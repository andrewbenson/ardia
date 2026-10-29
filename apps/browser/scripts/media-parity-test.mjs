import { mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { inflateSync } from "node:zlib";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node media-parity-test.mjs <Debug Solara.app> [--keep-data]

The native media controls against RN's, in pixels: window snapshots (2x) of the sidebar player, the hover mini player,
the CLI pill and the cast and share pickers, in light and dark, from RN (ARDIA_NATIVE_MEDIA=0), the RN-hosted native
views (=1) and the native shell's pane overlays (=1 with ARDIA_NATIVE_SHELL=1). Each control is cropped to RN's frame
grown by 16 pt, and its ink is what differs from the same crop with the control closed. A control passes when the
native ink is there and its bounds match RN's within a point (the CLI pill: its frame within half a point of RN's
Surface, with the Stop title unclipped, since the snapshot draws no layer shadow to bound it); the report gives the pixels off by more than 8/255 in
any channel, alpha included, and the largest difference.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-media-parity-"));
const shots = join(scratch, "shots");
mkdirSync(shots);
const rep = reporter(join(scratch, "media-parity-test.log"), { name: "media-parity-test" });

function readPng(path) {
  const buf = readFileSync(path);
  let width = 0, height = 0, channels = 4;
  const idat = [];
  for (let at = 8; at < buf.length; ) {
    const length = buf.readUInt32BE(at), type = buf.toString("ascii", at + 4, at + 8);
    if (type === "IHDR") {
      width = buf.readUInt32BE(at + 8);
      height = buf.readUInt32BE(at + 12);
      channels = { 2: 3, 6: 4 }[buf[at + 17]];
    } else if (type === "IDAT") idat.push(buf.subarray(at + 8, at + 8 + length));
    at += 12 + length;
  }
  const raw = inflateSync(Buffer.concat(idat));
  const stride = width * channels;
  const data = Buffer.alloc(stride * height);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    for (let x = 0; x < stride; x++) {
      const v = raw[y * (stride + 1) + 1 + x];
      const a = x >= channels ? data[y * stride + x - channels] : 0;
      const b = y ? data[(y - 1) * stride + x] : 0;
      const c = x >= channels && y ? data[(y - 1) * stride + x - channels] : 0;
      const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
      const pred = [0, a, b, (a + b) >> 1, pa <= pb && pa <= pc ? a : pb <= pc ? b : c][filter];
      data[y * stride + x] = (v + pred) & 255;
    }
  }
  return { width, height, channels, data };
}

const alphaAt = (img, i) => (img.channels === 4 ? img.data[i + 3] : 255);

function compare(pathA, pathB, rect) {
  const A = readPng(pathA), B = readPng(pathB);
  if (A.width !== B.width || A.height !== B.height) return { size: [A.width, A.height, B.width, B.height] };
  const [rx, ry, rw, rh] = rect.map((v) => Math.round(v * 2));
  let max = 0, over = 0, x0 = Infinity, y0 = Infinity, x1 = -1, y1 = -1;
  for (let y = Math.max(0, ry); y < Math.min(A.height, ry + rh); y++)
    for (let x = Math.max(0, rx); x < Math.min(A.width, rx + rw); x++) {
      const i = (y * A.width + x) * A.channels, j = (y * B.width + x) * B.channels;
      let d = Math.abs(alphaAt(A, i) - alphaAt(B, j));
      for (let k = 0; k < 3; k++) d = Math.max(d, Math.abs(A.data[i + k] - B.data[j + k]));
      max = Math.max(max, d);
      if (d > 8) {
        over++;
        x0 = Math.min(x0, x), y0 = Math.min(y0, y), x1 = Math.max(x1, x), y1 = Math.max(y1, y);
      }
    }
  return { max, over, box: over ? [x0 / 2, y0 / 2, (x1 - x0 + 1) / 2, (y1 - y0 + 1) / 2] : null };
}

const rate = 8000;
const tone = (() => {
  const n = rate * 120;
  const wav = Buffer.alloc(44 + n * 2);
  wav.write("RIFF", 0); wav.writeUInt32LE(36 + n * 2, 4); wav.write("WAVEfmt ", 8); wav.writeUInt32LE(16, 16);
  wav.writeUInt16LE(1, 20); wav.writeUInt16LE(1, 22); wav.writeUInt32LE(rate, 24); wav.writeUInt32LE(rate * 2, 28);
  wav.writeUInt16LE(2, 32); wav.writeUInt16LE(16, 34); wav.write("data", 36); wav.writeUInt32LE(n * 2, 40);
  for (let i = 0; i < n; i++) wav.writeInt16LE(Math.round(Math.sin((2 * Math.PI * 440 * i) / rate) * 33), 44 + i * 2);
  return wav;
})();
const server = createServer((req, res) => {
  if (req.url === "/tone.wav") {
    res.writeHead(200, { "content-type": "audio/wav", "content-length": String(tone.length) });
    return res.end(tone);
  }
  res.writeHead(200, { "content-type": "text/html" });
  if (req.url === "/player")
    return res.end(`<!doctype html><title>Player</title><link rel="icon" href="data:,"><audio id="tone" src="/tone.wav" loop></audio>
<script>navigator.mediaSession.metadata = new MediaMetadata({ title: "Short Track", artist: "Fixture Artist" });</script>`);
  res.end(`<!doctype html><title>B</title><link rel="icon" href="data:,"><body style="background:#fff">b</body>`);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const url = (name) => `http://127.0.0.1:${server.address().port}/${name}`;
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "p" } }],
  tabs: [{ id: "p", url: url("player"), title: "Player", pinned: true, pinnedUrl: url("player") }, { id: "b", url: url("b"), title: "B" }],
  settings: { sidebarMediaControls: true, warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false, searchSuggestions: false },
});

const CAST = {
  id: "cast-fixture", browserId: 0, open: true, header: "Cast tab", permissionRejected: false,
  sinks: [
    { id: "s1", name: "Living Room", state: "available", modes: 1, icon: 0, status: "", issue: "" },
    { id: "s2", name: "Kitchen Speaker", state: "connected", routeId: "r2", modes: 1, icon: 2, status: "Casting Player", issue: "" },
  ],
};
const SHARE = {
  id: "share-fixture", origin: "https://meet.test", frameOrigin: null, audio: { tab: true, screen: false, window: null },
  sources: [
    { id: "screen:fixture", kind: "screen", name: "Fixture Display", width: 1512, height: 982 },
    { id: "window:fixture", kind: "window", name: "Fixture Notes", app: "Notes" },
  ],
  pageUrl: url("b"),
};

const HELPERS = `
const st = () => ac.store.getState();
const hostOf = (fiber) => { let f = fiber; while (f && !(f.stateNode && f.stateNode.measureInWindow)) f = f.child; return f && f.stateNode; };
const measure = (fiber) => new Promise((r) => { const n = hostOf(fiber); return n ? n.measureInWindow((x, y, w, h) => r([x, y, w, h])) : r(null); });
const probe = (kind) => globalThis.expo.modules.SolaraMedia.probe(kind, "w1").then(JSON.parse);
const surfaces = () => Promise.all(acPerf.findFibers("Surface", 200).filter((f) => !!f.child).map(measure));
const rect = (name) => { const f = acPerf.findFibers(name, 50).find((f) => !!f.child); return f ? measure(f) : Promise.resolve(null); };
`;
const CONTROLS = [
  { name: "sidebar-player", fiber: "RNSidebarPlayer", open: `ac.actions.switchToTab("b");`, close: `ac.actions.switchToTab("p");` },
  { name: "mini-player", fiber: "MiniPlayer", closed: `ac.actions.switchToTab("b");`, open: `acMediaHover("w1", "p");`, close: `acMediaHover("w1", null);` },
  {
    name: "cli-pill", fiber: "RNCliControlPill", closed: `ac.actions.switchToTab("b");`, open: `acCli.indicator.setState({ shown: true });`, close: `acCli.indicator.setState({ shown: false });`,
    rnFrame: `surfaces().then((all) => all.find((r) => r && r[3] === 33 && r[1] > 600) ?? null)`,
    nativeFrame: `probe("media.cliPill").then((rows) => rows[0] ? { frame: rows[0].frame, stopClipped: rows[0].stopClipped } : null)`,
  },
  { name: "cast-picker", fiber: "PopoverSurface", closed: `ac.actions.switchToTab("b");`, open: `acCast.useCast.setState({ dialogs: { b: ${JSON.stringify(CAST)} } });`, close: `acCast.useCast.setState({ dialogs: {} });` },
  {
    name: "share-picker", fiber: "PopoverSurface", closed: `ac.actions.switchToTab("b");`,
    open: `acMedia.useMedia.setState((m) => ({ displayRequests: { ...m.displayRequests, b: ${JSON.stringify(SHARE)} } }));`,
    close: `acMedia.useMedia.setState((m) => { const d = { ...m.displayRequests }; delete d.b; return { displayRequests: d }; });`,
  },
];
const RN_HOSTED = Object.fromEntries([
  "ARDIA_NATIVE_SHELL", "ARDIA_NATIVE_SIDEBAR", "ARDIA_NATIVE_TOP_STRIP", "ARDIA_NATIVE_AUTOHIDE", "ARDIA_SHELL_PANES", "ARDIA_SHELL_MAIN_TOP",
  "ARDIA_NATIVE_PAGES_POOL", "ARDIA_NATIVE_PANE_PROMPTS",
].map((name) => [name, "0"]));
const MODES = [
  { tag: "rn", env: { ...RN_HOSTED, ARDIA_NATIVE_MEDIA: "0" } },
  { tag: "native", env: { ...RN_HOSTED, ARDIA_NATIVE_MEDIA: "1" } },
  { tag: "shell", env: { ARDIA_NATIVE_MEDIA: "1", ARDIA_NATIVE_SHELL: "1" } },
];
const APPEARANCES = ["light", "dark"];
const regions = {};
const files = {};
let app = null;

try {
  for (const mode of MODES) {
    app = await launch(resolve(appArg), {
      data: join(scratch, `data-${mode.tag}`), fresh: true, session: fixture, onboarded: true, probe: true,
      env: { ARDIA_ALLOW_AUDIO: "1", ...mode.env },
      switches: "--disable-audio-output --autoplay-policy=no-user-gesture-required",
      ready: "return !!ac.store.getState().windows.w1",
    });
    const run = (body) => app.eval(`${HELPERS}\n${body}`, { timeout: 20000 });
    for (let i = 0; i < 60 && !(await run(`return st().tabs.p?.title === "Player" && !st().live.p?.isLoading;`)); i++) await sleep(250);
    const page = await app.page(url("player"));
    await page.eval("document.getElementById('tone').play().then(() => true)", { userGesture: true });
    for (let i = 0; i < 40 && !(await run(`return acMedia.useMedia.getState().sessions.p?.playbackState === "playing";`)); i++) await sleep(250);
    await run(`acMedia.mediaCommand("p", "toggle"); return true;`);
    for (let i = 0; i < 40 && !(await run(`return acMedia.useMedia.getState().sessions.p?.playbackState === "paused";`)); i++) await sleep(250);
    await page.eval("document.getElementById('tone').currentTime = 0; true");
    page.close();
    for (const appearance of APPEARANCES) {
      await run(`st().updateSettings({ appearance: ${JSON.stringify(appearance)} }); return true;`);
      await sleep(600);
      for (const control of CONTROLS) {
        const key = `${control.name}-${appearance}`;
        const shot = (state) => {
          const path = join(shots, `${mode.tag}-${key}-${state}.png`);
          return run(`return ac.shell.devSnapshotWindow("w1", ${JSON.stringify(path)});`).then(() => path);
        };
        await run(`${control.closed ?? control.close} return true;`);
        await sleep(700);
        const closed = await shot("closed");
        await run(`${control.open} return true;`);
        await sleep(900);
        if (mode.tag === "rn") regions[key] = await run(`return rect(${JSON.stringify(control.fiber)});`);
        const frame = mode.tag === "rn" ? control.rnFrame : control.nativeFrame;
        const measured = frame ? await run(`return ${frame};`) : null;
        const open = await shot("open");
        await run(`${control.close} return true;`);
        await sleep(500);
        (files[key] ??= {})[mode.tag] = { closed, open, measured };
      }
    }
    await app.quit();
    app = null;
  }

  for (const control of CONTROLS)
    for (const appearance of APPEARANCES) {
      const key = `${control.name}-${appearance}`;
      await rep.check(key, async () => {
        const area = regions[key];
        if (!area) throw new Error(`RN never drew ${control.fiber}`);
        const crop = [area[0] - 16, area[1] - 16, area[2] + 32, area[3] + 32];
        const rn = files[key].rn;
        const rnInk = compare(rn.closed, rn.open, crop).box;
        if (!rnInk) throw new Error("RN's crop has no ink");
        const out = { area, rnInk };
        for (const tag of ["native", "shell"]) {
          const got = files[key][tag];
          const ink = compare(got.closed, got.open, crop).box;
          if (!ink) throw new Error(`${tag}: nothing drawn in RN's frame ${JSON.stringify(area)}`);
          const diff = compare(rn.open, got.open, crop);
          out[tag] = { ink, over: diff.over, max: diff.max, box: diff.box };
          if (control.rnFrame) {
            const want = rn.measured, have = got.measured;
            out[tag].frame = have;
            if (!want || !have || have.stopClipped || have.frame.some((v, i) => Math.abs(v - want[i]) > 0.5))
              throw new Error(`${tag} frame ${JSON.stringify(have)}, RN's ${JSON.stringify(want)}`);
            continue;
          }
          if (ink.some((v, i) => Math.abs(v - rnInk[i]) > 1)) throw new Error(`${tag} ink ${JSON.stringify(ink)}, RN's ${JSON.stringify(rnInk)}: ${JSON.stringify(out)}`);
        }
        return out;
      });
    }
} catch (e) {
  rep.record("run", { error: e });
} finally {
  await app?.quit().catch(() => {});
  server.close();
  if (!keep && rep.results.every((r) => r.ok)) rmSync(scratch, { recursive: true, force: true });
}
const failed = rep.results.filter((r) => !r.ok);
console.log(`${rep.results.length - failed.length}/${rep.results.length} passed${failed.length || keep ? `; log ${rep.logFile}` : ""}`);
process.exit(failed.length ? 1 : 0);

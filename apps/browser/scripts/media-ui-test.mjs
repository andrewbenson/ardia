import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node media-ui-test.mjs <Debug Solara.app> [--native] [--keep-data]

The media controls on a local tone page: the sidebar player shows for a playing tab that isn't shown, its play
button pauses and plays, Close Player hides it without pausing or moving to the tab, a new play brings it back, Back
to Tab shows the tab and ends the player; the pinned tab's hover player scrolls a long title and ticks its time; the
CLI pill appears and hides with RN's timing; the cast and share pickers open at RN's size and answer their buttons. --native runs with ARDIA_NATIVE_MEDIA=1 and clicks the native controls.`);
  process.exit(2);
}
const native = args.includes("--native");
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-media-ui-"));
const data = join(scratch, "data");
const rep = reporter(join(scratch, "media-ui-test.log"), { name: `media-ui-test${native ? " --native" : ""}` });

const LONG_TITLE = "A very long fixture track title that has to scroll in the hover player";
const tone = (() => {
  const rate = 8000;
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
  const name = req.url.slice(1) || "root";
  res.writeHead(200, { "content-type": "text/html" });
  if (name === "player")
    return res.end(`<!doctype html><title>Player</title><link rel="icon" href="data:,"><audio id="tone" src="/tone.wav" loop></audio>
<script>navigator.mediaSession.metadata = new MediaMetadata({ title: ${JSON.stringify(LONG_TITLE)}, artist: "Fixture Artist" });</script>`);
  res.end(`<!doctype html><title>${name.toUpperCase()}</title><link rel="icon" href="data:,"><body>${name}</body>`);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const url = (name) => `http://127.0.0.1:${server.address().port}/${name}`;
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "p" } }],
  tabs: [{ id: "p", url: url("player"), title: "Player", pinned: true, pinnedUrl: url("player") }, { id: "b", url: url("b"), title: "B" }],
  settings: { sidebarMediaControls: true, warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false, searchSuggestions: false },
});

const HELPERS = `
const C = globalThis.expo.modules.ArdiaCEF;
const M = globalThis.expo.modules.SolaraMedia;
const st = () => ac.store.getState();
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const shown = () => st().windows.w1.activeTabIds[st().windows.w1.profileId];
const win = () => C.chromeWindows().then((ws) => ws.find((w) => w.hasRoot).window);
const act = (a) => win().then((n) => C.devWindow(n, a));
const probe = (kind) => (M ? M.probe(kind, "w1").then(JSON.parse) : Promise.resolve([]));
const fibers = (name) => acPerf.findFibers(name, 500).filter((f) => !!f.child);
const centre = (f) => [Math.round(f[0] + f[2] / 2), Math.round(f[1] + f[3] / 2)];
const hover = ([x, y]) => ac.shell.devSetPointer("w1", { x, y }).then(() => act("mouse:moved:" + x + "," + y));
const click = (p) => hover(p).then(() => settle(60)).then(() => act("mouse:down:" + p[0] + "," + p[1])).then(() => settle(60)).then(() => act("mouse:up:" + p[0] + "," + p[1]));
const playerShown = () => ${native} ? probe("media.sidebarPlayer").then((rows) => rows.length) : Promise.resolve(fibers("RNSidebarPlayer").length);
const first = (kind) => probe(kind).then((rows) => rows[0] || null);
const session = () => acMedia.useMedia.getState().sessions.p;
const hostOf = (fiber) => { let f = fiber; while (f && !(f.stateNode && f.stateNode.measureInWindow)) f = f.child; return f && f.stateNode; };
const measure = (fiber) => new Promise((r) => { const n = hostOf(fiber); return n ? n.measureInWindow((x, y, w, h) => r([x, y, w, h])) : r(null); });
const surface = () => { const [f] = acPerf.findFibers("PopoverSurface", 5); return f ? measure(f) : Promise.resolve(null); };
`;
let app = null;
const run = (body, timeout = 20000) => app.eval(`${HELPERS}\n${body}`, { timeout });
const until = async (what, body, ms = 8000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await run(body).catch((e) => ({ error: String(e.message ?? e) }));
    if (last && !last.error) return last;
    await sleep(150);
  }
  throw new Error(`${what}: never true (last ${JSON.stringify(last)})`);
};
const inPage = async (expression) => {
  const page = await app.page(url("player"));
  try {
    return await page.eval(expression, { userGesture: true });
  } finally {
    page.close();
  }
};
const paused = async () => (await inPage("document.getElementById('tone').paused")) === true;
const pressPlayer = async (control) => {
  if (!native) return run(`acMedia.mediaCommand("p", "toggle"); return true;`);
  return run(`return first("media.sidebarPlayer").then((row) => { if (!row) throw new Error("no native player"); return click(centre(row.frames[${JSON.stringify(control)}])); }).then(() => true);`);
};

try {
  app = await launch(resolve(appArg), {
    data, fresh: true, session: fixture, onboarded: true, probe: true,
    env: { ARDIA_ALLOW_AUDIO: "1", ...(native ? { ARDIA_NATIVE_MEDIA: "1" } : {}) },
    switches: "--disable-audio-output --autoplay-policy=no-user-gesture-required",
    ready: "return !!ac.store.getState().windows.w1",
  });

  await rep.check("native-kinds", async () => {
    const [kinds, enabled] = await run(`return [globalThis.expo.modules.SolaraHosted.kinds(), !!M && M.enabled()];`);
    const want = ["media.cliPill", "media.hoverPlayer", "media.sidebarPlayer"];
    const have = want.filter((k) => kinds.includes(k));
    if (native && (have.length !== want.length || !enabled)) throw new Error(`native kinds missing: ${JSON.stringify({ kinds, enabled })}`);
    if (!native && have.length) throw new Error(`native kinds registered with the switch off: ${have}`);
    return { kinds: have, enabled };
  });

  await rep.check("sidebar-player-shows", async () => {
    await until("player page loaded", `return st().tabs.p?.title === "Player" && !st().live.p?.isLoading;`, 15000);
    await inPage("document.getElementById('tone').play().then(() => true)");
    await until("session playing", `return session()?.playbackState === "playing" && session()?.controllable;`, 10000);
    await run(`ac.actions.switchToTab("b"); return true;`);
    const count = await until("sidebar player", `return playerShown().then((n) => n || null);`, 6000);
    const rows = native ? await run(`return probe("media.sidebarPlayer");`) : null;
    if (native && rows[0].height !== 74) throw new Error(`player height ${rows[0].height}, RN draws 74`);
    return { count, height: rows?.[0]?.height };
  });

  await rep.check("play-pause", async () => {
    await pressPlayer("play");
    await until("paused", `return session()?.playbackState === "paused";`, 6000);
    if (!(await paused())) throw new Error("the page kept playing");
    await pressPlayer("play");
    await until("playing", `return session()?.playbackState === "playing";`, 6000);
    return { paused: await paused() };
  });

  await rep.check("close-keeps-playing", async () => {
    if (native) {
      await run(`return first("media.sidebarPlayer").then((row) => hover(centre(row.frames.title))).then(() => true);`);
      await until("corner buttons on hover", `return first("media.sidebarPlayer").then((row) => row?.corners || null);`, 3000);
      await pressPlayer("close");
    } else {
      await run(`acMedia.useMedia.setState((m) => ({ dismissed: { ...m.dismissed, p: true } })); return true;`);
    }
    await until("player gone", `return playerShown().then((n) => n === 0);`, 4000);
    await sleep(500);
    const still = { paused: await paused(), shown: await run(`return shown();`) };
    if (still.paused) throw new Error("closing the player paused playback");
    if (still.shown !== "b") throw new Error(`closing the player moved to tab ${still.shown}`);
    return still;
  });

  await rep.check("new-play-brings-it-back", async () => {
    await inPage("document.getElementById('tone').pause(), true");
    await until("paused", `return session()?.playbackState === "paused";`, 6000);
    await inPage("document.getElementById('tone').play().then(() => true)");
    return until("player again", `return playerShown().then((n) => n || null);`, 6000);
  });

  await rep.check("back-to-tab", async () => {
    if (native) await pressPlayer("art");
    else await run(`ac.actions.switchToTab("p"); return true;`);
    await until("tab shown", `return shown() === "p";`, 4000);
    await until("player ends", `return playerShown().then((n) => n === 0);`, 4000);
    return { paused: await paused() };
  });

  await rep.check("hover-player", async () => {
    await run(`ac.actions.switchToTab("b"); return true;`);
    await run(`return Promise.resolve(acMediaHover("w1", "p")).then(() => true);`);
    if (!native) return until("hover player", `return fibers("MiniPlayer").length || null;`, 3000);
    const first = await until("native hover player", `return first("media.hoverPlayer");`, 3000);
    if (!(first.titleOverflow > 0)) throw new Error(`the long title doesn't overflow: ${JSON.stringify(first)}`);
    await sleep(2600);
    const later = (await run(`return probe("media.hoverPlayer");`))[0];
    const max = Math.max(later.titleOverflow, later.artistOverflow);
    const expected = Math.max(0, Math.min(1, ((later.t - first.t - 1.5) * 30) / max));
    if (Math.abs(later.marquee - expected) > 0.1) throw new Error(`marquee at ${later.marquee}, RN would be near ${expected}`);
    if (later.elapsed === first.elapsed) throw new Error(`time stood still at ${later.elapsed}`);
    await run(`return Promise.resolve(acMediaHover("w1", null)).then(() => true);`);
    return { overflow: later.titleOverflow, marquee: later.marquee, expected, elapsed: [first.elapsed, later.elapsed] };
  });

  await rep.check("cli-pill-timing", async () => {
    if (!native) return { rn: "drawn by RN" };
    const samples = await run(`
      const indicator = globalThis.acCli.indicator;
      const out = [];
      const sample = (until) => performance.now() >= until ? Promise.resolve() : first("media.cliPill").then((row) => { if (row) out.push(row); return settle(16); }).then(() => sample(until));
      indicator.setState({ shown: true });
      return sample(performance.now() + 260).then(() => { indicator.setState({ shown: false }); return sample(performance.now() + 320); }).then(() => out);`, 10000);
    const on = samples.filter((s) => s.shown);
    const off = samples.filter((s) => !s.shown);
    if (!on.length || !off.length) throw new Error(`no samples: ${JSON.stringify(samples.slice(0, 3))}`);
    const peak = Math.max(...on.map((s) => s.opacity));
    if (peak < 0.99) throw new Error(`never fully shown: ${peak}`);
    if (off.at(-1).opacity > 0.01) throw new Error(`still visible 320 ms after hiding: ${off.at(-1).opacity}`);
    return { samples: samples.length, frame: on.at(-1).frame, peak };
  });
  const RN_CAST = [340, 185];
  const RN_SHARE = [460, 423];
  const CAST = {
    id: "cast-fixture", browserId: 0, open: true, header: "Cast tab", permissionRejected: false,
    sinks: [
      { id: "s1", name: "Living Room", state: "available", modes: 1, icon: 0, status: "", issue: "" },
      { id: "s2", name: "Kitchen Speaker", state: "connected", routeId: "r2", modes: 1, icon: 2, status: "Casting Player", issue: "" },
    ],
  };
  await rep.check("cast-picker", async () => {
    await run(`acCast.useCast.setState({ dialogs: { b: ${JSON.stringify(CAST)} } }); return true;`);
    const rect = await until("cast popover", `return surface();`, 4000);
    await sleep(300);
    const settled = await run(`return surface();`);
    const out = { rect: settled };
    if (Math.abs(settled[2] - RN_CAST[0]) > 0.5 || Math.abs(settled[3] - RN_CAST[1]) > 0.5) throw new Error(`cast popover ${settled[2]}x${settled[3]}, RN draws ${RN_CAST.join("x")}`);
    if (native) {
      const row = await until("native cast picker", `return first("media.castPicker");`, 3000);
      out.height = row.height;
      if (Math.abs(row.height + 1 - settled[3]) > 0.5) throw new Error(`native body ${row.height} tall in a ${settled[3]} popover`);
      await run(`globalThis.__castLog = []; const a = acNativeMedia.actions; globalThis.__castReal = a.castPicker; a.castPicker = (w, t, e) => { __castLog.push(e); }; return true;`);
      await run(`return first("media.castPicker").then((r) => click(centre(r.frames.done))).then(() => true);`);
      await run(`return first("media.castPicker").then((r) => click(centre(r.frames.sink0))).then(() => true);`);
      const log = await until("cast actions", `return __castLog.filter((e) => e.action !== "height").length >= 2 ? __castLog.filter((e) => e.action !== "height") : null;`, 3000);
      await run(`acNativeMedia.actions.castPicker = __castReal; return true;`);
      if (log[0].action !== "done" || log[1].action !== "cast" || log[1].sinkId !== "s1") throw new Error(`cast actions ${JSON.stringify(log)}`);
      out.actions = log.map((e) => e.action);
    }
    await run(`acCast.useCast.setState({ dialogs: {} }); return true;`);
    return out;
  });

  const SHARE = {
    id: "share-fixture", origin: "https://meet.test", frameOrigin: null, audio: { tab: true, screen: false, window: null },
    sources: [
      { id: "screen:fixture", kind: "screen", name: "Fixture Display", width: 1512, height: 982 },
      { id: "window:fixture", kind: "window", name: "Fixture Notes", app: "Notes" },
    ],
    pageUrl: url("b"),
  };
  await rep.check("share-picker", async () => {
    await run(`acMedia.useMedia.setState((m) => ({ displayRequests: { ...m.displayRequests, b: ${JSON.stringify(SHARE)} } })); return true;`);
    await until("share popover", `return surface();`, 4000);
    await sleep(300);
    const settled = await run(`return surface();`);
    const out = { rect: settled };
    if (Math.abs(settled[2] - RN_SHARE[0]) > 0.5 || Math.abs(settled[3] - RN_SHARE[1]) > 0.5) throw new Error(`share popover ${settled[2]}x${settled[3]}, RN draws ${RN_SHARE.join("x")}`);
    if (native) {
      const row = await until("native share picker", `return first("media.sharePicker");`, 3000);
      out.height = row.height;
      if (Math.abs(row.height + 1 - settled[3]) > 0.5) throw new Error(`native body ${row.height} tall in a ${settled[3]} popover`);
      await run(`return first("media.sharePicker").then((r) => click(centre(r.frames["tab:p"]))).then(() => true);`);
      const picked = await until("tab selected", `return first("media.sharePicker").then((r) => r.selected === "tab:p" ? r : null);`, 3000);
      out.audio = !!picked.frames.audio;
      if (!picked.frames.audio) throw new Error("no tab audio checkbox for a tab");
      await run(`return first("media.sharePicker").then((r) => click(centre(r.frames.cancel))).then(() => true);`);
    } else {
      await run(`acMedia.useMedia.setState((m) => { const d = { ...m.displayRequests }; delete d.b; return { displayRequests: d }; }); return true;`);
    }
    await until("share request ends", `return !acMedia.useMedia.getState().displayRequests.b;`, 3000);
    return out;
  });
} catch (e) {
  rep.record("run", { error: e });
} finally {
  await app?.quit().catch(() => {});
  server.close();
  if (!keep && rep.results.every((r) => r.ok)) rmSync(scratch, { recursive: true, force: true });
}
const failed = rep.results.filter((r) => !r.ok);
console.log(`${rep.results.length - failed.length}/${rep.results.length} passed${failed.length ? `; log ${rep.logFile}` : ""}`);
process.exit(failed.length ? 1 : 0);

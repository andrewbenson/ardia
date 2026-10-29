import assert from "node:assert/strict";
import { createServer } from "node:http";
import { mkdirSync, mkdtempSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node download-magnet-test.mjs <Debug Solara.app> [--native | --rn] [--keep-data]

A real download from a local server into a scratch folder (ARDIA_DOWNLOADS_DIR), with the download magnet drawn
natively (ARDIA_NATIVE_DOWNLOAD_MAGNET=1: DownloadMagnetView, read in process through SolaraHosted.downloadMagnet)
and by RN (=0). Both legs run unless one is named.
Native: the file icon flies once, about 0.7 s, from the page toward the downloads target on RN's arc (above the
straight line), fading in and out, and settles at the target with nothing left animating; RN draws no flight.
RN: its flight mounts for about 0.7 s and unmounts, and no native view exists.`);
  process.exit(2);
}
const appPath = resolve(appArg);
const legs = args.includes("--native") ? [true] : args.includes("--rn") ? [false] : [false, true];
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-download-magnet-"));
const rep = reporter(join(scratch, "download-magnet-test.log"), { name: "download-magnet-test" });

const server = createServer((req, res) => {
  if (req.url.startsWith("/file.bin")) {
    res.writeHead(200, { "content-type": "application/octet-stream", "content-disposition": 'attachment; filename="magnet-test.bin"' });
    return res.end(Buffer.alloc(64 * 1024, 7));
  }
  res.writeHead(200, { "content-type": "text/html" });
  res.end("<!doctype html><title>MAGNET</title><body style='background:#fff'>magnet</body>");
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}`;

const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [{ id: "a", url: `${base}/`, title: "MAGNET" }],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
});

const HELPERS = `
const H = globalThis.expo.modules.SolaraHosted;
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const nameOf = (t) => !t ? "" : typeof t === "string" ? t : t.displayName || t.name || nameOf(t.type) || nameOf(t.render);
const inMagnet = (pred) => {
  const m = acPerf.findFibers("DownloadMagnet", 5)[0];
  let hit = null;
  const visit = (f) => { for (let c = f; c && !hit; c = c.sibling) { if (pred(c)) hit = c; else visit(c.child); } };
  if (m) visit(m.child);
  return hit;
};
const hostedState = () => { const f = inMagnet((c) => c.memoizedProps && c.memoizedProps.kind === "downloadMagnet"); return f ? JSON.parse(f.memoizedProps.state || "null") : null; };
const rnFlying = () => !!inMagnet((c) => nameOf(c.type) === "FileIcon");
const magnet = () => H.downloadMagnet("w1").then(JSON.parse);
`;

let app = null;
const run = (body, timeout = 20000) => app.eval(`${HELPERS}\n${body}`, { timeout });

try {
  for (const native of legs) {
    const tag = native ? "native" : "rn";
    const downloads = join(scratch, `downloads-${tag}`);
    mkdirSync(downloads, { recursive: true });
    app = await launch(appPath, {
      data: join(scratch, `data-${tag}`), fresh: true, session: fixture, onboarded: true, probe: true,
      env: { ARDIA_NATIVE_DOWNLOAD_MAGNET: native ? "1" : "0", ARDIA_DOWNLOADS_DIR: downloads },
      ready: "return !!ac.store.getState().windows.w1 && !!globalThis.acPerf",
    });
    rep.log(`${tag}: pid ${app.pid}`);
    await rep.check(`${tag}: ${native ? "the native magnet flies to the downloads target and settles" : "RN's magnet flies and unmounts"}`, () => magnetChecks(native, downloads));
    await app.quit();
    app = null;
  }
} finally {
  await app?.quit();
  server.close();
  if (!keep) for (const tag of ["rn", "native"]) rmSync(join(scratch, `data-${tag}`), { recursive: true, force: true });
  else rep.say(`data: ${scratch}`);
}
process.exit(rep.summary() ? 0 : 1);

async function magnetChecks(native, downloads) {
  const kinds = await run("return H.kinds();");
  assert.equal(kinds.includes("downloadMagnet"), native, `the downloadMagnet kind is ${native ? "missing" : "registered"}`);
  if (native) {
    const end = Date.now() + 10000;
    let mounted = null;
    while (Date.now() < end && !(mounted?.inWindow && mounted.size[0] > 0)) {
      mounted = await run("return magnet();");
      if (!(mounted?.inWindow && mounted.size[0] > 0)) await new Promise((r) => setTimeout(r, 200));
    }
    assert.ok(mounted?.inWindow && mounted.size[0] > 0, `the native magnet view is mounted and laid out (${JSON.stringify(mounted)})`);
    assert.equal(mounted.flights, 0, "nothing flew before the download");
  } else {
    assert.equal(await run("return magnet();"), null, "no native magnet view with the switch off");
  }

  const samples = await run(`
    const t0 = Date.now();
    const samples = [];
    ac.actions.openUrls([${JSON.stringify(`${base}/file.bin`)}], "w1");
    const loop = () => (${native} ? magnet() : Promise.resolve(null)).then((d) => {
      const s = { t: Date.now() - t0, d, state: ${native} ? hostedState() : null, rn: rnFlying() };
      samples.push(s);
      const first = samples.find((x) => (x.d && x.d.flights > 0) || x.rn);
      if (s.t > 8000 || (first && s.t - first.t > 1400)) return samples;
      return settle(25).then(loop);
    });
    return loop();
  `, 30000);
  rep.log(`${samples.length} samples over ${samples.at(-1).t} ms`);

  const download = await run(`
    const t0 = Date.now();
    const read = () => ac.store.getState().downloads.map((d) => ({ state: d.state, path: d.path, filename: d.filename }));
    const loop = () => {
      const list = read();
      if (list.some((d) => d.filename) || Date.now() - t0 > 10000) return list;
      return settle(100).then(loop);
    };
    return loop();
  `, 15000);
  const got = download.find((d) => d.filename?.includes("magnet-test"));
  assert.ok(got, `the download reached the store (${JSON.stringify(download)})`);
  assert.ok(!got.path || got.path.startsWith(downloads), `downloaded to ${got.path}, not the scratch folder`);
  assert.ok(readdirSync(downloads).some((f) => f.startsWith("magnet-test")) || got.state !== "finished", "the finished file is in the scratch folder");

  if (!native) {
    const flying = samples.filter((s) => s.rn);
    assert.ok(flying.length > 0, "RN mounted a flight");
    const span = flying.at(-1).t - flying[0].t;
    assert.ok(span >= 450 && span <= 1200, `RN's flight lasted about 0.7 s (${span} ms)`);
    assert.equal(samples.at(-1).rn, false, "RN's flight unmounted");
    rep.log(`RN flight ${span} ms`);
    return `RN flight ${span} ms`;
  }

  assert.ok(samples.every((s) => !s.rn), "RN drew no flight with the switch on");
  const flight = samples.map((s) => s.state?.flight).find(Boolean);
  assert.ok(flight, "JS handed the native view a flight");
  const [sx, sy] = flight.start;
  const [tx, ty] = flight.target;
  const animating = samples.filter((s) => s.d?.animating);
  assert.ok(animating.length >= 3, `the icon animated (${animating.length} samples)`);
  const span = animating.at(-1).t - animating[0].t;
  assert.ok(span >= 400 && span <= 1100, `the flight lasted about 0.7 s (${span} ms)`);
  const visible = animating.filter((s) => s.d.opacity > 0.05);
  assert.ok(visible.length > 0, "the icon was visible mid-flight");
  assert.ok(animating.some((s) => s.d.opacity > 0.9), "it faded in to full opacity");
  const dist = (p) => Math.hypot(p[0] - tx, p[1] - ty);
  const along = visible.map((s) => s.d.position);
  assert.ok(dist(along.at(-1)) < dist(along[0]), `it moved toward the target (${JSON.stringify(along[0])} -> ${JSON.stringify(along.at(-1))}, target ${tx},${ty})`);
  const lift = Math.max(...along.map(([x, y]) => {
    const p = Math.abs(tx - sx) > 1 ? (x - sx) / (tx - sx) : (y - sy) / (ty - sy);
    return sy + (ty - sy) * p - y;
  }));
  assert.ok(lift > 20, `it flew on an arc above the straight line (${lift.toFixed(1)} pt at most)`);
  const last = samples.at(-1).d;
  assert.equal(last.flights, 1, "it flew once");
  assert.equal(last.animating, false, "nothing is left animating");
  assert.equal(last.flying, undefined, "the flight ended");
  assert.ok(Math.abs(last.restingPosition[0] - tx) <= 0.5 && Math.abs(last.restingPosition[1] - ty) <= 0.5, `it settled at the target (${last.restingPosition} vs ${tx},${ty})`);
  assert.equal(last.restingOpacity, 0, "it settled faded out");
  assert.equal(samples.at(-1).state?.flight ?? null, null, "JS cleared the flight once it landed");
  rep.log(`native flight ${span} ms, arc ${lift.toFixed(1)} pt, ${flight.start} -> ${flight.target}`);
  return `native flight ${span} ms, arc ${lift.toFixed(1)} pt`;
}

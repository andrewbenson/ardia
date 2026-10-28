import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node swipe-capsule-test.mjs <Debug Solara.app> [--keep-data]

The back-swipe capsule on a tab that went ONE, TWO, THREE on local pages, drawn by RN and then natively
(ARDIA_NATIVE_SHELL=1: SwipeCapsuleView in the pane overlay container on top of the shell's card, fed by RN's
SwipeOverlay, which keeps the gesture). The same simulated gestures in both: one kept moving past the threshold
shows the confirmed 82 pt capsule centred on the page at the rubber-banded offset, and cancelling it navigates
nowhere; one held still past the threshold turns into the 200 wide destination list (2 rows of 38 plus 8 above and
below, its first row centred on the page), and ending it goes back one entry. The native frames match RN's within
half a point, RN draws no capsule with the switch on, and the native container leaves the card once it fades.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-swipe-capsule-"));
const rep = reporter(join(scratch, "swipe-capsule-test.log"), { name: "swipe-capsule-test" });

const server = createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/html" });
  res.end(`<!doctype html><title>${req.url.slice(1).toUpperCase()}</title><link rel="icon" href="data:,"><body>${req.url.slice(1)}</body>`);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const url = (n) => `http://127.0.0.1:${server.address().port}/${n}`;
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [{ id: "a", url: url("one"), title: "ONE" }],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
});

const timed = (steps) => steps.map((s) => ({ dy: 0, ...s, timestampMs: s.atMs }));
const push = Array.from({ length: 8 }, (_, i) => ({ phase: "changed", dx: 20, atMs: 16 * (i + 1) }));
const kept = timed([{ phase: "began", dx: 0, atMs: 0 }, ...push, ...Array.from({ length: 6 }, (_, i) => ({ phase: "changed", dx: 1, atMs: 200 + 100 * i })), { phase: "cancelled", dx: 0, atMs: 760 }]);
const held = timed([{ phase: "began", dx: 0, atMs: 0 }, ...push, { phase: "ended", dx: 0, atMs: 1100 }]);

const HELPERS = `
const C = globalThis.expo.modules.ArdiaCEF;
const M = globalThis.expo.modules.SolaraMedia;
const title = () => ac.store.getState().tabs.a.title;
const hostOf = (fiber) => { let f = fiber; while (f && !(f.stateNode && f.stateNode.measureInWindow)) f = f.child; return f && f.stateNode; };
const measure = (fiber) => new Promise((r) => { const n = hostOf(fiber); return n ? n.measureInWindow((x, y, w, h) => r([x, y, w, h])) : r(null); });
const overlay = () => acPerf.findFibers("SwipeOverlay", 500).find((f) => f.memoizedProps.tabId === "a");
const rnCapsule = () => { const o = overlay(); const area = o && o.child; const capsule = area && area.sibling; return capsule && !capsule.memoizedProps.onLayout ? capsule : null; };
const native = () => M && M.describePaneOverlays ? M.describePaneOverlays("w1").then(JSON.parse) : Promise.resolve(null);
const sample = () => Promise.all([rnCapsule() ? measure(rnCapsule()) : null, native(), measure(overlay().child),
  acPerf.findFibers("DestinationList", 50).length]).then(([rn, nat, area, lists]) => ({ rn, native: nat && nat.tabs.a && nat.tabs.a.swipe || null, area, lists, title: title() }));
const gesture = (steps, at) => new Promise((resolve) => {
  let seen = null;
  setTimeout(() => sample().then((s) => (seen = s)), at);
  globalThis.acSwipe.pane("a").devSimulate(steps, { ignorePreference: true }).then(() => setTimeout(() => resolve(seen), 100));
});
`;
let app = null;
const run = (body, timeout = 20000) => app.eval(`${HELPERS}\n${body}`, { timeout });
const until = async (what, body, ms = 8000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await run(body).catch((e) => ({ error: String(e.message ?? e) }));
    if (last && !last.error) return last;
    await sleep(100);
  }
  throw new Error(`${what}: never true (last ${JSON.stringify(last)})`);
};
const near = (a, b) => a && b && a.length === b.length && a.every((v, i) => Math.abs(v - b[i]) <= 0.5);
const got = {};

try {
  for (const nativeShell of [false, true]) {
    const tag = nativeShell ? "native" : "rn";
    app = await launch(resolve(appArg), {
      data: join(scratch, `data-${tag}`), fresh: true, session: fixture, onboarded: true, probe: true,
      env: { ARDIA_NATIVE_SHELL: nativeShell ? "1" : "0" },
      ready: "return !!ac.store.getState().windows.w1 && !!globalThis.acSwipe",
    });
    await until("page ONE", `return title() === "ONE" || null;`, 15000);
    for (const page of ["two", "three"]) {
      await run(`ac.store.getState().navigate("a", ${JSON.stringify(url(page))}, { userInitiated: true }); return true;`);
      await until(`page ${page}`, `return title() === ${JSON.stringify(page.toUpperCase())} || null;`, 15000);
    }
    await sleep(600);
    const shown = (s) => (nativeShell ? s.native && s.native.frame : s.rn);

    await rep.check(`${tag}-confirmed-capsule`, async () => {
      const s = await run(`return gesture(${JSON.stringify(kept)}, 620);`);
      const frame = shown(s);
      if (!frame) throw new Error(`no capsule mid-gesture: ${JSON.stringify(s)}`);
      const [, ay, , ah] = s.area;
      if (Math.abs(frame[2] - 82) > 0.5 || Math.abs(frame[3] - 82) > 0.5 || Math.abs(frame[1] - (ay + ah / 2 - 41)) > 0.5) throw new Error(`capsule ${frame} in ${s.area}`);
      if (nativeShell && (s.rn || !s.native.confirmed)) throw new Error(`RN capsule ${s.rn}, native ${JSON.stringify(s.native)}`);
      await sleep(500);
      if ((await run(`return title();`)) !== "THREE") throw new Error("cancelling navigated");
      got[`${tag}-capsule`] = frame;
      return { frame, area: s.area };
    });

    await rep.check(`${tag}-destination-list`, async () => {
      const s = await run(`return gesture(${JSON.stringify(held)}, 950);`);
      const frame = shown(s);
      if (!frame) throw new Error(`no list mid-gesture: ${JSON.stringify(s)}`);
      const [, ay, , ah] = s.area;
      const want = [200, 2 * 38 + 16];
      if (!near(frame.slice(2), want) || Math.abs(frame[1] - (ay + ah / 2 - 8 - 19)) > 0.5) throw new Error(`list ${frame} in ${s.area}`);
      if (nativeShell && (s.lists || JSON.stringify(s.native.items) !== JSON.stringify(["TWO", "ONE"]))) throw new Error(`RN lists ${s.lists}, native items ${JSON.stringify(s.native.items)}`);
      await until("back to TWO", `return title() === "TWO" || null;`, 4000);
      if (nativeShell) await until("the native capsule goes", `return native().then((d) => !d || !d.inCard || null);`, 2000);
      got[`${tag}-list`] = frame;
      return { frame };
    });
    await app.quit();
    app = null;
  }
  await rep.check("native-matches-rn", async () => {
    for (const k of ["capsule", "list"]) if (!near(got[`native-${k}`], got[`rn-${k}`])) throw new Error(`${k}: native ${got[`native-${k}`]}, RN ${got[`rn-${k}`]}`);
    return got;
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

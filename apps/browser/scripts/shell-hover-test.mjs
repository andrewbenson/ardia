import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node shell-hover-test.mjs <Debug Solara.app> [--sidebar] [--keep-data]

Hover goes to what's on top in a native window shell (ARDIA_NATIVE_SHELL=1): the sidebar's rows (RN's, or the native
column's when the native sidebar is on) hover under the pointer; under a native view mounted in the shell's overlay slot
they don't; a row under a still pointer leaves when the native view arrives and enters again when it goes, and the same
when the native view is hidden and shown without leaving the overlay; with the native sidebar, a native view over the
peeking sidebar takes its hover too (--sidebar runs the native column, the RN rows otherwise); finding the layer under
the pointer stays under 30 µs. With the RN main root on top (ARDIA_SHELL_MAIN_TOP=1) the exact lookup walks the RN
tree, so it stays under 120 µs and the shell runs it at most once a display frame: a 120 Hz pointer stream costs at most
one lookup per frame and 3% of a core on a 60 Hz display (the 120 Hz display estimate is only reported), and with or
without it the hover layer changes within a frame of the move.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const nativeColumn = args.includes("--sidebar");
const scratch = mkdtempSync(join(tmpdir(), "ac-shell-hover-"));
const data = join(scratch, "data");
const rep = reporter(join(scratch, "shell-hover-test.log"), { name: "shell-hover-test" });
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [{ id: "a", url: "about:blank", title: "A" }, { id: "b", url: "about:blank", title: "B" }, { id: "c", url: "about:blank", title: "C" }],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
});
const HELPERS = `
const S = globalThis.expo.modules.SolaraWindowShell;
const C = globalThis.expo.modules.ArdiaCEF;
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const win = () => C.chromeWindows().then((ws) => ws.find((w) => w.hasRoot).window);
const at = (x, y) => ac.shell.devSetPointer("w1", { x, y }).then(() => win()).then((n) => C.devWindow(n, "mouse:moved:" + x + "," + y)).then(() => settle(250));
const stats = () => ac.shell.devHoverStats(true);
const count = (s, kind) => (s.log || []).filter((e) => e[0] === kind).length;
const H = globalThis.expo.modules.SolaraHosted;
const hover = () => (H?.sidebarShell ? H.sidebarShell("w1").then((d) => JSON.parse(d)?.hover ?? null) : Promise.resolve(null));
`;
const ROWS = [90, 130, 170, 210];
const COVER = [0, 0, 320, 800];
let app = null;
let native = false;
const run = (body) => app.eval(`${HELPERS}\n${body}`, { timeout: 30000 });
const entersAt = (y) =>
  native
    ? run(`return at(700, 400).then(() => at(120, ${y})).then(hover).then((k) => (k ? 1 : 0));`)
    : run(`return at(700, 400).then(stats).then(() => at(120, ${y})).then(stats).then((s) => count(s, "enter"));`);
const cover = (rect, hidden) => `S.devCover("w1", ${JSON.stringify(rect)}, ${JSON.stringify(hidden)}).then(() => settle(250))`;

try {
  app = await launch(resolve(appArg), {
    data, fresh: true, session: fixture, onboarded: true,
    env: nativeColumn ? { ARDIA_NATIVE_SHELL: "1", ARDIA_NATIVE_SIDEBAR: "1", ARDIA_NATIVE_TOP_STRIP: "1", ARDIA_NATIVE_PROFILE_PAGER: "1" } : { ARDIA_NATIVE_SHELL: "1", ARDIA_NATIVE_SIDEBAR: "0" },
    ready: "return !!ac.store.getState().windows.w1 && !!globalThis.expo.modules.SolaraWindowShell.devCover",
  });
  await sleep(2000);
  native = await run(`return H?.sidebarShell ? H.sidebarShell("w1").then((d) => d !== "null") : false;`);

  await rep.check("rows-hover", async () => {
    const enters = [];
    for (const y of ROWS) enters.push(await entersAt(y));
    if (enters.some((n) => n === 0)) throw new Error(`a row didn't hover: ${enters}`);
    return { native, enters };
  });

  await rep.check("covered-rows-dont-hover", async () => {
    if (!(await run(`return S.devCover("w1", ${JSON.stringify(COVER)}, null);`))) throw new Error("no shell host for w1");
    try {
      const enters = [];
      for (const y of ROWS) enters.push(await entersAt(y));
      if (enters.some((n) => n !== 0)) throw new Error(`rows under the native view hovered: ${enters}`);
      return enters;
    } finally {
      await run(`return S.devCover("w1", null, null);`);
    }
  });

  await rep.check("still-pointer-follows-the-cover", async () => {
    if (native) {
      await run(`return at(700, 400);`);
      const parked = await run(`return at(120, 130).then(hover);`);
      const out = { parked, coverOn: await run(`return ${cover(COVER, null)}.then(hover);`), coverOff: await run(`return ${cover(null, null)}.then(hover);`) };
      if (!parked || out.coverOn !== null || out.coverOff !== parked) throw new Error(`hover didn't follow the cover: ${JSON.stringify(out)}`);
      return out;
    }
    await run(`return at(700, 400).then(stats);`);
    const parked = await run(`return at(120, 130).then(stats).then((s) => count(s, "enter"));`);
    const on = await run(`return S.devCover("w1", ${JSON.stringify(COVER)}, null).then(() => settle(250)).then(stats).then((s) => [count(s, "leave"), count(s, "enter")]);`);
    const off = await run(`return S.devCover("w1", null, null).then(() => settle(250)).then(stats).then((s) => count(s, "enter"));`);
    const out = { parked, coverOn: on, coverOff: off };
    if (!parked || on[0] !== parked || on[1] !== 0 || off !== parked) throw new Error(`hover didn't follow the cover: ${JSON.stringify(out)}`);
    return out;
  });

  await rep.check("a-hidden-cover-gives-hover-back", async () => {
    if (native) {
      await run(`return at(700, 400);`);
      const parked = await run(`return at(120, 130).then(hover);`);
      const out = { parked, shown: await run(`return ${cover(COVER, null)}.then(hover);`), hidden: await run(`return ${cover(null, true)}.then(hover);`), again: await run(`return ${cover(null, false)}.then(hover);`) };
      await run(`return S.devCover("w1", null, null);`);
      if (!parked || out.shown !== null || out.hidden !== parked || out.again !== null) throw new Error(`hover didn't follow the cover's isHidden: ${JSON.stringify(out)}`);
      return out;
    }
    await run(`return at(700, 400).then(stats);`);
    const parked = await run(`return at(120, 130).then(stats).then((s) => count(s, "enter"));`);
    const shown = await run(`return S.devCover("w1", ${JSON.stringify(COVER)}, null).then(() => settle(250)).then(stats).then((s) => count(s, "leave"));`);
    const hidden = await run(`return S.devCover("w1", null, true).then(() => settle(250)).then(stats).then((s) => count(s, "enter"));`);
    const again = await run(`return S.devCover("w1", null, false).then(() => settle(250)).then(stats).then((s) => count(s, "leave"));`);
    await run(`return S.devCover("w1", null, null);`);
    const out = { parked, shown, hidden, again };
    if (!parked || shown !== parked || hidden !== parked || again !== parked) throw new Error(`hover didn't follow the cover's isHidden: ${JSON.stringify(out)}`);
    return out;
  });

  const PEEK = "a-cover-over-the-peeking-sidebar-takes-its-hover";
  if (!native) rep.record(PEEK, { skip: "RN sidebar" });
  else await rep.check(PEEK, async () => {
    await run(`if (ac.store.getState().windows.w1.sidebarOpen) ac.store.getState().toggleSidebar("w1"); return settle(900);`);
    try {
      await run(`return ac.shell.devLeftEdgePointer("w1", { x: -4, y: 300 }).then(() => settle(500));`);
      const peeking = await run(`return ac.shell.devLeftEdgePointer("w1", { x: 120, y: 300 }).then(() => settle(500)).then(() => "w1" in globalThis.acLayout.dockMotion.getState().peeks);`);
      const out = { peeking, parked: await run(`return at(120, 130).then(hover);`), covered: await run(`return ${cover(COVER, null)}.then(hover);`) };
      if (!peeking || !out.parked || out.covered !== null) throw new Error(`hover under the cover while peeking: ${JSON.stringify(out)}`);
      return out;
    } finally {
      await run(`return S.devCover("w1", null, null).then(() => ac.shell.devLeftEdgePointer("w1", null)).then(() => { if (!ac.store.getState().windows.w1.sidebarOpen) ac.store.getState().toggleSidebar("w1"); return settle(900); });`);
    }
  });

  await rep.check("layer-lookup-cost", async () => {
    const costs = [await run(`return S.devHitCost("w1", 120, 130);`), await run(`return S.devHitCost("w1", 700, 400);`)];
    const micros = costs.map((c) => Number(c.micros));
    const mainTop = process.env.ARDIA_SHELL_MAIN_TOP === "1";
    if (micros.some((m) => !(m < (mainTop ? 120 : 30)))) throw new Error(`layer lookup ${micros} µs`);
    if (!mainTop) return micros;
    const points = Array.from({ length: 240 }, (_, i) => (i % 2 ? [700 + (i % 7), 400] : [120, 130 + (i % 5)]));
    const stream = await run(`return S.devPointerStream("w1", ${JSON.stringify(points)}, 120);`);
    const frames = stream.seconds / stream.frame;
    if (!(stream.lookups <= frames + 1) || !(stream.coreShare <= 0.03)) throw new Error(`pointer stream ${JSON.stringify(stream)} over ${frames.toFixed(0)} frames`);
    return { perCall: micros, stream, frames, coreShareAt120Hz: stream.coreShare * 120 * stream.frame };
  });

  await rep.check("hover-within-a-frame", async () => {
    const moves = [];
    await run(`return S.devPointerLatency("w1", -1, -1);`);
    for (const [x, y] of [[120, 130], [-1, -1], [700, 400], [-1, -1], [120, 130], [-1, -1]]) {
      const moved = await run(`return S.devPointerLatency("w1", ${x}, ${y});`);
      moves.push([x, y, moved]);
      if (!moved.changed || !(moved.ms <= moved.frameMs + 1)) throw new Error(`hover took ${JSON.stringify(moves)}`);
      await sleep(50);
    }
    return moves;
  });
} catch (e) {
  rep.record("run", { error: e });
} finally {
  await app?.quit().catch(() => {});
  if (!keep && rep.results.every((r) => r.ok)) rmSync(scratch, { recursive: true, force: true });
}
const failed = rep.results.filter((r) => !r.ok);
console.log(`${rep.results.length - failed.length}/${rep.results.length} passed${failed.length ? `; log ${rep.logFile}` : ""}`);
process.exit(failed.length ? 1 : 0);

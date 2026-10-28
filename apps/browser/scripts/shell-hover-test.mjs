import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node shell-hover-test.mjs <Debug Solara.app> [--keep-data]

Hover goes to what's on top in a native window shell (ARDIA_NATIVE_SHELL=1): the RN sidebar's rows hover under the
pointer; under a native view mounted in the shell's overlay slot they don't; a row under a still pointer leaves when
the native view arrives and enters again when it goes, and the same when the native view is hidden and shown
without leaving the overlay; finding the layer under the pointer stays under 30 µs.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
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
`;
const ROWS = [90, 130, 170, 210];
const COVER = [0, 0, 320, 800];
let app = null;
const run = (body) => app.eval(`${HELPERS}\n${body}`, { timeout: 30000 });
const entersAt = (y) => run(`return at(700, 400).then(stats).then(() => at(120, ${y})).then(stats).then((s) => count(s, "enter"));`);

try {
  app = await launch(resolve(appArg), {
    data, fresh: true, session: fixture, onboarded: true,
    env: { ARDIA_NATIVE_SHELL: "1" },
    ready: "return !!ac.store.getState().windows.w1 && !!globalThis.expo.modules.SolaraWindowShell.devCover",
  });
  await sleep(2000);

  await rep.check("rows-hover", async () => {
    const enters = [];
    for (const y of ROWS) enters.push(await entersAt(y));
    if (enters.some((n) => n === 0)) throw new Error(`a row didn't hover: ${enters}`);
    return enters;
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
    await run(`return at(700, 400).then(stats);`);
    const parked = await run(`return at(120, 130).then(stats).then((s) => count(s, "enter"));`);
    const on = await run(`return S.devCover("w1", ${JSON.stringify(COVER)}, null).then(() => settle(250)).then(stats).then((s) => [count(s, "leave"), count(s, "enter")]);`);
    const off = await run(`return S.devCover("w1", null, null).then(() => settle(250)).then(stats).then((s) => count(s, "enter"));`);
    const out = { parked, coverOn: on, coverOff: off };
    if (!parked || on[0] !== parked || on[1] !== 0 || off !== parked) throw new Error(`hover didn't follow the cover: ${JSON.stringify(out)}`);
    return out;
  });

  await rep.check("a-hidden-cover-gives-hover-back", async () => {
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

  await rep.check("layer-lookup-cost", async () => {
    const costs = [await run(`return S.devHitCost("w1", 120, 130);`), await run(`return S.devHitCost("w1", 700, 400);`)];
    const micros = costs.map((c) => Number(c.micros));
    if (micros.some((m) => !(m < 30))) throw new Error(`layer lookup ${micros} µs`);
    return micros;
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

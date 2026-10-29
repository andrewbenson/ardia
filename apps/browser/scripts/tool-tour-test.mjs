import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node tool-tour-test.mjs <Debug Solara.app> [--rn | --native] [--keep-data]

--rn and --native pick the tour (ARDIA_NATIVE_TOOL_TOUR=0 or 1); the checks are the same for both.

Starts the tool tour in a fresh window (1360×860) and clicks through it in-process: a click inside the spotlight
reaches the page, one on the dimmed rest does nothing, Next and Back step, Done ends it, and a skipped tour stays
gone.`);
  process.exit(2);
}
const appPath = resolve(appArg);
const native = !args.includes("--rn");
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-tool-tour-"));
const data = join(scratch, "data");
const rep = reporter(join(scratch, "tool-tour-test.log"), { name: "tool-tour-test" });

const HELPERS = `
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const st = ac.store.getState();
const wid = st.windowOrder?.[0] ?? Object.keys(st.windows)[0];
const tour = () => { const t = acTour.store.getState(); return { index: t.index, active: t.windowId === wid && t.stops.length > 0, stops: t.stops.map((s) => s.id) }; };
const click = (x, y) => ac.shell.devClick(wid, { x, y }).then((r) => settle(900).then(() => ({ hit: r.hit, ...tour() })));
`;

let app = null;
const run = (body) => app.eval(`${HELPERS}\n${body}`, { timeout: 20000 });
try {
  app = await launch(appPath, { data, onboarded: true, env: { ARDIA_NATIVE_TOOL_TOUR: native ? "1" : "0" } });
  rep.log(`instance: pid ${app.pid}, data ${data}`);
  await app.ready({ test: "return !!globalThis.acTour && !!globalThis.ac?.store" });
  await rep.check(`the ${native ? "native" : "RN"} tour steps, passes clicks through its spotlight and stays closed`, () => tourChecks());
} finally {
  await app?.quit();
  if (!keep) rmSync(data, { recursive: true, force: true });
  else rep.say(`data: ${data}`);
}
process.exit(rep.summary() ? 0 : 1);

async function tourChecks() {
  const kinds = await app.eval("return globalThis.expo.modules.SolaraHosted?.kinds() ?? [];");
  assert.equal(kinds.includes("toolTour"), native, `the toolTour kind is ${native ? "missing" : "registered"}`);
  rep.log(`tour: ${native ? "native" : "RN"}`);

  const started = await run("return acTour.start(wid).then(() => settle(1500)).then(tour);");
  assert.deepEqual(started.stops, ["commandBar", "tabs", "sidebar", "split", "done"], "every stop finds its anchor");
  assert.equal(started.active, true);

  const hole = await run("return click(700, 380);");
  assert.notEqual(hole.hit, "ToolTourHost", "a click in the spotlight reaches the page");
  assert.equal(hole.index, 0);
  const scrim = await run("return click(100, 600);");
  assert.equal(scrim.active, true, "a click on the dim leaves the tour up");
  assert.equal(scrim.index, 0, "a click on the dim doesn't step");
  rep.log("spotlight passes clicks through, the dim swallows them");

  const steps = [
    ["Next on 1", 875, 604, 1],
    ["Back on 2", 392, 192, 0],
    ["Next on 1", 875, 604, 1],
    ["Next on 2", 452, 192, 2],
    ["Next on 3", 433, 200, 3],
    ["Next on 4 (inside the spotlight)", 874, 663, 4],
  ];
  for (const [label, x, y, index] of steps) {
    const after = await run(`return click(${x}, ${y});`);
    assert.equal(after.index, index, `${label} goes to stop ${index + 1} (hit ${after.hit})`);
    rep.log(`${label} → stop ${index + 1}`);
  }
  const done = await run("return click(781, 589);");
  assert.equal(done.active, false, "Done ends the tour");
  rep.log("Done ends it");

  await run("return acTour.start(wid).then(() => settle(1500));");
  const skipped = await run("return click(669, 604).then(() => settle(1500)).then(tour);");
  assert.equal(skipped.active, false, "Skip Tour ends it and it stays gone");
  rep.log("Skip Tour ends it, still gone 1.5 s later");
  return "5 stops, 6 steps, Done and Skip";
}

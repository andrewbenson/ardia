#!/usr/bin/env node
// End-to-end import into the native (SwiftUI) Import window of a hidden instance, from packages/import's fake Chrome
// home (never a real profile). It drives the window's model through SolaraSettings.devImport (background instances
// only) instead of clicks, and checks the imported cookies, addresses and cards.
//
//   node packages/settings/scripts/import-e2e.mjs <Solara.app> <scratch dir>
//
//   <Solara.app>     a Release build (JS bundled); it runs hidden with its own data dir under <scratch dir>/data
//   <scratch dir>    data/ and home/ are wiped first; result.txt lists one line per check
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { launch, sleep } from "../../../scripts/lib/instance.mjs";

const [app, scratch] = process.argv.slice(2).map((p) => path.resolve(p));
if (!app || !scratch || app.startsWith("/Applications/")) {
  console.log("usage: import-e2e.mjs <Solara.app under apps/browser/build-*> <scratch dir>");
  process.exit(64);
}
const DATA = path.join(scratch, "data");
const HOME = path.join(scratch, "home");
const SECRET = "e2e-test-secret";
for (const dir of [DATA, HOME]) fs.rmSync(dir, { recursive: true, force: true });
execFileSync("python3", [new URL("../../import/scripts/e2e_fixture.py", import.meta.url).pathname, HOME, SECRET, "8765"], { stdio: "ignore" });

const inst = await launch(app, {
  data: DATA,
  js: "none",
  probe: true,
  onboarded: true,
  env: { SOLARA_IMPORT_SOURCE_DIR: `${HOME}/Library/Application Support`, SOLARA_IMPORT_TEST_SECRET: SECRET },
});
const run = (body) => inst.eval(body);
const results = [];
const ok = (cond, msg) => {
  const line = `${cond ? "ok  " : "FAIL"} ${msg}`;
  results.push(line);
  console.log(line);
};
try {
  const drive = (action, arg = null) => run(`return globalThis.expo.modules.SolaraSettings.devImport(${JSON.stringify(action)}, ${JSON.stringify(arg)})`);
  await run(`ac.runCommand({ command: "importBrowserData", arg: null, windowId: null }); return true`);
  let state = {};
  for (const deadline = Date.now() + 30000; Date.now() < deadline; await sleep(300)) {
    state = await drive("state");
    if (state.step === "choose") break;
  }
  ok(state.step === "choose", `native import window opened on choose (${state.step ?? state.error})`);
  ok(state.browsers?.includes("chrome"), `Chrome fixture listed (${state.browsers})`);
  state = await drive("select", "chrome");
  ok(state.kinds.includes("cookies") && state.kinds.includes("autofill"), `cookies and autofill on (${state.kinds})`);
  state = await drive("next");
  for (const deadline = Date.now() + 10000; !["unlock", "progress", "done"].includes(state.step) && Date.now() < deadline; await sleep(300)) state = await drive("state");
  ok(state.step === "unlock", `unlock step for encrypted kinds (${state.step})`);
  state = await drive("unlock");
  for (const deadline = Date.now() + 60000; state.step !== "done" && Date.now() < deadline; await sleep(500)) state = await drive("state");
  console.log("done:", JSON.stringify(state));
  ok(state.step === "done", "reached done");
  ok(state.counts.cookies === 5, `5 cookies (${state.counts.cookies})`);
  ok(state.counts.addresses === 1 && state.counts.cards === 1, `1 address, 1 card (${state.counts.addresses}, ${state.counts.cards})`);
  ok(state.failures.length === 0, `no failures (${JSON.stringify(state.failures)})`);
  ok(state.notes.some((n) => n.includes("1 cookie couldn't be decrypted")), `undecryptable note (${JSON.stringify(state.notes)})`);
  const log = fs.readFileSync(path.join(DATA, "app.out.log"), "utf8");
  ok(!/LogBox|Unhandled JS Exception|RedBox/i.test(log), "no LogBox or JS exception in the log");
} catch (error) {
  ok(false, `threw: ${error}`);
} finally {
  await inst.quit().catch(() => {});
}
fs.writeFileSync(path.join(scratch, "result.txt"), results.join("\n") + "\n");
process.exit(results.some((r) => r.startsWith("FAIL")) ? 1 : 0);

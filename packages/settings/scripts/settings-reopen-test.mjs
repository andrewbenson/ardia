#!/usr/bin/env node
// The native Settings window, opened, closed and opened again, in a hidden instance: each window is key and takes
// typing; a query typed before closing comes back selected, so the next key replaces it. Both opens go through the
// pre-built controller, as they do after launch.
//
//   node packages/settings/scripts/settings-reopen-test.mjs <Solara.app under apps/browser/build-*> [--keep-data]
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg || resolve(appArg).startsWith("/Applications/")) {
  console.error("usage: node settings-reopen-test.mjs <Solara.app under apps/browser/build-*> [--keep-data]");
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-settings-reopen-"));
const data = join(scratch, "data");
const rep = reporter(join(scratch, "settings-reopen-test.log"), { name: "settings-reopen-test" });
let app = null;
const dev = (action, argument) =>
  app.eval(`return globalThis.expo.modules.SolaraSettings.devSettings(${JSON.stringify(action)}, ${JSON.stringify(argument ?? null)}).then(JSON.parse)`);
const opened = async () => {
  await app.eval(`ac.openSettings("privacy"); return true`);
  await sleep(1500);
  return dev("state");
};

try {
  app = await launch(resolve(appArg), { data, onboarded: true });
  await app.ready({ test: "return !!globalThis.expo?.modules?.SolaraSettings?.devSettings" });
  await sleep(7000);

  await rep.check("the first window is key and takes typing", async () => {
    const first = await opened();
    assert.equal(first.key, true, "key");
    await app.eval(`globalThis.expo.modules.SolaraSettings.focusSearch(); return true`);
    await sleep(300);
    const typed = await dev("type", "cookie");
    assert.equal(typed.query, "cookie", `first responder: ${typed.firstResponder}`);
    return typed.firstResponder;
  });

  await rep.check("a reopened window is key, and the next key replaces the kept query", async () => {
    await dev("close");
    await sleep(1000);
    assert.equal((await dev("state")).window, false, "closed");
    const again = await opened();
    assert.equal(again.key, true, "key");
    assert.equal(again.query, "cookie", "the kept query");
    const typed = await dev("type", "x");
    assert.equal(typed.query, "x", `first responder: ${typed.firstResponder}`);
    return typed.firstResponder;
  });
} finally {
  await app?.quit();
  if (!keep) rmSync(data, { recursive: true, force: true });
  else rep.say(`data: ${data}`);
}
process.exit(rep.summary() ? 0 : 1);

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

test("SolaraUI's New Tab theme tokens match theme.ts", () => {
  const script = fileURLToPath(new URL("../../../../native/SolaraKit/Scripts/newtab-theme.mts", import.meta.url));
  const run = spawnSync(process.execPath, [script, "--check"], { encoding: "utf8" });
  assert.equal(run.status, 0, run.stderr);
});

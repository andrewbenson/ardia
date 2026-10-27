import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { binaryPids, binaryOf, commandIsBinary, isAlive, launch, realPath } from "./instance.mjs";

const lowerHome = (path) => path.replace(/^\/Users\/([^/]+)\/Developer\/Personal\//, "/Users/$1/Developer/personal/");

test("a binary matches its command line whatever the path's case", () => {
  const binary = "/Users/me/Developer/Personal/ardia/apps/browser/build-x/Solara.app/Contents/MacOS/Solara";
  assert.ok(commandIsBinary(binary, binary.toLowerCase()));
  assert.ok(commandIsBinary(`${binary} --flag`, binary.replace("Personal", "personal")));
  assert.ok(!commandIsBinary(`${binary}Helper --type=renderer`, binary));
  assert.ok(!commandIsBinary("/Applications/Solara.app/Contents/MacOS/Solara", binary));
});

test("realPath gives the spelling on disk", () => {
  const dir = mkdtempSync(join(tmpdir(), "instance-case-"));
  try {
    assert.equal(realPath(dir.toUpperCase().replace(/^\/PRIVATE/, "/private")), realPath(dir));
  } finally {
    rmSync(dir, { recursive: true });
  }
});

const app = process.env.INSTANCE_TEST_APP;
test("an instance launched by a differently cased path is recorded and quits", { skip: !app && "set INSTANCE_TEST_APP to a Debug Solara.app" }, async () => {
  const data = mkdtempSync(join(tmpdir(), "instance-case-data-"));
  const binary = realPath(binaryOf(app));
  const before = binaryPids(binary);
  let instance = null;
  try {
    instance = await launch(lowerHome(realPath(app)), { data, onboarded: true });
    assert.ok(instance.stillOwned(), "the launched app is the one recorded");
    assert.equal((await instance.quit()).how, "quit");
    assert.ok(!isAlive(instance.pid));
  } finally {
    if (instance?.stillOwned()) await instance.quit({ graceful: false });
    const left = [...binaryPids(binary)].filter((pid) => !before.has(pid));
    rmSync(data, { recursive: true, force: true });
    assert.deepEqual(left, [], "no instance left running");
  }
});

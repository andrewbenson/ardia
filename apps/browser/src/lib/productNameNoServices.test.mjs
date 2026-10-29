import assert from "node:assert/strict";
import { test } from "node:test";
const { appInfo } = await import("../test-native/index.ts");

appInfo.appName = "Solara";
appInfo.switchesURL = "";
appInfo.updateFeedURL = "";

const { SERVICES } = await import("./productName.ts");

test("a build with no service URLs names no server", () => {
  assert.deepEqual(SERVICES, { updateHost: null, switchFile: null });
});

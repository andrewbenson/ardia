import assert from "node:assert/strict";
import { test } from "node:test";
const { appInfo } = await import("../test-native/index.ts");

appInfo.appName = "Solara";
appInfo.telemetryURL = "";
appInfo.switchesURL = "";
appInfo.updateFeedURL = "";

const { SERVICES } = await import("./productName.ts");
const { SHARING_COPY, WHATS_SENT } = await import("../telemetry/copy.ts");

test("a build with no service URLs names no server and says nothing is sent", () => {
  assert.deepEqual(SERVICES, { telemetryHost: null, updateHost: null, switchFile: null });
  const copy = JSON.stringify([SHARING_COPY, WHATS_SENT]);
  assert.doesNotMatch(copy, /ardia\.dev|null/);
  assert.equal(SHARING_COPY.footnote, "Nothing is sent: this copy of Solara has no diagnostics server.");
  assert.equal(SHARING_COPY.switchFile, "No switch file is read at launch: nothing is sent.");
  assert.equal(SHARING_COPY.dailyCountShort, "Solara sends nothing: no crash reports, no usage stats, no daily count.");
});

import assert from "node:assert/strict";
import { test } from "node:test";
import { emitAppEvent, windows } from "../test-native/shell.ts";

let safeMode = "option";
const calls = [];
globalThis.acTestNativeModules = {
  ArdiaStore: { status: () => ({ active: false, safeMode }) },
  SolaraSettings: {
    liveInitialReplica: () => ({ revision: 0, replicaJSON: "{}" }),
    liveStart: async () => { calls.push("start"); },
    liveCommand: async (name) => { calls.push(name); return JSON.stringify({ revision: 0 }); },
    liveMeetingBrowser: async () => { calls.push("meetingBrowser"); },
    addListener: () => ({ remove() {} }),
  },
};
const { startNativeStore } = await import("../store/nativeStore.ts");
const { startLiveEngine } = await import("../live/engine.ts");
const { startMeetingGroups } = await import("../live/meetingGroups.ts");
const { updateCalendarSettings } = await import("../live/store.ts");

for (const safe of [true, false]) {
  test(`${safe ? "safe" : "normal"} Live automatic subscriptions and explicit calendar command`, async () => {
    safeMode = safe ? "option" : null;
    startNativeStore();
    calls.length = 0;
    startLiveEngine();
    startMeetingGroups();
    windows.emit({ type: "focus", windowId: "fixture" });
    emitAppEvent({ type: "resignActive" });
    await new Promise((resolve) => setTimeout(resolve, 150));
    assert.deepEqual(calls, safe ? [] : ["start", "windowFocused", "appResignedActive", "meetingBrowser"]);
    calls.length = 0;
    await updateCalendarSettings({ alertLead: "10" });
    assert.deepEqual(calls, ["updateCalendarSettings"]);
  });
}

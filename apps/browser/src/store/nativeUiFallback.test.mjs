import assert from "node:assert/strict";
import { test } from "node:test";

const sent = [];
globalThis.acTestNativeModules = {
  ArdiaStore: {
    status: () => ({ active: true, scope: "settingsAndDownloads" }),
    snapshot: () => JSON.stringify({ rev: 0, data: { settings: { chosen: [], inferred: [] }, downloads: [] } }),
    dispatch: (json) => {
      sent.push(...[JSON.parse(json)].flat());
      return JSON.stringify({ rev: 0, patches: [] });
    },
    addListener: () => ({ remove() {} }),
  },
};
const { useBrowser } = await import("./browser.ts");
const { startPersistence } = await import("../lib/persist.ts");
const { writeState } = await import("./nativeStore.ts");
const S = () => useBrowser.getState();
startPersistence();

test("settingsAndDownloads keeps JS appearance and find reducers and pruning", () => {
  const windowId = S().createWindow();
  const tabId = S().windows[windowId].tabIds[0];
  sent.length = 0;
  S().setAppDark(false);
  assert.equal(S().ui.appDark, false);
  S().setFind(tabId, { open: true, query: "fallback" });
  S().setFind(tabId, { count: 2, active: 1 });
  assert.deepEqual(S().find[tabId], { open: true, query: "fallback", count: 2, active: 1 });
  S().setFind("missing", { open: true });
  assert.equal(S().find.missing, undefined);
  writeState(useBrowser, { ui: { ...S().ui, appDark: true } });
  assert.equal(S().ui.appDark, true);
  assert.ok(!sent.some((c) => ["setFind", "setAppDark"].includes(c.name)));
  S().closeTab(tabId);
  assert.equal(S().find[tabId], undefined);
});

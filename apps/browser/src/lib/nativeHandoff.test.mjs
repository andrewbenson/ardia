import assert from "node:assert/strict";
import { test } from "node:test";

globalThis.acTestNativeModules = {
  ArdiaStore: {
    status: () => ({ active: false, reason: "another instance (pid 1) is using this data folder", handedOff: true }),
    snapshot: () => null,
    dispatch: () => null,
    catchUp: () => null,
    flush: () => false,
    addListener: () => ({ remove() {} }),
  },
};

const { docs } = await import("../test-native/index.ts");
const { useBrowser } = await import("../store/browser.ts");
const { flushPersistence, startPersistence } = await import("./persist.ts");

test("when another instance holds the data folder, this one writes neither session.json nor downloads.json", () => {
  const session = JSON.stringify({ version: 2, settings: { searchEngine: "bing" }, windows: [], tabs: [] });
  const downloads = JSON.stringify({ version: 2, downloads: [] });
  docs.set("session.json", session);
  docs.set("downloads.json", downloads);
  startPersistence();
  useBrowser.getState().updateSettings({ appearance: "dark" });
  useBrowser.getState().upsertDownload({ id: "d", url: "https://e/", state: "complete", profile: "" });
  flushPersistence({ final: true });
  assert.equal(docs.get("session.json"), session);
  assert.equal(docs.get("downloads.json"), downloads);
});

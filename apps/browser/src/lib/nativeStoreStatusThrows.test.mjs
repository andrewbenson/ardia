import assert from "node:assert/strict";
import { test } from "node:test";

const reason = "the store module threw";
globalThis.acTestNativeModules = {
  SolaraStoreAdapter: {
    status: () => {
      throw new Error(reason);
    },
    snapshot: () => null,
    dispatch: () => null,
    catchUp: () => null,
    flush: () => false,
    freeze: () => true,
    addListener: () => ({ remove() {} }),
  },
};

const { docs } = await import("../test-native/index.ts");
const { useBrowser } = await import("../store/browser.ts");
const { flushPersistence, startPersistence } = await import("./persist.ts");

test("with the store module present but its status throwing, nothing writes through the JS path", () => {
  const session = JSON.stringify({ version: 2, settings: { searchEngine: "bing" }, windows: [], tabs: [] });
  docs.set("session.json", session);
  docs.delete("downloads.json");
  const errors = [];
  const error = console.error;
  console.error = (...args) => errors.push(args.join(" "));
  try {
    startPersistence();
  } finally {
    console.error = error;
  }
  assert.notEqual(useBrowser.getState().settings.searchEngine, "bing", "the JS session wasn't loaded");
  useBrowser.getState().createWindow({ url: "https://lost.example/" });
  useBrowser.getState().updateSettings({ appearance: "dark" });
  useBrowser.getState().upsertDownload({ id: "d", url: "https://e/", state: "complete", profile: "" });
  flushPersistence({ final: true });
  assert.equal(docs.get("session.json"), session, "session.json is untouched");
  assert.equal(docs.has("downloads.json"), false, "downloads.json isn't written");
  assert.ok(errors.some((e) => e.includes("saves nothing") && e.includes(reason)), "the reason is reported");
});

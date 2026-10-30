import assert from "node:assert/strict";
import { test } from "node:test";

const sent = [];
let rev = 0;
globalThis.acTestNativeModules = {
  ArdiaStore: {
    status: () => ({ active: true, scope: "settingsAndDownloads", safeMode: "failedLaunches" }),
    snapshot: () => JSON.stringify({ rev, data: { settings: { searchEngine: "duckduckgo" }, downloads: [{ id: "kept", state: "complete", url: "https://download.example", profile: "" }] } }),
    dispatch: (json) => { sent.push(...[JSON.parse(json)].flat()); return JSON.stringify({ rev: ++rev }); },
    catchUp: () => JSON.stringify({ rev }),
    flush: () => true,
    addListener: () => ({ remove() {} }),
  },
};
const { docs, unreadableDocs } = await import("../test-native/index.ts");
const { shellNativeModules } = await import("../test-native/shell.ts");
const reads = [];
const read = shellNativeModules.ArdiaShell.readDocumentResult;
shellNativeModules.ArdiaShell.readDocumentResult = (name) => { reads.push(name); return read(name); };
const { useBrowser } = await import("../store/browser.ts");
const { startPersistence, flushPersistence } = await import("./persist.ts");
const { persistenceRefused } = await import("./persistLatch.ts");
const { useToasts } = await import("../components/layout/toasts.ts");

test("safe settings-only startup bypasses an unreadable saved session and hydrates before its notice", () => {
  docs.set("session.json", "untouched bytes");
  unreadableDocs.set("session.json", "permission denied");
  const stop = startPersistence();
  assert.equal(persistenceRefused(), false);
  assert.equal(reads.includes("session.json"), false);
  assert.equal(useBrowser.getState().settings.searchEngine, "duckduckgo");
  assert.deepEqual(useBrowser.getState().downloads.map((d) => d.id), ["kept"]);
  assert.ok(sent.some((c) => c.name === "applyState"));
  const id = useBrowser.getState().createWindow({ url: "" });
  assert.equal(useToasts.getState().toasts[id]?.title, "Solara started in safe mode");
  flushPersistence({ final: true });
  stop();
  assert.equal(docs.get("session.json"), "untouched bytes");
});

import assert from "node:assert/strict";
import { test } from "node:test";

const { docs, shellNativeModules } = await import("../test-native/index.ts");
delete shellNativeModules.ArdiaShell.readDocumentResult;
const { useBrowser } = await import("../store/browser.ts");
const { useToasts } = await import("../components/layout/toasts.ts");
const { flushPersistence, startPersistence } = await import("./persist.ts");
const { persistenceRefused } = await import("./persistLatch.ts");

test("on a build without readDocumentResult, a readable session loads and saves exactly as before", () => {
  docs.set("session.json", JSON.stringify({ version: 2, settings: { searchEngine: "bing" }, windows: [], tabs: [] }));
  startPersistence();
  assert.equal(useBrowser.getState().settings.searchEngine, "bing");
  useBrowser.getState().createWindow({ url: "https://old-binary.example/" });
  flushPersistence({ final: true });
  assert.equal(persistenceRefused(), false);
  assert.match(docs.get("session.json") ?? "", /old-binary\.example/);
  assert.deepEqual(useToasts.getState().notices, {});
});

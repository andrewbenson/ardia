import assert from "node:assert/strict";
import { test } from "node:test";

const { docs, unreadableDocs } = await import("../test-native/index.ts");
const { useBrowser } = await import("../store/browser.ts");
const { flushPersistence, startPersistence } = await import("./persist.ts");

test("without the native store, a downloads.json that exists but can't be read is never replaced, and the session still saves", () => {
  docs.set("session.json", JSON.stringify({ version: 2, windows: [], tabs: [] }));
  unreadableDocs.set("downloads.json", "Permission denied");
  startPersistence();
  const s = useBrowser.getState();
  s.createWindow({ url: "https://kept.example/" });
  s.upsertDownload({ id: "d", url: "https://e/", state: "complete", profile: "" });
  flushPersistence({ final: true });
  assert.equal(docs.has("downloads.json"), false);
  assert.match(docs.get("session.json") ?? "", /kept\.example/);
});

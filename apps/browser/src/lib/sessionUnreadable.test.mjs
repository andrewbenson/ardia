import assert from "node:assert/strict";
import { test } from "node:test";

const { docs, unreadableDocs } = await import("../test-native/index.ts");
const { useBrowser } = await import("../store/browser.ts");
const { useToasts } = await import("../components/layout/toasts.ts");
const { flushPersistence, startPersistence } = await import("./persist.ts");

test("without the native store, a session.json that exists but can't be read is never replaced", () => {
  unreadableDocs.set("session.json", "Permission denied");
  startPersistence();
  const s = useBrowser.getState();
  const windowId = s.createWindow({});
  s.newTab(windowId, { url: "https://after.example/" });
  s.updateSettings({ appearance: "dark" });
  flushPersistence({ final: true });
  assert.equal(docs.has("session.json"), false);
  assert.equal(docs.has("downloads.json"), false);
  const notice = useToasts.getState().notices[windowId];
  assert.match(notice?.message ?? "", /won't be saved.*\/data\/session\.json/);
});

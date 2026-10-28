import assert from "node:assert/strict";
import { test } from "node:test";

const { docs, unreadableDocs } = await import("../test-native/index.ts");
const { useBrowser } = await import("../store/browser.ts");
const { flushPersistence, resumePersistence, startPersistence } = await import("./persist.ts");
const { appInfo } = await import("../test-native/index.ts");
const { trackAppVersion } = await import("../components/ntp/releaseNotes.ts");

test("a refused launch stays refused through a cancelled quit: nothing writes, the launch look included", () => {
  unreadableDocs.set("session.json", "Permission denied");
  startPersistence();
  const before = new Map(docs);
  const s = useBrowser.getState();
  const windowId = s.createWindow({ url: "https://before-quit.example/" });
  flushPersistence({ final: true });
  resumePersistence();
  s.newTab(windowId, { url: "https://after-cancel.example/" });
  s.updateSettings({ appearance: "dark" });
  flushPersistence();
  flushPersistence({ final: true });
  assert.deepEqual(new Map(docs), before);
});

test("a refused launch isn't a first run or an update, so What's New stays quiet and writes nothing", () => {
  appInfo.appVersion = "9.9";
  const before = new Map(docs);
  assert.equal(trackAppVersion(), false);
  assert.deepEqual(new Map(docs), before);
});

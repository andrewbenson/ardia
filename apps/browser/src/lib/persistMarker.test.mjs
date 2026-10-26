import assert from "node:assert/strict";
import { test } from "node:test";
import { docs } from "../test-native/index.ts";
import { useBrowser } from "../store/browser.ts";
import { flushPersistence, startPersistence } from "./persist.ts";

test("without the native store, session.json carries no nativeExport marker and downloads.json is still written", () => {
  docs.set("session.json", JSON.stringify({ version: 2, settings: { searchEngine: "bing" }, windows: [], tabs: [] }));
  docs.set("downloads.json", JSON.stringify({ version: 2, downloads: [] }));
  startPersistence();
  useBrowser.getState().updateSettings({ appearance: "dark" });
  useBrowser.getState().upsertDownload({ id: "d", url: "https://e/", state: "complete", profile: "" });
  flushPersistence();
  const session = JSON.parse(docs.get("session.json"));
  assert.equal(session.settings.appearance, "dark");
  assert.equal("nativeExport" in session, false);
  assert.deepEqual(JSON.parse(docs.get("downloads.json")).downloads.map((d) => d.id), ["d"]);
});

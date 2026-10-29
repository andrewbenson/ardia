import assert from "node:assert/strict";
import { test } from "node:test";
import { docs } from "../test-native/index.ts";
import { useBrowser } from "../store/browser.ts";
import { flushPersistence, startPersistence } from "./persist.ts";

test("with no store module at all, as in Node tests, the JS path loads and saves the session", () => {
  docs.set("session.json", JSON.stringify({ version: 2, settings: { searchEngine: "bing" }, windows: [], tabs: [] }));
  const stop = startPersistence();
  assert.equal(useBrowser.getState().settings.searchEngine, "bing", "the session loaded");
  useBrowser.getState().updateSettings({ appearance: "dark" });
  flushPersistence();
  stop();
  assert.equal(JSON.parse(docs.get("session.json")).settings.appearance, "dark", "the change was saved");
});

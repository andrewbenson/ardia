import assert from "node:assert/strict";
import { test } from "node:test";

globalThis.acTestNativeModules = {
  ArdiaStore: {
    status: () => ({ active: true, scope: "everything" }),
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

test("when the native store owns the workspace but returns none, nothing is saved and the failure is reported", () => {
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
  useBrowser.getState().createWindow({ url: "https://lost.example/" });
  flushPersistence({ final: true });
  assert.equal(docs.get("session.json"), session);
  assert.equal(docs.has("downloads.json"), false);
  assert.ok(errors.some((e) => e.includes("saves nothing")));
});

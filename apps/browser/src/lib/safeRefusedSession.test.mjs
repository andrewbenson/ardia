import assert from "node:assert/strict";
import { test } from "node:test";

globalThis.acTestNativeModules = { ArdiaStore: { status: () => ({ active: false, safeMode: "option", refusedSession: "/data/session.json", reason: "no usable database" }), freeze: () => true } };
const { shellNativeModules } = await import("../test-native/shell.ts");
const reads = [];
shellNativeModules.ArdiaShell.readDocumentResult = (name) => { reads.push(name); return { path: `/data/${name}`, failure: "permission denied" }; };
const { startPersistence } = await import("./persist.ts");
const { persistenceRefused } = await import("./persistLatch.ts");

test("safe startup never reads or refuses a session reported unreadable by the native store", () => {
  const error = console.error;
  const errors = [];
  console.error = (message) => errors.push(message);
  try {
    startPersistence()();
  } finally {
    console.error = error;
  }
  assert.deepEqual(reads, []);
  assert.equal(persistenceRefused(), false);
  assert.ok(errors.some((message) => message.includes("saves nothing")));
});

import assert from "node:assert/strict";
import { test } from "node:test";

let reply;
globalThis.acTestNativeModules = { ArdiaStore: { flush: () => reply } };
const { flushNativeStore } = await import("@ardia/store");

test("new JS accepts old Bool and new String native flush results", () => {
  for (const [native, expected] of [[true, "saved"], [false, "timedOut"], ["saved", "saved"], ["timedOut", "timedOut"], ["failed: rows: fixture", "failed: rows: fixture"]]) {
    reply = native;
    assert.equal(flushNativeStore(), expected);
  }
});

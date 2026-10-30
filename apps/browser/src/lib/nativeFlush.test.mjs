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

test("a safe launch with no database reports a skipped flush, which isn't a problem", async () => {
  const { flushProblem } = await import("@ardia/store");
  reply = "skipped: safe mode opened no database";
  assert.equal(flushNativeStore(), "skipped: safe mode opened no database");
  assert.equal(flushProblem(flushNativeStore()), false);
  assert.equal(flushProblem("saved"), false);
  for (const problem of ["timedOut", "failed: rows: fixture", "failed: the native store is unavailable"]) assert.equal(flushProblem(problem), true);
});

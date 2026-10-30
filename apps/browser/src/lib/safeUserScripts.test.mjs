import assert from "node:assert/strict";
import { test } from "node:test";
import { declaration, runNative, source } from "../test-native/safe-host/run.mjs";

test("the Swift script service refuses automatic synchronization in safe mode even with CLI enabled", () => {
  const text = source("packages/settings/ios/Services/NativeUserScripts.swift");
  const production = ["func startWhenReady(", "private func stateChanged("].map((name) => declaration(text, name)).join("\n");
  for (const result of runNative("UserScriptsDriver.swift", production, [], true)) {
    assert.equal(result.subscriptions, result.safe ? 0 : 1);
    assert.deepEqual(result.sync, result.safe ? [] : [true]);
  }
});

test("safe script reads and watchers create no files and status writes visibly refuse", () => {
  for (const result of runNative("UserScripts.swift", source("packages/shell/ios/UserScripts.swift"), [], true)) {
    assert.equal(result.createdByReadOrWatch, !result.safe);
    assert.equal(result.createdByStatus, !result.safe);
    assert.equal(result.status, result.safe ? "original" : "replacement");
    if (result.safe) assert.match(result.refusal, /safe mode/i);
    else assert.equal(result.refusal, "");
  }
});

import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { test } from "node:test";
import { source } from "../test-native/safe-host/run.mjs";
import { visitRecorder } from "../store/engines.ts";

const ts = createRequire(import.meta.url)("typescript");

for (const safe of [true, false]) {
  test(`automatic WebKit history visits are ${safe ? "refused" : "stored"} at the caller in mode ${safe}`, () => {
    const calls = [];
    const pending = new Map();
    let next = 0;
    const state = { tabs: { fixture: { profileId: "work" } } };
    const modules = {
      "@solara/settings": { nativeAddHistoryVisits: async (...args) => calls.push(args) },
      zustand: { create: () => () => ({}) },
      "../store/browser": { useBrowser: { getState: () => state, subscribe: () => () => {} } },
      "../store/engines": { visitRecorder },
      "../store/model": { engineProfile: (id) => id, isIncognitoProfile: () => false },
      "../store/nativeStore": { nativeSafeMode: () => safe },
    };
    const output = ts.transpileModule(source("apps/browser/src/lib/engines.ts"), { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText;
    const api = {};
    new Function("require", "exports", "setTimeout", "clearTimeout", output)((name) => modules[name] ?? {}, api,
      (run) => (pending.set(++next, run), next), (id) => pending.delete(id));
    api.noteWebKitPage("fixture", { url: "https://automatic.example/", title: "Automatic", isLoading: false, committedUrl: "https://automatic.example/" });
    for (const run of pending.values()) run();
    assert.equal(calls.length, safe ? 0 : 1);
    if (!safe) {
      assert.equal(calls[0][0], "work");
      assert.equal(calls[0][1][0].url, "https://automatic.example/");
      assert.equal(calls[0][1][0].title, "Automatic");
    }
  });
}

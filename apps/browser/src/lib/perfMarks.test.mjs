import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
import { test } from "node:test";
import vm from "node:vm";

function fixture() {
  let at = 1000;
  let watcher;
  let scheduled;
  const marks = [];
  const native = { setEnabled() {}, markFrame() {}, lastInput: () => [at, 1], drain: () => marks.splice(0) };
  const context = vm.createContext({
    NativeModules: { ACFieldTiming: native }, readDocument: () => "1", perfProbeEnabled: true,
    useBrowser: { subscribe: (callback) => { watcher = callback; } }, activeTabId: (s) => s.active,
    findLast: (list, test) => { for (let i = list.length - 1; i >= 0; i--) if (test(list[i])) return list[i]; },
    Date: class extends Date { static now() { return at; } },
    setTimeout: (callback) => { scheduled = callback; return 1; },
  });
  const source = readFileSync(new URL("./perfMarks.ts", import.meta.url), "utf8").replace(/^import .*;\n/gm, "").replace(/^export /gm, "");
  vm.runInContext(stripTypeScriptTypes(source, { mode: "strip" }) + "\nglobalThis.api = { startPerfMarks, journeyBarCommitted, journeyKeystroke, journeySuggestions, journeyQueryInvalidated, devJourneys };", context);
  const api = context.api;
  api.startPerfMarks();
  watcher({ active: "t", windows: { w: { profileId: "p" } }, tabs: { t: { url: "" } } }, { active: null, windows: { w: { profileId: "p" } }, tabs: {} });
  api.journeyBarCommitted("t");
  return { api, marks, advance: (next) => { at = next; }, tick: () => scheduled() };
}

test("J2 accepts only the latest query generation and its presentation frame", () => {
  const f = fixture();
  f.marks.push(["t", "typeable", 1000]);
  f.api.journeyKeystroke("t", "n", "epoch:1");
  f.advance(1001);
  f.api.journeyKeystroke("t", "n", "epoch:2");
  f.api.journeySuggestions("t", "n", "epoch:1", 1002);
  f.marks.push(["omnibox:t:epoch:1", "suggestFrame", 1003]);
  f.tick();
  assert.equal(f.api.devJourneys().samples.j2_suggest, undefined);
  assert.equal(f.api.devJourneys().queries[0].committedAt, undefined);
  f.api.journeySuggestions("t", "n", "epoch:2", 1004);
  f.marks.push(["omnibox:t:epoch:2", "suggest", 1004]);
  f.tick();
  assert.equal(f.api.devJourneys().samples.j2_suggest, undefined);
  f.marks.push(["omnibox:t:epoch:2", "suggestFrame", 1017]);
  f.tick();
  const state = f.api.devJourneys();
  assert.equal(state.samples.j2_suggest[0], 16);
  assert.equal(state.queries[1].shownAt, 1017);
  assert.equal(state.queries[1].committedAt, 1004);
});

test("an unrelated tab and generic suggest mark cannot complete a query sample", () => {
  const f = fixture();
  f.marks.push(["t", "typeable", 1000]);
  f.api.journeyKeystroke("t", "n", "epoch:1");
  f.api.journeySuggestions("other", "n", "epoch:1", 1001);
  f.marks.push(["t", "suggest", 1002], ["omnibox:other:epoch:1", "suggestFrame", 1003]);
  f.tick();
  assert.equal(f.api.devJourneys().samples.j2_suggest, undefined);
  assert.equal(f.api.devJourneys().queries[0].committedAt, undefined);
});


test("invalidation after commit prevents a later frame from satisfying the sample", () => {
  const f = fixture();
  f.marks.push(["t", "typeable", 1000]);
  f.api.journeyKeystroke("t", "n", "epoch:1");
  f.api.journeySuggestions("t", "n", "epoch:1", 1001);
  f.api.journeyQueryInvalidated("t", "epoch:1");
  f.marks.push(["omnibox:t:epoch:1", "suggestFrame", 1017]);
  f.tick();
  const state = f.api.devJourneys();
  assert.equal(state.samples.j2_suggest, undefined);
  assert.equal(state.queries[0].invalidated, true);
  assert.equal(state.queries[0].shownAt, undefined);
});

import assert from "node:assert/strict";
import { test } from "node:test";

const sent = [];
const listeners = new Set();
const native = {
  rev: 0,
  settings: { searchEngine: "google", chosen: [], inferred: [] },
  downloads: [],
  log: [],
  commit(patch) {
    this.rev += 1;
    const entry = { rev: this.rev, ...patch };
    this.log.push(entry);
    return entry;
  },
  since(rev) {
    return { rev: this.rev, patches: this.log.filter((p) => p.rev > rev) };
  },
};
globalThis.acTestNativeModules = {
  ArdiaStore: {
    status: () => ({ active: true }),
    snapshot: () => JSON.stringify({ rev: native.rev, data: { settings: native.settings, downloads: native.downloads } }),
    dispatch(json, sinceRev) {
      const commands = [JSON.parse(json)].flat();
      sent.push(...commands);
      for (const { name, args } of commands) {
        if (name === "updateSettings") {
          native.settings = { ...native.settings, ...args[0], chosen: [...new Set([...native.settings.chosen, ...Object.keys(args[0])])] };
          native.commit({ settings: { set: { ...args[0], chosen: native.settings.chosen } } });
        } else if (name === "applyState") {
          const patch = {};
          if (args[0].downloads) patch.downloads = native.downloads = args[0].downloads;
          if (args[0].settings) {
            native.settings = args[0].settings;
            patch.settings = { set: args[0].settings };
          }
          native.commit(patch);
        }
      }
      return JSON.stringify(native.since(sinceRev));
    },
    catchUp: (sinceRev) => JSON.stringify(native.since(sinceRev)),
    flush: () => true,
    addListener(_event, listener) {
      listeners.add(listener);
      return { remove: () => listeners.delete(listener) };
    },
  },
};

const { docs } = await import("../test-native/index.ts");
docs.set("session.json", JSON.stringify({ version: 2, settings: { searchEngine: "bing" }, windows: [], tabs: [] }));
docs.set("downloads.json", JSON.stringify({ version: 2, downloads: [{ id: "stale", state: "complete" }] }));
const { useBrowser } = await import("../store/browser.ts");
const { flushPersistence, startPersistence } = await import("./persist.ts");
const { nativeStoreActive, nativeStoreRev } = await import("../store/nativeStore.ts");
const S = () => useBrowser.getState();
const foreign = (patch) => {
  const entry = native.commit(patch);
  for (const listener of listeners) listener({ event: JSON.stringify({ rev: entry.rev, patch: entry }) });
};

native.settings = { ...native.settings, searchEngine: "duckduckgo", chosen: ["searchEngine"] };
native.downloads = [{ id: "saved-0", url: "https://e/1", state: "complete", profile: "" }];
startPersistence();

test("the replica hydrates settings and downloads from the native store, not the files", () => {
  assert.equal(nativeStoreActive(), true);
  assert.equal(S().settings.searchEngine, "duckduckgo");
  assert.deepEqual(S().downloads.map((d) => d.id), ["saved-0"]);
});

test("updateSettings becomes a native command and the replica applies its patch", () => {
  sent.length = 0;
  S().updateSettings({ appearance: "dark" });
  assert.deepEqual(sent.map((c) => c.name), ["updateSettings"]);
  assert.equal(S().settings.appearance, "dark");
  assert.equal(nativeStoreRev(), native.rev);
});

test("download actions send the list JS decided on, and the replica takes it from the patch", () => {
  sent.length = 0;
  S().upsertDownload({ id: "fresh", url: "https://e/2", state: "downloading", profile: "" });
  assert.equal(sent[0].name, "applyState");
  assert.deepEqual(S().downloads.map((d) => d.id), ["fresh", "saved-0"]);
  S().removeDownload("saved-0");
  assert.deepEqual(native.downloads.map((d) => d.id), ["fresh"]);
  assert.deepEqual(S().downloads.map((d) => d.id), ["fresh"]);
});

test("foreign commits apply in order, and a gap catches up from the native store", () => {
  foreign({ settings: { set: { searchEngine: "ecosia" } } });
  assert.equal(S().settings.searchEngine, "ecosia");
  native.commit({ settings: { set: { appearance: "light" } } });
  foreign({ settings: { set: { searchEngine: "brave" } } });
  assert.equal(S().settings.appearance, "light");
  assert.equal(S().settings.searchEngine, "brave");
  assert.equal(nativeStoreRev(), native.rev);
});

test("a write outside the applier is forwarded to the native store, not lost", () => {
  sent.length = 0;
  const warn = console.warn;
  const warnings = [];
  console.warn = (...args) => warnings.push(args.join(" "));
  try {
    useBrowser.setState({ settings: { ...S().settings, searchEngine: "kagi" } });
  } finally {
    console.warn = warn;
  }
  assert.equal(sent[0]?.name, "applyState");
  assert.equal(native.settings.searchEngine, "kagi");
  assert.ok(warnings.some((w) => w.includes("outside the native store's applier")));
});

test("persist.ts marks session.json and leaves downloads.json to the native store", () => {
  docs.delete("downloads.json");
  S().updateSettings({ appearance: "dark" });
  flushPersistence();
  const session = JSON.parse(docs.get("session.json"));
  assert.equal(session.nativeExport.rev, native.rev);
  assert.equal(session.settings.appearance, "dark");
  assert.equal(docs.has("downloads.json"), false);
});

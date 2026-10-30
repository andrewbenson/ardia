import assert from "node:assert/strict";
import { test } from "node:test";
import { nativeEvents } from "../../test-native/events.ts";

const events = nativeEvents();
const calls = [];
let status = { mode: "js-feed", ready: true, epoch: 0 };
let readStatus = async () => status;
const native = {
  available: () => true,
  sourceStatus: () => readStatus(),
  addListener: events.addListener,
  ...Object.fromEntries(["setTabs", "setEngineProfile", "setBookmarkIcons", "setActions", "setExtensions", "forgetWindow"].map((name) => [name, async (...args) => { calls.push({ name, args }); }])),
};
globalThis.acTestNativeModules = { SolaraNewTab: native };
const { newTabSources } = await import("../../../../../packages/settings/src/newTab.tsx");
const { useBrowser } = await import("../../store/browser.ts");
const { startWorkspaceSources } = await import("./workspaceSources.ts");
const start = (windowId) => ({ unmount: startWorkspaceSources(windowId, "default", useBrowser, newTabSources) });
const settle = () => new Promise((resolve) => setTimeout(resolve, 70));
const publish = (next) => { status = next; events.emit("onSourceStatus", next); };
const of = (name) => calls.filter((call) => call.name === name);

function setup() {
  calls.length = 0;
  status = { mode: "js-feed", ready: true, epoch: 0 };
  readStatus = async () => status;
  useBrowser.getState().hydrate({});
  const windowId = useBrowser.getState().createWindow({ url: "https://start.example/" });
  return windowId;
}

test("source status subscribes before reading and rejects an older asynchronous read", async () => {
  setup();
  let finish;
  readStatus = () => {
    assert.equal(events.count("onSourceStatus"), 1);
    return new Promise((resolve) => { finish = resolve; });
  };
  const seen = [];
  const stop = newTabSources.onSourceStatus((value) => seen.push(value));
  publish({ mode: "native-store", ready: true, epoch: 2 });
  finish({ mode: "js-feed", ready: true, epoch: 1 });
  await Promise.resolve();
  assert.deepEqual(seen, [{ mode: "native-store", ready: true, epoch: 2 }]);
  stop();
  assert.equal(events.count("onSourceStatus"), 0);
});

test("fallback publishes query tabs and mappings tagged with its status epoch", async () => {
  const windowId = setup();
  status = { mode: "js-feed", ready: true, epoch: 3 };
  const h = start(windowId);
  await settle();
  assert.equal(of("setTabs").at(-1).args[2], 3);
  assert.equal(JSON.parse(of("setTabs").at(-1).args[1])[0].url, "https://start.example/");
  assert.deepEqual(of("setEngineProfile").at(-1).args, ["default", "", "", 3]);
  h.unmount();
});

test("native readiness cancels queued tabs and suppresses mapping publications", async () => {
  const windowId = setup();
  const h = start(windowId);
  publish({ mode: "native-store", ready: true, epoch: 1 });
  calls.length = 0;
  useBrowser.getState().newTab(windowId, { url: "https://native.example/", background: true });
  await settle();
  assert.equal(of("setTabs").length, 0);
  assert.equal(of("setEngineProfile").length, 0);
  h.unmount();
});

test("loss publishes fresh rows and mappings even when table identity has not changed", async () => {
  const windowId = setup();
  status = { mode: "native-store", ready: true, epoch: 2 };
  const h = start(windowId);
  await settle();
  calls.length = 0;
  publish({ mode: "js-feed", ready: true, epoch: 3 });
  publish({ mode: "native-store", ready: true, epoch: 2 });
  await settle();
  assert.equal(of("setTabs").length, 1);
  assert.equal(of("setTabs")[0].args[2], 3);
  assert.deepEqual(of("setEngineProfile")[0].args, ["default", "", "", 3]);
  h.unmount();
});

test("native intent without readiness keeps fallback; unmount rejects a pending status read", async () => {
  const windowId = setup();
  status = { mode: "native-store", ready: false, epoch: 4 };
  const h = start(windowId);
  await settle();
  assert.equal(of("setTabs").at(-1).args[2], 4);
  h.unmount();
  let finish;
  readStatus = () => new Promise((resolve) => { finish = resolve; });
  const seen = [];
  const stop = newTabSources.onSourceStatus((value) => seen.push(value));
  stop();
  finish({ mode: "native-store", ready: true, epoch: 5 });
  await Promise.resolve();
  assert.deepEqual(seen, []);
  assert.equal(events.count("onSourceStatus"), 0);
});


test("a status read before a newer event and duplicate delivery preserve epoch ordering", async () => {
  setup();
  const seen = [];
  const stop = newTabSources.onSourceStatus((value) => seen.push(value));
  await Promise.resolve();
  publish({ mode: "native-store", ready: true, epoch: 1 });
  publish({ mode: "native-store", ready: true, epoch: 1 });
  publish({ mode: "js-feed", ready: true, epoch: 0 });
  assert.deepEqual(seen.map((value) => value.epoch), [0, 1]);
  stop();
});

test("closing a window and rapidly regaining native readiness cancel pending fallback rows", async () => {
  const windowId = setup();
  const h = start(windowId);
  await Promise.resolve();
  calls.length = 0;
  useBrowser.getState().newTab(windowId, { url: "https://pending.example/", background: true });
  useBrowser.getState().closeWindow(windowId);
  await settle();
  assert.equal(of("setTabs").length, 0);
  h.unmount();
  const second = setup();
  const next = start(second);
  publish({ mode: "native-store", ready: true, epoch: 1 });
  publish({ mode: "js-feed", ready: true, epoch: 2 });
  publish({ mode: "native-store", ready: true, epoch: 3 });
  calls.length = 0;
  await settle();
  assert.equal(of("setTabs").length, 0);
  assert.equal(of("setEngineProfile").length, 0);
  next.unmount();
});

test("first fallback snapshot cannot starve under other-profile churn", (t) => {
  setup();
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const state = {
    windows: { w: { profileId: "default" } },
    profiles: { default: { id: "default" } },
    settings: { defaultProfileId: "default" },
    tabs: { current: { id: "current", profileId: "default", url: "https://current.example/", title: "Current" } },
  };
  let receiveStatus;
  let changed;
  const publications = [];
  const stop = startWorkspaceSources("w", "default", {
    getState: () => state,
    subscribe: (handler) => { changed = handler; return () => {}; },
  }, {
    onSourceStatus: (handler) => {
      receiveStatus = handler;
      handler({ mode: "native-store", ready: true, epoch: 1 });
      return () => {};
    },
    setTabs: (...args) => publications.push({ name: "tabs", args }),
    setEngineProfile: (...args) => publications.push({ name: "mapping", args }),
  });
  t.after(stop);
  receiveStatus({ mode: "js-feed", ready: false, epoch: 2 });
  for (let i = 0; i < 10; i++) {
    t.mock.timers.tick(20);
    state.tabs = { ...state.tabs, noise: { id: "noise", profileId: "work", url: "https://noise.example/", title: `Update ${i}` } };
    changed();
  }
  const rows = () => publications.filter((value) => value.name === "tabs");
  assert.equal(rows().length, 1);
  assert.deepEqual(rows()[0].args, ["default", [{ id: "current", url: "https://current.example/", title: "Current", favicon: null }], 2]);
  assert.deepEqual(publications.filter((value) => value.name === "mapping"), [{ name: "mapping", args: ["default", "", "", 2] }]);
  t.mock.timers.tick(49);
  assert.equal(rows().length, 1);
  t.mock.timers.tick(1);
  assert.equal(rows().length, 2);
  receiveStatus({ mode: "native-store", ready: true, epoch: 3 });
  receiveStatus({ mode: "js-feed", ready: true, epoch: 4 });
  assert.equal(rows().length, 3);
  assert.equal(rows().at(-1).args[2], 4);
});

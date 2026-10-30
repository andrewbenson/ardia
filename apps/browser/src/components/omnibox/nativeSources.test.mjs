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
  ...Object.fromEntries(["setIdleTabs", "setTabs", "setEngineProfile", "setBookmarkIcons", "setActions", "setExtensions", "forgetWindow"].map((name) => [name, async (...args) => { calls.push({ name, args }); }])),
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
    peeks: {},
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
    setIdleTabs: () => {},
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


test("fallback idle inputs preserve raw tabs, peeks, sharing and active tab changes", async () => {
  const windowId = setup();
  let state = useBrowser.getState();
  let changed;
  const stop = startWorkspaceSources(windowId, "default", {
    getState: () => state,
    subscribe: (handler) => { changed = handler; return () => {}; },
  }, newTabSources);
  await settle();
  const first = of("setIdleTabs").at(-1);
  assert.ok(first);
  const payload = JSON.parse(first.args[0]);
  assert.deepEqual(payload.tabs, Object.values(state.tabs));
  assert.deepEqual(payload.windows, Object.values(state.windows));
  assert.deepEqual(payload.peeks, {});
  assert.equal(payload.shared, false);
  assert.equal(first.args[1], 0);
  calls.length = 0;
  const tabId = Object.keys(state.tabs)[0];
  state = { ...state,
    peeks: { ...state.peeks, [windowId]: { tabId } },
    settings: { ...state.settings, shareTabsAcrossWindows: true },
    windows: { ...state.windows, [windowId]: { ...state.windows[windowId], activeTabIds: { default: "changed" } } },
  };
  changed();
  await settle();
  const updated = JSON.parse(of("setIdleTabs").at(-1).args[0]);
  assert.deepEqual(updated.peeks, { [windowId]: tabId });
  assert.equal(updated.shared, true);
  assert.equal(updated.windows.find((window) => window.id === windowId).activeTabIds.default, "changed");
  publish({ mode: "native-store", ready: true, epoch: 1 });
  calls.length = 0;
  state = { ...state, peeks: {} };
  changed();
  await settle();
  assert.equal(of("setIdleTabs").length, 0);
  publish({ mode: "js-feed", ready: false, epoch: 2 });
  await settle();
  assert.equal(of("setIdleTabs").at(-1).args[1], 2);
  assert.deepEqual(JSON.parse(of("setIdleTabs").at(-1).args[0]).peeks, {});
  stop();
});

test("closing the last publishing window clears its idle workspace snapshot", () => {
  let state = {
    windows: { w: { id: "w", profileId: "default", activeTabIds: {} } },
    profiles: { default: { id: "default" } },
    settings: { defaultProfileId: "default" },
    tabs: { t: { id: "t", windowId: "w", profileId: "default", url: "https://closed.example/", title: "Closed" } },
    peeks: {},
  };
  let changed;
  const snapshots = [];
  const stop = startWorkspaceSources("w", "default", {
    getState: () => state,
    subscribe: (handler) => { changed = handler; return () => {}; },
  }, {
    onSourceStatus: (handler) => { handler({ mode: "js-feed", ready: true, epoch: 0 }); return () => {}; },
    setTabs: () => {},
    setEngineProfile: () => {},
    setIdleTabs: (snapshot) => snapshots.push(snapshot),
  });
  assert.equal(snapshots.at(-1).tabs.length, 1);
  state = { ...state, windows: {}, tabs: {} };
  changed();
  assert.deepEqual(snapshots.at(-1).tabs, []);
  assert.deepEqual(snapshots.at(-1).windows, []);
  stop();
});

test("idle snapshot revisions increase across publishers, closes and remounts in one epoch", async () => {
  const firstWindow = setup();
  const secondWindow = useBrowser.getState().createWindow({ url: "https://second.example/" });
  const first = start(firstWindow);
  const second = start(secondWindow);
  try {
    await settle();
    useBrowser.getState().closeWindow(firstWindow);
    await settle();
    first.unmount();
    const remounted = start(secondWindow);
    await settle();
    remounted.unmount();
    const snapshots = of("setIdleTabs");
    assert.ok(snapshots.length >= 4);
    let previous = -1;
    for (const { args } of snapshots) {
      assert.equal(args[1], 0);
      assert.ok(Number.isSafeInteger(args[2]), "each snapshot carries a workspace revision");
      assert.ok(args[2] > previous, "publishers must share one monotonic revision");
      previous = args[2];
    }
    const closed = snapshots.findIndex(({ args }) => !JSON.parse(args[0]).windows.some((window) => window.id === firstWindow));
    assert.ok(closed >= 0);
    assert.ok(snapshots[closed].args[2] > snapshots[closed - 1].args[2]);
  } finally {
    first.unmount();
    second.unmount();
  }
});

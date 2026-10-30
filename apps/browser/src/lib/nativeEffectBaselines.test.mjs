import assert from "node:assert/strict";
import { test, beforeEach } from "node:test";

const tab = { id: "t1", windowId: "w1", profileId: "default", url: "https://a.example/", title: "A", favicon: null, pinned: false, muted: false, zoom: 1, customTitle: null, customIcon: null, pinnedUrl: null, openerId: null, createdAt: 1, lastActiveAt: 1 };
const win = { id: "w1", profileId: "default", incognito: false, tabIds: ["t1"], activeTabIds: { default: "t1" }, sidebarOpen: true, frame: null, createdAt: 1 };
const data = (rev) => ({ rev, data: { profiles: { default: { id: "default", name: "Personal", color: "plum", icon: null, createdAt: 0 } }, profileOrder: ["default"], windows: { w1: win }, windowOrder: ["w1"], tabs: { t1: { ...tab, title: `A${rev}` } }, groups: {}, splits: {}, peeks: {}, closedTabs: [], closedWindows: [], closedGroups: [], deletedGroups: [], cleanedTabs: [], parkedPins: {}, pinChoices: {}, pinSync: {}, downloads: [], settings: { chosen: [], inferred: [] }, ui: { focusedWindowId: "w1", focusOrder: ["w1"], lastProfileId: null } } });
const listeners = new Set();
let rev = 1;
let dispatchReply;
let catchUpReply;
let dispatchHook;
const sent = [];
globalThis.acTestNativeModules = {
  ArdiaStore: {
    status: () => ({ active: true, scope: "everything" }),
    snapshot: () => JSON.stringify(data(rev)),
    dispatch: (json, sinceRev) => {
      const commands = [JSON.parse(json)].flat();
      sent.push(...commands.map((c) => c.name));
      dispatchHook?.(commands);
      if (dispatchReply) return JSON.stringify(dispatchReply);
      return JSON.stringify({ rev: Math.max(rev, sinceRev), patches: [] });
    },
    catchUp: () => JSON.stringify(catchUpReply ?? { rev, snapshot: data(rev).data }),
    flush: () => "saved",
    addListener: (_e, listener) => {
      listeners.add(listener);
      return { remove: () => listeners.delete(listener) };
    },
  },
};

const { useBrowser } = await import("../store/browser.ts");
const capturedSetWindowFrame = useBrowser.getState().setWindowFrame;
const { startPersistence } = await import("./persist.ts");
const S = () => useBrowser.getState();
startPersistence();

const { nativeWrite, attachReplica, NativeStoreBusy, nativeStoreRev, withApplier } = await import("../store/nativeStore.ts");
const { workspaceFromSnapshot } = await import("../store/nativeWorkspace.ts");
const { asSyncOrigin, applyingFromSync } = await import("../store/syncOrigin.ts");
const { IDLE_LIVE } = await import("../store/model.ts");
beforeEach(() => {
  dispatchReply = undefined;
  catchUpReply = undefined;
  dispatchHook = undefined;
  withApplier(() => useBrowser.setState(workspaceFromSnapshot(S(), data(rev).data)));
});
const emit = (commit) => {
  for (const listener of listeners) listener({ event: JSON.stringify(commit) });
};

test("an own patch effect does not close a panel opened by its subscriber", () => {
  let triggered = false;
  const stop = useBrowser.subscribe((s, prev) => {
    if (triggered || s.tabs.t1.title === prev.tabs.t1.title) return;
    triggered = true;
    s.openPanel("w1", "newer intent during own response");
  });
  const nextRev = ++rev;
  dispatchReply = { rev, patches: [{ rev, tabs: { upsert: [{ ...tab, title: `Own${nextRev}` }], remove: [] } }], effects: [{ type: "closePanel", windowId: "w1" }] };
  try {
    nativeWrite({ name: "probe", args: [] });
    assert.equal(triggered, true);
    assert.equal(S().windowUi.w1.panel.open, true);
  } finally {
    stop();
  }
});

test("an own snapshot effect does not close a panel opened by its subscriber", () => {
  let triggered = false;
  const stop = useBrowser.subscribe((s, prev) => {
    if (triggered || s.tabs.t1.title === prev.tabs.t1.title) return;
    triggered = true;
    s.openPanel("w1", "newer intent during own snapshot");
  });
  rev += 2000;
  dispatchReply = { rev, snapshot: data(rev).data, effects: [{ type: "closePanel", windowId: "w1" }] };
  try {
    nativeWrite({ name: "probe", args: [] });
    assert.equal(triggered, true);
    assert.equal(S().windowUi.w1.panel.open, true);
  } finally {
    stop();
  }
});

test("an effect-only foreign gap does not close a panel opened while catching up", () => {
  let triggered = false;
  const stop = useBrowser.subscribe((s, prev) => {
    if (triggered || s.tabs.t1.title === prev.tabs.t1.title) return;
    triggered = true;
    s.openPanel("w1", "newer intent during foreign catch-up");
  });
  rev += 2;
  catchUpReply = { rev, patches: [{ rev: rev - 1, tabs: { upsert: [{ ...tab, title: `Gap${rev}` }], remove: [] } }, { rev, settings: { set: { appearance: "light" } } }] };
  try {
    emit({ rev, patch: { rev }, effects: [{ type: "closePanel", windowId: "w1" }] });
    assert.equal(triggered, true);
    assert.equal(S().windowUi.w1.panel.open, true);
  } finally {
    stop();
  }
});

test("a nested subscriber command's UI effect survives the outer response", () => {
  S().openPanel("w1", "keep panel until newer command");
  let triggered = false;
  const stop = useBrowser.subscribe((s, prev) => {
    if (triggered || s.tabs.t1.title === prev.tabs.t1.title) return;
    triggered = true;
    dispatchReply = { rev: ++rev, patches: [{ rev, settings: { set: { appearance: "dark" } } }], effects: [{ type: "openDownloads", windowId: "w1" }] };
    nativeWrite({ name: "nested", args: [] });
  });
  dispatchReply = { rev: ++rev, patches: [{ rev, tabs: { upsert: [{ ...tab, title: `Outer${rev}` }], remove: [] } }], effects: [{ type: "closePanel", windowId: "w1" }] };
  try {
    nativeWrite({ name: "outer", args: [] });
    assert.equal(triggered, true);
    assert.equal(S().windowUi.w1.downloadsOpen, true);
    assert.equal(S().windowUi.w1.panel.open, true);
  } finally {
    stop();
  }
});

import assert from "node:assert/strict";
import { test } from "node:test";

const tab = { id: "t1", windowId: "w1", profileId: "default", url: "https://a.example/", title: "A", favicon: null, pinned: false, muted: false, zoom: 1, customTitle: null, customIcon: null, pinnedUrl: null, openerId: null, createdAt: 1, lastActiveAt: 1 };
const win = { id: "w1", profileId: "default", incognito: false, tabIds: ["t1"], activeTabIds: { default: "t1" }, sidebarOpen: true, frame: null, createdAt: 1 };
const data = (rev) => ({ rev, data: { profiles: { default: { id: "default", name: "Personal", color: "plum", icon: null, createdAt: 0 } }, profileOrder: ["default"], windows: { w1: win }, windowOrder: ["w1"], tabs: { t1: { ...tab, title: `A${rev}` } }, groups: {}, splits: {}, peeks: {}, closedTabs: [], closedWindows: [], closedGroups: [], deletedGroups: [], cleanedTabs: [], parkedPins: {}, pinChoices: {}, pinSync: {}, downloads: [], settings: { chosen: [], inferred: [] }, ui: { focusedWindowId: "w1", focusOrder: ["w1"], lastProfileId: null } } });
const listeners = new Set();
let rev = 1;
const sent = [];
globalThis.acTestNativeModules = {
  ArdiaStore: {
    status: () => ({ active: true, scope: "everything" }),
    snapshot: () => JSON.stringify(data(rev)),
    dispatch: (json, sinceRev) => {
      sent.push(...[JSON.parse(json)].flat().map((c) => c.name));
      return JSON.stringify({ rev: Math.max(rev, sinceRev), patches: [] });
    },
    catchUp: () => JSON.stringify({ rev, snapshot: data(rev).data }),
    flush: () => true,
    addListener: (_e, listener) => {
      listeners.add(listener);
      return { remove: () => listeners.delete(listener) };
    },
  },
};

const { useBrowser } = await import("../store/browser.ts");
const { startPersistence } = await import("./persist.ts");
const S = () => useBrowser.getState();
startPersistence();

test("attaching closes any transaction a previous JS runtime left open", () => {
  assert.ok(sent.includes("closeTransactions"));
});

test("a catch-up snapshot after a gap keeps the live state, panels and selection of what still exists", () => {
  S().updateLive("t1", { playingAudio: true, isLoading: true });
  S().setDownloadsOpen("w1", true);
  rev = 5;
  for (const listener of listeners) listener({ event: JSON.stringify({ rev, patch: { rev } }) });
  assert.equal(S().tabs.t1.title, "A5");
  assert.equal(S().live.t1.playingAudio, true);
  assert.equal(S().windowUi.w1.downloadsOpen, true);
});

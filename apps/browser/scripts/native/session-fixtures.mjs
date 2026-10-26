#!/usr/bin/env node
import { mkdirSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { writeSeed } from "../perf/seed.mjs";

const HELP = `usage: node scripts/native/session-fixtures.mjs [<out folder>]

Writes the synthetic session.json edge cases the importer oracle checks (oracle-check.mjs), one data folder
each, plus the 200-tab perf seed. Default out folder: native/SolaraKit/Tests/Fixtures/sessions.`;

if (process.argv.includes("--help")) {
  console.log(HELP);
  process.exit(0);
}
const here = dirname(fileURLToPath(import.meta.url));
const out = resolve(process.argv[2] ?? join(here, "../../../../native/SolaraKit/Tests/Fixtures/sessions"));

const profile = (id, name, extra = {}) => ({ id, name, color: "blue", icon: null, createdAt: 1, ...extra });
const tab = (id, windowId, extra = {}) => ({
  id,
  windowId,
  profileId: "default",
  url: `https://example.com/${id}`,
  title: `Page ${id}`,
  favicon: null,
  pinned: false,
  muted: false,
  zoom: 1,
  customTitle: null,
  customIcon: null,
  pinnedUrl: null,
  openerId: null,
  createdAt: 1700000000000,
  lastActiveAt: 1700000000000,
  ...extra,
});
const win = (id, tabIds, extra = {}) => ({
  id,
  profileId: "default",
  incognito: false,
  tabIds,
  activeTabIds: { default: tabIds[0] },
  sidebarOpen: true,
  frame: [10, 20, 1200, 800],
  createdAt: 1700000000000,
  ...extra,
});
const group = (id, windowId, tabIds, extra = {}) => ({
  id,
  windowId,
  profileId: "default",
  name: id,
  icon: null,
  color: "blue",
  collapsed: false,
  pinned: false,
  tabIds,
  createdAt: 1700000000000,
  ...extra,
});
const session = (parts) => ({
  version: 2,
  profiles: { default: profile("default", "Personal", { color: "plum", createdAt: 0 }) },
  profileOrder: ["default"],
  orphanedProfileData: [],
  settings: { chosen: [], inferred: [] },
  windows: [],
  windowOrder: [],
  focusedWindowId: null,
  lastProfileId: null,
  tabs: [],
  groups: [],
  splits: [],
  closedTabs: [],
  closedWindows: [],
  parkedPins: {},
  pinChoices: {},
  pinSync: {},
  closedGroups: [],
  deletedGroups: [],
  cleanedTabs: [],
  ...parts,
});

const weekAgo = Date.UTC(2026, 9, 26, 12) - 8 * 86_400_000;
const recent = Date.UTC(2026, 9, 26, 11);

const fixtures = {
  "restore-session-off": session({
    settings: { restoreSession: false, chosen: ["restoreSession"], inferred: [] },
    windows: [win("w1", ["p1", "p2", "r1", "g1", "a", "b", "c"], { activeTabIds: { default: "a" } }), win("w2", ["x"])],
    windowOrder: ["w1", "w2"],
    focusedWindowId: "w1",
    tabs: [
      tab("p1", "w1", { pinned: true, pinnedUrl: "https://example.com/home" }),
      tab("p2", "w1", { pinned: true, pinnedUrl: "https://example.com/p2", tileFolder: { id: "tf1", name: "Folder" } }),
      tab("r1", "w1", { pinned: true, pinnedAsRow: true, pinnedUrl: "https://example.com/r1" }),
      tab("g1", "w1", { pinnedUrl: "https://example.com/g1" }),
      tab("a", "w1", { wakeAdoptId: "restore:old-a" }),
      tab("b", "w1"),
      tab("c", "w1", { url: "" }),
      tab("x", "w2"),
    ],
    groups: [group("pg", "w1", ["g1"], { pinned: true })],
    splits: [{ id: "s1", windowId: "w1", tabIds: ["a", "b"], orientation: "horizontal", sizes: [0.4, 0.6] }],
  }),
  "orphans-and-unknown-profiles": session({
    windows: [win("w1", ["a", "b", "ghost", "elsewhere"]), win("empty", [])],
    windowOrder: ["w1", "missing", "empty"],
    focusedWindowId: "missing",
    tabs: [
      tab("a", "w1"),
      tab("b", "w1", { profileId: "gone" }),
      tab("lost", "nowhere"),
      tab("elsewhere", "w9"),
      tab("pvt", "w1", { profileId: "incognito:w1@default" }),
    ],
    groups: [group("g1", "w1", ["a", "lost"]), group("g2", "w1", ["lost"])],
  }),
  "broken-splits": session({
    windows: [win("w1", ["a", "b", "c", "d", "e"]), win("w2", ["f"])],
    windowOrder: ["w1", "w2"],
    tabs: [tab("a", "w1"), tab("b", "w1"), tab("c", "w1"), tab("d", "w1", { profileId: "work" }), tab("e", "w1"), tab("f", "w2")],
    profiles: { default: profile("default", "Personal", { createdAt: 0 }), work: profile("work", "Work") },
    profileOrder: ["default", "work"],
    splits: [
      { id: "s1", windowId: "w1", tabIds: ["a", "b", "c", "e"], orientation: "horizontal", sizes: [0.25, 0.25, 0.25, 0.25] },
      { id: "s2", windowId: "w1", tabIds: ["a", "d"], orientation: "vertical", sizes: [0.5, 0.5] },
      { id: "s3", windowId: "w1", tabIds: ["b", "f"], orientation: "horizontal", sizes: [0.5, 0.5], stack: { index: 0, sizes: [0.5, 0.5] } },
      { id: "s4", windowId: "w1", tabIds: ["c", "e", "missing"], orientation: "horizontal", sizes: [0.2, 0.3, 0.5], stack: { index: 1, sizes: [0.3, 0.7] } },
    ],
  }),
  "deleted-profile": session({
    profiles: { work: profile("work", "Work") },
    profileOrder: ["default", "work", "other"],
    orphanedProfileData: ["work", "stale-engine"],
    settings: { defaultProfileId: "default", chosen: ["defaultProfileId"], inferred: [] },
    windows: [win("w1", ["a", "b"], { profileId: "default", activeTabIds: { default: "a", work: "b" } })],
    windowOrder: ["w1"],
    lastProfileId: "gone",
    tabs: [tab("a", "w1"), tab("b", "w1", { profileId: "work" })],
    parkedPins: { gone: { tabs: [], groups: [] }, work: { tabs: [{ ...tab("pp", "x"), id: "pp", groupId: null }], groups: [] } },
    pinChoices: { gone: { a: 5 }, work: { b: 7, "place:b": 8 } },
    pinSync: { gone: { a: { g: "x" } }, work: { b: { w: 2 } } },
  }),
  "absent-and-unknown-fields": session({
    profiles: { default: { id: "default", name: "Personal", color: "plum", createdAt: 0, future: { x: 1 } } },
    settings: { searchEngine: "duckduckgo", futureSetting: [1, 2, { a: null }], chosen: ["searchEngine", "futureSetting"], inferred: [] },
    windows: [{ id: "w1", profileId: "default", incognito: false, tabIds: ["a", "b"], activeTabIds: { default: "b" }, sidebarOpen: false, createdAt: 5, extraWindowKey: true }],
    windowOrder: ["w1"],
    tabs: [
      { id: "a", windowId: "w1", profileId: "default", url: "https://a.example/", title: "A", pinned: false, muted: false, zoom: 1.25, createdAt: 1, lastActiveAt: 2 },
      { ...tab("b", "w1"), mystery: { deep: [1, "two", null] }, liveItem: { folderId: "f", itemId: "i" }, engine: "webkit" },
    ],
    groups: [{ id: "g", windowId: "w1", profileId: "default", name: "G", collapsed: true, pinned: false, tabIds: ["a"], createdAt: 3, newField: "kept" }],
    closedTabs: [{ kind: "tab", id: "ct1", tab: { url: "https://c.example/", title: "C", pinned: false, muted: false, zoom: 1, profileId: "default" }, windowId: "w1", index: 0, group: null, closedAt: recent, extra: 1 }],
    closedWindows: [
      { kind: "window", id: "cw1", window: { profileId: "default", sidebarOpen: true, frame: null, odd: 1 }, tabs: [{ ...tab("q", "w1"), active: true, tabId: "q" }], groups: [{ id: "cg", profileId: "default", name: "", icon: null, color: null, collapsed: false, pinned: false, createdAt: 0, tabIndexes: [0, -1] }], closedAt: recent },
    ],
  }),
  "legacy-settings": session({
    settings: { batterySaver: true, newTabPosition: "top", hideToolbarWhileScrolling: true, openLinksInLittleArdia: false },
    windows: [win("w1", ["a"])],
    windowOrder: ["w1"],
    tabs: [tab("a", "w1")],
  }),
  "legacy-settings-chosen": session({
    settings: { batterySaver: false, chosen: ["batterySaver", "newTabPosition"], inferred: ["batterySaver"], newTabPosition: "top", migrations: [] },
  }),
  "wrong-version": { version: 1, profiles: {}, windows: [] },
  "downloads-and-staging": {
    ...session({ windows: [win("w1", ["a"])], windowOrder: ["w1"], tabs: [tab("a", "w1")] }),
    __downloads: {
      version: 2,
      downloads: [
        { id: "d1", url: "https://e/1", filename: "1", path: "/tmp/1", state: "downloading", paused: false, received: 1, total: 2, speed: 0, mimeType: "" },
        { id: "d2", url: "https://e/2", filename: "2", path: "/tmp/2", state: "complete", paused: false, received: 2, total: 2, speed: 0, mimeType: "", offTheRecord: true, profile: "" },
        { id: "wk-download-UUID", url: "https://e/3", filename: "3", path: "/tmp/3", state: "complete", paused: false, received: 2, total: 2, speed: 0, mimeType: "", staging: "/tmp/s", destination: "/Users/x/Downloads/3" },
        { id: "d4", url: "https://e/4", filename: "4", path: "/tmp/4", state: "failed", paused: false, received: 0, total: 2, speed: 0, mimeType: "", profile: "incognito:w9@default" },
      ],
    },
  },
  "nested-groups-folders-rows": session({
    windows: [win("w1", ["t1", "t2", "t3", "r1", "r2", "n1", "n2", "n3", "l1", "l2"], { activeTabIds: { default: "l1" } })],
    windowOrder: ["w1"],
    focusedWindowId: "w1",
    tabs: [
      tab("t1", "w1", { pinned: true, pinnedUrl: "https://example.com/t1", tileFolder: { id: "f", name: "F", renamedAt: 3 } }),
      tab("t2", "w1", { pinned: true, pinnedUrl: "https://example.com/t2", tileFolder: { id: "f", name: "F", renamedAt: 3 } }),
      tab("t3", "w1", { pinned: true, pinnedUrl: "https://example.com/t3", tileFolder: { id: "solo", name: "" } }),
      tab("r1", "w1", { pinned: true, pinnedAsRow: true, pinnedUrl: "https://example.com/r1", pinKey: "rk" }),
      tab("r2", "w1", { pinned: true, pinnedAsRow: true, pinnedUrl: "https://example.com/r2", tileFolder: { id: "bad", name: "" } }),
      tab("n1", "w1", { pinnedUrl: "https://example.com/n1" }),
      tab("n2", "w1", { pinnedUrl: "https://example.com/n2" }),
      tab("n3", "w1"),
      tab("l1", "w1", { openerId: "l2" }),
      tab("l2", "w1", { pageIn: "nowhere", unloaded: true }),
    ],
    groups: [
      group("outer", "w1", ["n1", "n2"], { pinned: true }),
      group("inner", "w1", ["n2"], { pinned: true, parentId: "outer" }),
      group("list", "w1", ["n3", "l1"], { autoUngroup: true, pinnedOpenerId: "n1" }),
      group("cycle-a", "w1", ["l2"], { parentId: "cycle-b" }),
      group("cycle-b", "w1", ["l2"], { parentId: "cycle-a" }),
    ],
    deletedGroups: [
      { kind: "group", id: "dg-old", group: { id: "x", name: "Old", icon: null, color: null, pinned: false }, tabs: [], windowId: "w1", index: 0, closedAt: weekAgo },
      { kind: "group", id: "dg-new", group: { id: "y", name: "New", icon: null, color: null, pinned: true }, tabs: [{ url: "https://n/", title: "", favicon: null, pinned: false, muted: false, zoom: 1, customTitle: null, customIcon: null, profileId: "default", pinnedUrl: null }], windowId: "w1", index: 3, closedAt: recent },
    ],
    cleanedTabs: [
      { kind: "tab", id: "cl1", tab: { url: "https://c/", title: "", favicon: null, pinned: false, muted: false, zoom: 1, customTitle: null, customIcon: null, profileId: "incognito:w1@default" }, windowId: "w1", index: 0, group: null, closedAt: recent },
      { kind: "tab", id: "cl2", tab: { url: "https://d/", title: "", favicon: null, pinned: false, muted: false, zoom: 1, customTitle: null, customIcon: null, profileId: "default" }, windowId: "w1", index: 0, group: null, closedAt: weekAgo },
      { kind: "tab", id: "cl3", tab: { url: "https://e/", title: "", favicon: null, pinned: false, muted: false, zoom: 1, customTitle: null, customIcon: null, profileId: "default" }, windowId: "w1", index: 1, group: { id: "g", name: "", icon: null, color: null }, closedAt: recent },
    ],
  }),
  "duplicates-and-numbers": session({
    windows: [win("w1", ["a", "b", "a"], { frame: [0.5, -12.25, 1440.000001, 9e15], fullScreen: 1793016000000.5, linkPointer: [1, 2] }), win("w1", ["b"])],
    windowOrder: ["w1", "w1"],
    tabs: [tab("a", "w1", { zoom: 0.30000000000000004, title: "Ünïcödé — 😀   \\ \"quoted\"" }), tab("b", "w1"), tab("a", "w1", { title: "second a" })],
  }),
  "private-windows-only": session({
    windows: [win("w1", ["a"], { incognito: true, profileId: "incognito:w1@default", originalProfileId: "default", activeTabIds: { "incognito:w1@default": "a" } })],
    windowOrder: ["w1"],
    tabs: [tab("a", "w1", { profileId: "incognito:w1@default" })],
  }),
  "unparseable-session": null,
  "no-session-file": { __downloadsOnly: true },
  "lone-surrogate": {
    ...session({ windows: [win("w1", ["a"])], windowOrder: ["w1"], focusedWindowId: "w1", tabs: [tab("a", "w1", { title: "half \ud83d of a face" })] }),
    __oracle: { wellFormed: "a Swift String cannot hold a lone surrogate, so the importer writes U+FFFD where JS keeps \\ud83d" },
  },
  "big-numbers": session({
    windows: [win("w1", ["a"], { frame: [1e21, 1.5e-7, -0, 123456789012345680000] })],
    windowOrder: ["w1"],
    tabs: [tab("a", "w1", { zoom: 1e-7, createdAt: 9007199254740993 })],
  }),
};

const richBase = () =>
  session({
    profiles: { default: profile("default", "Personal", { color: "plum", createdAt: 0 }), work: profile("work", "Work", { createdAt: 2 }) },
    profileOrder: ["default", "work"],
    settings: { searchEngine: "duckduckgo", appearance: "dark", chosen: ["searchEngine", "appearance"], inferred: [] },
    windows: [win("w1", ["a", "b", "p"])],
    windowOrder: ["w1"],
    focusedWindowId: "w1",
    tabs: [tab("a", "w1"), tab("b", "w1"), tab("p", "w1", { pinned: true, pinnedUrl: "https://example.com/p" })],
    splits: [{ id: "s", windowId: "w1", tabIds: ["a", "b"], orientation: "horizontal", sizes: [0.5, 0.5] }],
    closedTabs: [{ kind: "tab", id: "ct", tab: { url: "https://c/", title: "C", favicon: null, pinned: false, muted: false, zoom: 1, customTitle: null, customIcon: null, profileId: "default" }, windowId: "w1", index: 0, group: null, closedAt: recent }],
    closedWindows: [{ kind: "window", id: "cw", window: { profileId: "default", sidebarOpen: true, frame: null }, tabs: [{ url: "https://w/", title: "W", favicon: null, pinned: false, muted: false, zoom: 1, customTitle: null, customIcon: null, profileId: "default", active: true, tabId: null }], groups: [], closedAt: recent }],
    closedGroups: [{ kind: "group", id: "cg", group: { id: "g", name: "G", icon: null, color: "red", pinned: false }, tabs: [{ url: "https://g/", title: "", favicon: null, pinned: false, muted: false, zoom: 1, customTitle: null, customIcon: null, profileId: "default" }], windowId: "w1", index: 0, closedAt: recent }],
    __downloads: { version: 2, downloads: [{ id: "d1", url: "https://e/1", filename: "1", path: "/tmp/1", state: "complete", paused: false, received: 2, total: 2, speed: 0, mimeType: "" }] },
  });
const wrongShapes = {
  "tab-tilefolder-string": (d) => (d.tabs[2].tileFolder = "legacy"),
  "tab-navigation-string": (d) => (d.tabs[0].navigation = "x"),
  "split-stack-number": (d) => (d.splits[0].stack = 0),
  "closed-tab-snapshot-string": (d) => (d.closedTabs[0].tab = "x"),
  "closed-tab-group-string": (d) => (d.closedTabs[0].group = "x"),
  "closed-tab-parents-strings": (d) => (d.closedTabs[0].parents = ["x"]),
  "closed-window-tab-number": (d) => d.closedWindows[0].tabs.push(5),
  "closed-window-group-string": (d) => (d.closedWindows[0].groups = ["x"]),
  "closed-group-head-string": (d) => (d.closedGroups[0].group = "x"),
  "closed-group-tab-string": (d) => d.closedGroups[0].tabs.push("x"),
  "closed-group-nested-string": (d) => (d.closedGroups[0].nested = ["x"]),
  "parked-pins-tab-string": (d) => (d.parkedPins = { default: { tabs: ["x"], groups: [] } }),
  "profile-string": (d) => (d.profiles.work = "x"),
  "window-null": (d) => d.windows.push(null),
  "tab-number": (d) => d.tabs.push(5),
  "closed-tabs-null": (d) => {
    d.closedTabs = [null];
    d.__oracle = { jsFails: "persist.ts throws on a null closed tab; Swift drops it and keeps the rest" };
  },
};
const jsThrows = "the JS store throws on this value while hydrating or saving; Swift drops it and keeps the rest";
const normalized = "Swift drops or resets this unreadable value where JS carries it along; the windows, tabs, settings and downloads must still match";
const expectations = {
  "closed-group-tab-string": { jsFails: jsThrows },
  "closed-tab-snapshot-string": { jsFails: jsThrows },
  "closed-window-tab-number": { jsFails: jsThrows },
  "window-null": { jsFails: jsThrows },
  "closed-group-head-string": { normalizes: normalized },
  "closed-group-nested-string": { normalizes: normalized },
  "closed-tab-parents-strings": { normalizes: normalized },
  "closed-window-group-string": { normalizes: normalized },
  "parked-pins-tab-string": { normalizes: normalized },
  "profile-string": { normalizes: normalized },
};
const wrongScalars = {
  "title-absent": (d) => delete d.tabs[0].title,
  "title-null": (d) => (d.tabs[0].title = null),
  "zoom-string": (d) => (d.tabs[0].zoom = "1.5"),
  "created-string": (d) => (d.tabs[0].createdAt = "1700000000000"),
  "name-number": (d) => (d.profiles.work.name = 42),
  "sidebar-number": (d) => (d.windows[0].sidebarOpen = 1),
  "frame-strings": (d) => (d.windows[0].frame = ["0", 0, 100, 100]),
  "tabids-mixed": (d) => (d.windows[0].tabIds = ["a", 5, "b", "p"]),
};
for (const [name, mutate] of Object.entries(wrongScalars)) {
  const doc = richBase();
  mutate(doc);
  fixtures[`scalar-${name}`] = doc;
}
for (const [name, mutate] of Object.entries(wrongShapes)) {
  const doc = richBase();
  mutate(doc);
  if (expectations[name]) doc.__oracle = expectations[name];
  fixtures[`wrong-shape-${name}`] = doc;
}

for (const [name, value] of Object.entries(fixtures)) {
  const dir = join(out, name);
  mkdirSync(dir, { recursive: true });
  for (const file of ["session.json", "downloads.json", "oracle.json"]) rmSync(join(dir, file), { force: true });
  if (value === null) {
    writeFileSync(join(dir, "downloads.json"), JSON.stringify({ version: 2, downloads: [] }));
    writeFileSync(join(dir, "session.json"), "not json at all");
    continue;
  }
  if (value.__downloadsOnly) {
    writeFileSync(join(dir, "downloads.json"), JSON.stringify({ version: 2, downloads: [] }));
    continue;
  }
  const { __downloads, __oracle, ...doc } = value;
  writeFileSync(join(dir, "session.json"), JSON.stringify(doc));
  if (__downloads) writeFileSync(join(dir, "downloads.json"), JSON.stringify(__downloads));
  if (__oracle) writeFileSync(join(dir, "oracle.json"), JSON.stringify(__oracle));
}
const seedDir = join(out, "perf-seed");
writeSeed(seedDir, "http://127.0.0.1:47817", "");
for (const name of readdirSync(seedDir)) if (name !== "session.json" && name !== "downloads.json") rmSync(join(seedDir, name), { recursive: true });
console.log(`wrote ${Object.keys(fixtures).length + 1} fixtures to ${out}`);

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { openTabsByUse } from "../../../apps/browser/src/store/tabShare.ts";
import { tabTitle } from "../../../apps/browser/src/components/sidebar/actions.ts";
import { recentTabSuggestions } from "../../../packages/core/src/openTabs.ts";

const tab = (id, windowId, url, lastActiveAt, extra = {}) => ({ id, windowId, profileId: "default", url, title: `Title ${id}`, favicon: null, pinned: false, createdAt: 0, lastActiveAt, ...extra });
const windows = [
  { id: "w1", profileId: "default", incognito: false, activeTabIds: { default: "active" }, tabIds: [], createdAt: 0 },
  { id: "w2", profileId: "default", incognito: false, activeTabIds: { default: "remote" }, tabIds: [], createdAt: 0 },
];
const tabs = [
  tab("named-first", "w1", "https://same.example/", 20, { pinKey: "family", customTitle: "Custom here", favicon: "icon:here" }),
  tab("10", "w2", "https://ten.example/", 20),
  tab("2", "w1", "https://two.example/", 20),
  tab("active", "w1", "https://active.example/", 100),
  tab("remote", "w2", "https://same.example/", 80, { pinKey: "family" }),
  tab("peek", "w2", "https://peek.example/", 90, { pinKey: "family" }),
  tab("pinned-here", "w1", "https://pin.example/", 30, { pinKey: "pinned", pinned: true }),
  tab("pinned-away", "w2", "https://pin.example/", 70, { pinKey: "pinned", pinned: true }),
  tab("custom", "w2", "https://custom.example/", 60, { customTitle: "Only custom", title: "" }),
  tab("label", "w1", "HTTPS://www.example.com/path/", 50, { title: "", customTitle: "" }),
  tab("blank", "w1", "", 200, { title: "", customTitle: "" }),
  tab("other-profile", "w1", "https://other.example/", 500, { profileId: "work", pinKey: "family" }),
  tab("orphan", "closed", "https://orphan.example/", 5),
];
const peeks = { w2: { tabId: "peek", sourceId: "remote", sourcePage: "https://same.example/" } };
const inputs = [
  { name: "unshared-w1", shared: false, windowId: "w1", profileId: "default", tabs, peeks, windows },
  { name: "unshared-w2", shared: false, windowId: "w2", profileId: "default", tabs, peeks, windows },
  { name: "shared-w1", shared: true, windowId: "w1", profileId: "default", tabs, peeks, windows },
  { name: "shared-w2", shared: true, windowId: "w2", profileId: "default", tabs, peeks, windows },
  { name: "other-profile", shared: true, windowId: "w1", profileId: "work", tabs, peeks, windows },
  { name: "absent-window", shared: true, windowId: "missing", profileId: "default", tabs, peeks, windows },
  { name: "active-family-excluded", shared: true, windowId: "w1", profileId: "default", tabs, peeks, windows: windows.map(w => ({ ...w, activeTabIds: { default: "named-first" } })) },
  { name: "no-local-family-copy", shared: true, windowId: "w1", profileId: "default", tabs: tabs.filter(t => t.id !== "named-first"), peeks, windows },
  { name: "equal-last-use", shared: true, windowId: "w1", profileId: "default", tabs: tabs.filter(t => t.profileId === "default").map(t => ({ ...t, lastActiveAt: 10 })), peeks, windows },
  { name: "title-fallbacks", shared: false, windowId: "w1", profileId: "default", tabs: [
    tab("title", "w1", "https://title.example/", 10),
    tab("url", "w1", "https://www.host.example/", 10, { title: "" }),
    tab("scheme", "w1", "CUSTOM+scheme://www.host.example/", 10, { title: "" }),
    tab("new", "w1", "/", 10, { title: "" }),
    tab("spaces", "w1", "https://spaces.example/", 10, { customTitle: " " }),
    tab("unicode", "w1", "https://example.com/cafe\u0301", 10, { customTitle: "Cafe\u0301", favicon: "icon:cafe\u0301" }),
  ], peeks: {}, windows },
];
const cases = inputs.map(input => {
  const tabs = Object.fromEntries(input.tabs.map(t => [t.id, t]));
  const active = input.windows.find(w => w.id === input.windowId)?.activeTabIds[input.profileId];
  const rows = openTabsByUse(tabs, input.peeks, input).map(({ tab: t, lastActiveAt }) => ({ id: t.id, url: t.url, title: tabTitle(t), favicon: t.favicon, lastActiveAt }));
  const fallbackPayload = { tabs: Object.values(tabs), windows: Object.values(Object.fromEntries(input.windows.map(w => [w.id, w]))), peeks: Object.fromEntries(Object.entries(input.peeks).map(([windowId, peek]) => [windowId, peek.tabId])), shared: input.shared };
  return { ...input, fallbackPayload, active: active ?? null, expected: recentTabSuggestions(rows, { exclude: active }) };
});
const sources = ["../../../apps/browser/src/components/omnibox/dropdownStart.ts", "../../../apps/browser/src/store/tabShare.ts", "../../../apps/browser/src/store/pinMirror.ts", "../../../apps/browser/src/components/sidebar/actions.ts", "../../../packages/core/src/openTabs.ts"];
const output = JSON.stringify({ sourceHashes: Object.fromEntries(sources.map(path => [path, createHash("sha256").update(readFileSync(new URL(path, import.meta.url))).digest("hex")])), cases }, null, 2) + "\n";
const path = process.argv.find(arg => arg.startsWith("--out="))?.slice(6) ?? new URL("../Tests/SolaraOmniboxTests/Fixtures/idle-tabs.json", import.meta.url);
if (process.argv.includes("--verify")) assert.equal(readFileSync(path, "utf8"), output);
else writeFileSync(path, output);
console.log(`${cases.length} idle tab goldens ${process.argv.includes("--verify") ? "verified" : "recorded"}`);

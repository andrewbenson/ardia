import { writeFileSync } from "node:fs";
import { queryTabRows } from "../../../apps/browser/src/components/omnibox/workspaceSources.ts";
import { bookmarkProfileId, engineProfile, setSharedDataIds } from "../../../apps/browser/src/store/model.ts";

const profile = (id, dataId = undefined) => ({ id, name: id, color: "blue", icon: null, createdAt: 0, ...(dataId ? { dataId } : {}) });
const window = (id, profileId, originalProfileId = undefined) => ({ id, profileId, incognito: profileId.startsWith("incognito:"), originalProfileId, tabIds: [], activeTabIds: {}, createdAt: 0 });
const tab = (id, windowId, profileId, url, title, extra = {}) => ({ id, windowId, profileId, url, title, favicon: null, ...extra });
const profiles = [profile("default"), profile("shared", "default"), profile("work", "engine-work"), profile("other", "engine-work"), profile("empty"), profile("incognito:closed@default")];
const windows = [window("w1", "default"), window("w2", "default"), window("ws", "shared"), window("ww", "work"), window("wp", "incognito:wp@work", "work"), window("wp2", "incognito:wp2@default", "default")];
const tabs = [
  tab("named-first", "w1", "default", "https://duplicate.example/", "Actual title", { customTitle: "Do not publish custom title", favicon: "icon:a" }),
  tab("10", "w2", "default", "https://duplicate.example/", "Duplicate URL"),
  tab("2", "w1", "default", "", "Empty URL", { favicon: "" }),
  tab("01", "w2", "default", "https://leading.example/", "Leading zero"),
  tab("4294967295", "w1", "default", "https://max.example/", "Named max index"),
  tab("0", "w2", "default", "https://zero.example/", "Zero"),
  tab("4294967294", "w2", "default", "https://index.example/", "Last numeric index"),
  tab("shared-tab", "ws", "shared", "https://duplicate.example/", "Separate UI profile"),
  tab("private-tab", "wp", "incognito:wp@work", "https://private.example/", "Private work"),
  tab("private-tab2", "wp2", "incognito:wp2@default", "https://private.example/", "Private default"),
  tab("work-tab", "ww", "work", "https://work.example/", "Work"),
  tab("named-last", "w1", "default", "https://last.example/", "Last named"),
  tab("named-first", "w2", "default", "https://duplicate.example/", "Updated title", { customTitle: "Still ignored", favicon: "icon:updated" }),
];
const currentTabs = Object.values(Object.fromEntries(tabs.map(t => [t.id, t])));
const cases = [
  { name: "numeric-named-shared-private", profiles, windows, tabs },
  { name: "first-window-closed", profiles, windows: windows.filter(w => w.id !== "w1"), tabs: currentTabs.filter(t => t.windowId !== "w1") },
  { name: "private-window-closed", profiles, windows: windows.filter(w => !w.incognito), tabs: currentTabs.filter(t => !t.profileId.startsWith("incognito:")) },
  { name: "missing-original-falls-back", profiles, windows: [window("orphan", "incognito:orphan@missing", "missing")], tabs: [] },
  { name: "no-windows", profiles: [profile("default"), profile("work", "engine-work")], windows: [], tabs: [] },
];
const output = cases.map(input => {
  const state = { profiles: Object.fromEntries(input.profiles.map(p => [p.id, p])), windows: Object.fromEntries(input.windows.map(w => [w.id, w])), tabs: Object.fromEntries(input.tabs.map(t => [t.id, t])), settings: { defaultProfileId: "default" } };
  setSharedDataIds(Object.fromEntries(input.profiles.filter(p => p.dataId).map(p => [p.id, p.dataId])));
  const ids = [...new Set([...Object.keys(state.profiles).filter(id => !id.startsWith("incognito:")), ...Object.values(state.windows).map(w => w.profileId), ...Object.values(state.tabs).map(t => t.profileId)])];
  return { ...input, expected: ids.map(profileId => {
    const selectedWindow = Object.values(state.windows).find(w => w.profileId === profileId) ?? window("", profileId);
    return { profileId, engineProfile: engineProfile(profileId), bookmarkEngineProfile: engineProfile(bookmarkProfileId(state, selectedWindow)), tabs: queryTabRows(state, profileId) };
  }) };
});
writeFileSync(process.argv[2] ?? new URL("../Tests/SolaraOmniboxTests/Fixtures/workspace-sources.json", import.meta.url), JSON.stringify({ cases: output }, null, 2) + "\n");

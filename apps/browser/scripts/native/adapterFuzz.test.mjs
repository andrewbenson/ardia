import { test } from "node:test";
const { useBrowser } = await import("../../src/store/browser.ts");
const adapters = await import("../../src/sync/adapters.ts");
const { DEFAULT_SETTINGS } = await import("../../src/store/settings.ts");

const S = () => useBrowser.getState();
const RUNS = Number(process.env.ADAPTER_FUZZ_RUNS ?? 40);

function mulberry32(seed) {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function kit(seed) {
  const rand = mulberry32(seed);
  const pick = (list) => list[Math.floor(rand() * list.length)];
  const chance = (p) => rand() < p;
  const some = (list, p = 0.3) => list.filter(() => chance(p));
  const junk = () => pick([null, 0, 1, -2.5, "", "x", true, false, [], [1, "a"], {}, { v: null }, { z: 1, a: 2 }, "ünï", 1e21, 0.1]);
  return { rand, pick, chance, some, junk };
}

const NAMES = adapters.SYNCED_SETTINGS;

function settingValue(k, name) {
  const fallback = DEFAULT_SETTINGS[name];
  return k.pick([
    fallback,
    JSON.parse(JSON.stringify(fallback ?? null)),
    fallback && typeof fallback === "object" && !Array.isArray(fallback) ? Object.fromEntries(Object.entries(fallback).reverse()) : fallback,
    null,
    k.junk(),
    typeof fallback === "boolean" ? !fallback : fallback,
  ]);
}

test("settings: extract and apply over random settings, bases and records", () => {
  for (let run = 0; run < RUNS; run++) {
    const k = kit(1000 + run);
    S().hydrate({});
    const names = k.some(NAMES, 0.4);
    const values = Object.fromEntries(names.map((name) => [name, settingValue(k, name)]).filter(([, v]) => v !== undefined));
    useBrowser.setState({ settings: { ...S().settings, ...values, chosen: k.some(names, 0.7), inferred: k.some(names, 0.4) } });
    const bases = new Map(names.filter(() => k.chance(0.5)).map((name) => [`set:${name}`, k.pick([{ v: null }, {}, { v: 1 }, 3, "s", { v: settingValue(k, name) }])]));
    const extraction = adapters.settingsAdapter.extract((key) => bases.get(key));
    for (const name of k.some(NAMES, 0.2)) extraction.ignore?.(`set:${name}`);
    const changed = [...k.some(NAMES, 0.3).map((n) => `set:${n}`), ...(k.chance(0.3) ? ["set:notASetting", "set:"] : [])];
    const visible = new Map(changed.filter(() => k.chance(0.8)).map((key) => [key, k.pick([{ v: settingValue(k, key.slice(4)) }, { v: null }, {}, 0, "x", null, { v: k.junk() }])]));
    adapters.settingsAdapter.apply(visible, changed);
  }
});

const COLORS = ["plum", "blue", "red", "green", "none", "gray"];

function color(k) {
  return k.pick([
    { r: k.rand(), g: k.rand(), b: k.rand(), a: k.rand() },
    { r: k.rand(), g: k.rand(), b: k.rand() },
    { r: 3.9, g: -3.9, b: 0, a: 2 },
    { r: 4, g: 0, b: 0 },
    { r: "1", g: 0, b: 0 },
    null,
    "red",
  ]);
}

function look(k) {
  return {
    ...(k.chance(0.9) ? { stops: Array.from({ length: k.pick([0, 1, 2, 3, 4, 17]) }, () => k.pick([{ x: k.rand() * 2 - 0.5, y: k.pick([k.rand(), "a", undefined, 1.5]), color: color(k) }, null, 5, { color: color(k) }])) } : { stops: k.junk() }),
    ...(k.chance(0.7) ? { intensity: k.pick([k.rand(), -1, 2, "x", null]) } : {}),
    ...(k.chance(0.5) ? { grain: k.pick([k.rand(), 5]) } : {}),
    ...(k.chance(0.6) ? { texture: k.pick(["grain", "sand", "denim", "tweed", "silk", 3]) } : {}),
    ...(k.chance(0.5) ? { translucency: k.pick([k.rand(), -0.5]) } : {}),
    ...(k.chance(0.5) ? { angle: k.pick([0, 45, 359.5, 360, -30, -720.25, 1e6, "90", null]) } : {}),
  };
}

function theme(k) {
  return k.pick([null, undefined, { ...look(k), mode: k.pick(["auto", "light", "dark", "night", undefined]), ...(k.chance(0.5) ? { dark: k.chance(0.8) ? look(k) : k.junk() } : {}) }, k.junk()]);
}

function profileWorld(k) {
  S().hydrate({});
  const ids = ["default"];
  for (let i = 0; i < k.pick([0, 1, 2, 3]); i++) ids.push(S().createProfile({ name: k.pick(["Work", "Ünï", "", "School"]), color: k.pick(COLORS), icon: k.pick([null, "🙂", "briefcase"]) }));
  const profiles = { ...S().profiles };
  for (const id of ids) {
    const p = { ...profiles[id] };
    if (k.chance(0.3)) delete p.icon;
    if (k.chance(0.3)) p.dataId = k.pick([...ids, "gone", ""]);
    const t = theme(k);
    if (t === undefined) delete p.theme;
    else p.theme = t;
    profiles[id] = p;
  }
  useBrowser.setState({ profiles });
  const links = Object.fromEntries([...ids.filter(() => k.chance(0.8)), ...(k.chance(0.3) ? ["missing"] : [])].map((id, i) => [id, { syncId: `s${i}`, ...(k.chance(0.2) ? { themeAdopting: true } : {}), enabled: k.chance(0.8), ...(k.chance(0.2) ? { retire: true } : {}) }]));
  return { ids, links };
}

test("profiles, themes and shared data over random profiles, links and records", () => {
  for (let run = 0; run < RUNS * 2; run++) {
    const k = kit(5000 + run);
    const { links } = profileWorld(k);
    const syncIds = Object.values(links).map((l) => l.syncId);
    const keys = syncIds.flatMap((s) => [`prof:${s}`, `pth:${s}`, `pth:${s}:angle`, `share:${s}`]);
    const known = new Set(keys.filter(() => k.chance(0.4)));
    const bases = new Map(keys.filter(() => k.chance(0.4)).map((key) => [key, k.pick([{ t: look(k) }, { preset: true }, { a: 10 }, {}])]));
    const records = Object.fromEntries(keys.filter((key) => key.startsWith("pth:") && k.chance(0.4)).map((key) => [key, { v: k.chance(0.8) ? (bases.get(key) ?? { t: look(k) }) : null }]));
    const extractArgs = [(key) => bases.get(key), () => false, 0, (key) => known.has(key)];
    const profiles = adapters.profilesAdapter(() => links);
    const shownRecords = k.chance(0.9) ? records : undefined;
    const themes = adapters.profileThemesAdapter(() => links, () => shownRecords, () => {});
    const shared = adapters.sharedDataAdapter(() => links);
    profiles.extract(...extractArgs).ignore?.(`prof:${k.pick(syncIds) ?? "x"}`);
    themes.extract(...extractArgs);
    shared.extract(...extractArgs);
    const changed = new Set(keys.filter(() => k.chance(0.5)));
    const visible = new Map(
      [...changed].filter(() => k.chance(0.85)).map((key) => [
        key,
        key.startsWith("prof:")
          ? k.pick([{ n: "Renamed", c: k.pick(COLORS), i: k.pick([null, "🙂"]), ...(k.chance(0.4) ? { th: theme(k) } : {}) }, { n: "Only name" }, null, 7])
          : key.endsWith(":angle")
            ? k.pick([{ a: k.pick([10, -10, "x", null]) }, { d: 200 }, { a: 1, d: 2 }, {}, null, "a"])
            : k.pick([{ t: theme(k) }, { preset: true }, { preset: "yes" }, {}, [], null, { t: look(k), preset: true }]),
      ]),
    );
    const applyRecords = { known: (key) => known.has(key), now: 0, horizon: 0, joined: k.chance(0.5) };
    profiles.apply(visible, changed, (key) => bases.get(key), applyRecords);
    themes.apply(visible, changed, (key) => bases.get(key), applyRecords);
    shared.apply(visible, changed, (key) => bases.get(key), applyRecords);
  }
});

const HOSTS = ["localhost", "LOCALHOST", "127.0.0.1", "[::1]", "app.localhost", "example.com", "Example.COM", "a".repeat(254), "", "dev.test", "ÜNÏ.de"];

test("developer mode over random host lists", () => {
  for (let run = 0; run < RUNS; run++) {
    const k = kit(9000 + run);
    S().hydrate({});
    const mode = () => k.pick([{ on: k.some(HOSTS, 0.4), off: k.some(HOSTS, 0.4), reload: k.pick(["reload", "forceReload", "other"]) }, { on: [3, null, ...k.some(HOSTS)] }, "string", null, []]);
    const profileId = k.pick(["default", "other"]);
    useBrowser.setState({ settings: { ...S().settings, developerMode: k.chance(0.8) ? { default: mode(), other: mode() } : undefined } });
    const adapter = adapters.developerModeAdapter(profileId);
    adapter.extract();
    const visible = new Map([
      ...k.some(HOSTS).map((h) => [`devmode:on:${h}`, { v: 1 }]),
      ...k.some(HOSTS).map((h) => [`devmode:off:${h}`, { v: 1 }]),
      ...(k.chance(0.5) ? [["devmode:reload", k.pick([{ r: "forceReload" }, { r: "reload" }, "forceReload", null, []])]] : []),
      ...(k.chance(0.2) ? [["devmode:other", { v: 1 }]] : []),
    ]);
    adapter.apply(visible, new Set(visible.keys()));
  }
});

test("device tabs over random windows, tabs and peeks", () => {
  for (let run = 0; run < RUNS; run++) {
    const k = kit(13000 + run);
    S().hydrate({});
    const windows = [S().createWindow(), S().createWindow(), S().createWindow({ incognito: true })];
    const tabs = [];
    for (let i = 0; i < k.pick([3, 10, 40]); i++) {
      const windowId = k.pick(windows);
      tabs.push(S().newTab(windowId, { url: k.pick(["https://a.com/", "http://b.org", "file:///tmp/x", "HTTPS://c.com", "chrome://settings", "about:blank", "ftp://x"]), background: true }));
    }
    const patch = { ...S().tabs };
    for (const id of tabs) {
      if (!patch[id]) continue;
      patch[id] = { ...patch[id], lastActiveAt: k.pick([1, 2, 3, 5, 5]), title: k.pick(["", "Title", "Ünï"]), ...(k.chance(0.3) ? { customTitle: k.pick(["", "Mine"]) } : {}), ...(k.chance(0.2) ? { unloaded: true } : {}), ...(k.chance(0.15) ? { pinned: true } : {}) };
    }
    useBrowser.setState({ tabs: patch });
    if (k.chance(0.4)) {
      const source = tabs.find((id) => S().tabs[id] && /^https?:/.test(S().tabs[id].url) && !S().windows[S().tabs[id].windowId]?.incognito);
      if (source) S().openPeek(source, "https://peek.example/");
    }
    adapters.deviceTabsAdapter("default", "dev1", () => "Mac", k.chance(0.1)).extract();
  }
});

const pinned = await import("../../src/sync/pinned.ts");
const tileFolders = await import("../../src/store/tileFolders.ts");
const { Clock, emptyScope, syncScope } = await import("@ardia/sync");

const PIN_URLS = ["https://mail.example/", "https://cal.example/inbox", "https://docs.example/", "https://news.example/#top", "netnyahoo://settings", "https://row.example/", ""];
const POSITIONS = ["V", "l", "t", "x", "z", "0", "a0", "Vk", "", "zz", "A", "￿", "V0", "lV"];
const GROUP_COLORS = ["blue", "red", "none", "grey", null, undefined, "chartreuse"];
const dropUndefined = (o) => Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined));
const pinKey = (x) => x.pinKey ?? x.id;

function pinnedWorld(k) {
  S().hydrate({});
  const profiles = ["default", ...(k.chance(0.3) ? [S().createProfile({ name: "Work" })] : [])];
  const windows = [S().createWindow()];
  if (k.chance(0.4)) windows.push(S().createWindow());
  if (profiles.length > 1 && k.chance(0.6)) windows.push(S().createWindow({ profileId: profiles[1] }));
  for (const w of windows) {
    const ids = Array.from({ length: k.pick([2, 3, 5, 8]) }, () => S().newTab(w, { url: k.pick(PIN_URLS.filter(Boolean)), background: true }));
    const live = () => ids.filter((id) => S().tabs[id]);
    const tiles = k.some(live(), 0.5);
    if (tiles.length) S().pinTabs(tiles, true);
    const rows = k.some(live().filter((id) => !S().tabs[id]?.pinned), 0.4);
    if (rows.length) S().pinTabs(rows, true, true);
    const loose = live().filter((id) => !S().tabs[id]?.pinned);
    if (loose.length >= 1 && k.chance(0.7)) {
      const groupId = S().groupTabs(k.some(loose, 0.6).slice(0, 3).concat(loose[0]).filter((id, i, a) => a.indexOf(id) === i), { pinned: true, name: k.pick(["Work", "", "Ünï"]) });
      if (groupId && S().groups[groupId] && k.chance(0.4)) S().newNestedGroup(groupId);
      if (groupId && S().groups[groupId] && k.chance(0.4)) S().updateGroup(groupId, { color: k.pick(["none", "blue", "red"]) });
    }
    const left = live().filter((id) => !S().tabs[id]?.pinned && !Object.values(S().groups).some((g) => g.tabIds.includes(id)));
    if (left.length >= 2 && k.chance(0.3)) S().groupTabs(left.slice(0, 2), { pinned: false, name: "Loose" });
    const tileIds = live().filter((id) => S().tabs[id]?.pinned && !S().tabs[id].pinnedAsRow);
    if (tileIds.length >= 2 && k.chance(0.5)) useBrowser.setState(tileFolders.newTileFolder(S(), tileIds.slice(0, k.pick([2, 3])), k.pick(["", "Reading"])).state, true);
    for (const id of live()) {
      if (k.chance(0.2)) S().updateTab(id, { customTitle: k.pick(["Mine", "", null]) });
      if (k.chance(0.15)) S().updateTab(id, { unloaded: true });
    }
  }
  const foldered = Object.values(S().tabs).filter((t) => t.tileFolder);
  if (foldered.length && k.chance(0.5)) {
    const t = k.pick(foldered);
    useBrowser.setState({ tabs: { ...S().tabs, [t.id]: { ...t, tileFolder: { ...t.tileFolder, name: k.pick(["Later", "Earlier"]), renamedAt: k.pick([1, 5, 1e15]) } } } });
  }
  if (windows.length > 1 && k.chance(0.35)) S().closeWindow(k.pick(windows));
  if (k.chance(0.25)) S().closeWindow(windows[0]);
  return { profiles };
}

function worldKeys(k) {
  const s = S();
  const tabKeys = [...new Set(Object.values(s.tabs).map(pinKey)), ...Object.values(s.parkedPins).flatMap((p) => p.tabs.map((t) => t.id))];
  const groupKeys = [...new Set(Object.values(s.groups).map(pinKey)), ...Object.values(s.parkedPins).flatMap((p) => p.groups.map((g) => g.id))];
  const folderIds = [...new Set([...Object.values(s.tabs).map((t) => t.tileFolder?.id), ...Object.values(s.parkedPins).flatMap((p) => p.tabs.map((t) => t.tileFolder?.id))].filter(Boolean))];
  return { tabKeys: [...tabKeys, "ghost-tab", "ghost-two"], groupKeys: [...groupKeys, "ghost-group", "5"], folderIds: [...folderIds, "tf-ghost"] };
}

function pinRecords(k, keys) {
  const { tabKeys, groupKeys, folderIds } = keys;
  const groupRef = () => k.pick([...groupKeys, null, undefined, 5, "", "ghost-group"]);
  const entries = [];
  for (const key of k.some(tabKeys, 0.6)) {
    entries.push([`pin:t:${key}`, dropUndefined({ g: groupRef(), u: k.chance(0.03) ? 5 : k.pick(PIN_URLS), t: k.pick([null, "Mine", undefined, ...(k.chance(0.05) ? [7] : [])]), i: k.pick([null, "🙂", undefined]), ti: k.chance(0.03) ? [] : k.pick(["", "Title"]), pos: k.pick(POSITIONS) })]);
    if (k.chance(0.25)) entries.push([`pinn:t:${key}`, dropUndefined({ g: groupRef() })]);
    if (k.chance(0.4)) entries.push([`pinrow:${key}`, k.pick([1, 0, 2, "1", null])]);
    if (k.chance(0.3)) entries.push([`tilefold:${key}`, k.pick([{ f: k.pick(folderIds) }, { f: 5 }, {}, null, "x", { f: "" }])]);
    if (k.chance(0.3)) entries.push([`pgh:${key}`, k.pick(["https://home.example/", "", 5, null, {}, "netnyahoo://home"])]);
  }
  for (const key of k.some(groupKeys, 0.6)) {
    if (k.chance(0.7)) entries.push([`pin:g:${key}`, dropUndefined({ n: k.chance(0.03) ? 9 : k.pick(["Work", "", "Ünï"]), i: k.pick([null, "📁", undefined]), c: k.chance(0.03) ? 3 : k.pick(GROUP_COLORS), pos: k.pick(POSITIONS) })]);
    if (k.chance(0.4)) entries.push([`pinn:g:${key}`, dropUndefined({ n: k.pick(["Inner", ""]), i: k.pick([null, undefined]), c: k.pick(GROUP_COLORS), p: k.pick([...groupKeys, key, 5, undefined]) })]);
    if (k.chance(0.3)) entries.push([`pgc:${key}`, k.pick(["none", "blue", null, 5, {}])]);
    if (k.chance(0.4)) entries.push([`pord:g:${key}`, k.pick([{ a: k.pick([...tabKeys, null]) }, { a: 5 }, {}, 5, null, "x"])]);
  }
  for (const id of k.some(folderIds, 0.5)) entries.push([`tilefold:n:${id}`, k.pick([{ n: "Named" }, { n: 5 }, {}, null, { n: "" }])]);
  return entries;
}

function pinBase(k, keys) {
  const { tabKeys, groupKeys, folderIds } = keys;
  const base = new Map();
  for (const key of k.some(tabKeys, 0.5)) {
    base.set(`pin:t:${key}`, dropUndefined({ g: k.pick([null, undefined, ...groupKeys]), pos: k.pick([...POSITIONS, undefined, null]), u: "https://old.example/" }));
    if (k.chance(0.4)) base.set(`pinrow:${key}`, k.pick([1, 0]));
    if (k.chance(0.3)) base.set(`pgh:${key}`, k.pick(["https://home.example/", "", 5]));
    if (k.chance(0.3)) base.set(`tilefold:${key}`, k.pick([{ f: k.pick(folderIds) }, {}, null]));
  }
  for (const key of k.some(groupKeys, 0.5)) {
    base.set(`pin:g:${key}`, dropUndefined({ pos: k.pick([...POSITIONS, undefined]), n: "Old" }));
    if (k.chance(0.3)) base.set(`pgc:${key}`, k.pick(["none", "blue"]));
    if (k.chance(0.4)) base.set(`pord:g:${key}`, k.pick([{ a: k.pick([...tabKeys, null]) }, {}, { a: 5 }]));
  }
  for (const id of k.some(folderIds, 0.5)) base.set(`tilefold:n:${id}`, k.pick([{ n: "Synced" }, { n: 5 }, {}]));
  return base;
}

function pinChoicesFor(k, keys, profiles) {
  const { tabKeys, groupKeys } = keys;
  const mine = () =>
    Object.fromEntries(
      [...k.some(tabKeys, 0.2).map((key) => k.pick([`place:${key}`, key])), ...k.some(groupKeys, 0.2).map((key) => k.pick([`group:${key}`, `order:${key}`]))].map((c, i) => [c, 100 + i]),
    );
  const pinChoices = Object.fromEntries(profiles.filter(() => k.chance(0.5)).map((p) => [p, mine()]));
  const pinSync = Object.fromEntries(
    profiles.filter(() => k.chance(0.4)).map((p) => [p, Object.fromEntries(k.some(tabKeys, 0.3).map((key) => [key, k.pick([{ g: k.pick(groupKeys) ?? "x", w: k.pick([0, 5, 1e15]) }, { g: k.pick(groupKeys) ?? "x" }, {}])]))]),
  );
  useBrowser.setState({ pinChoices, pinSync });
}

const PINNED_FACTORIES = ["tileFoldersAdapter", "pinnedRowsAdapter", "pinnedOrderAdapter", "groupLooksAdapter", "pinnedHomesAdapter", "pinnedAdapter"];

function attempt(fn) {
  try {
    return fn();
  } catch (error) {
    if (process.env.ADAPTER_FUZZ_LOUD) console.error(`pinned fuzz: ${error?.stack ?? error}`);
    return undefined;
  }
}

const PIN_BATCH = 5;

function pinnedRun(run) {
  {
    const k = kit(17000 + run);
    const { profiles } = pinnedWorld(k);
    const keys = worldKeys(k);
    pinChoicesFor(k, keys, profiles);
    const profileId = k.pick(profiles);
    const base = pinBase(k, keys);
    const records = pinRecords(k, keys);
    const remote = new Map(records.filter(() => k.chance(0.7)));
    for (const key of k.some([...base.keys()], 0.2)) remote.set(key, null);
    const known = new Set([...base.keys(), ...records.map(([key]) => key)].filter(() => k.chance(0.5)));
    const stamps = new Map([...base.keys(), ...records.map(([key]) => key)].filter(() => k.chance(0.5)).map((key) => [key, k.pick(["0001", "0002-b", "0003", "0002-a", "0010"])]));
    const now = k.pick([0, 5, 1e15]);
    for (const name of PINNED_FACTORIES) {
      const adapter = pinned[name](profileId);
      const extraction = attempt(() =>
        adapter.extract((key) => base.get(key), (key) => key.length % 3 === 0, now, (key) => known.has(key), (key) => remote.get(key), (key) => stamps.get(key)),
      );
      if (extraction) {
        for (const [key] of k.some(records, 0.3)) {
          extraction.ignore?.(key);
          extraction.republish?.(key);
        }
        if (extraction.published && k.chance(0.5)) attempt(() => extraction.published(new Set([...extraction.values.keys()].filter(() => k.chance(0.6)))));
      }
      const prefix = adapter.prefix;
      const mine = records.filter(([key]) => key.startsWith(prefix));
      const visible = new Map(mine.filter(() => k.chance(0.8)));
      const changed = new Set([...k.some(mine, 0.7).map(([key]) => key), ...k.some([...base.keys()].filter((key) => key.startsWith(prefix)), 0.3)]);
      if (k.chance(0.1)) changed.clear();
      attempt(() => adapter.apply(visible, changed, (key) => base.get(key), { known: (key) => known.has(key), now, horizon: k.pick([0, 1000, 7776000000]), joined: k.chance(0.2) }));
    }
  }
}

for (let batch = 0; batch < Math.ceil((RUNS * 2) / PIN_BATCH); batch++) {
  test(`pinned area: extract and apply over random pins, groups, folders, rows and records, batch ${batch}`, () => {
    for (let run = batch * PIN_BATCH; run < Math.min(RUNS * 2, (batch + 1) * PIN_BATCH); run++) pinnedRun(run);
  });
}

class FuzzFolder {
  files = new Map();
  counter = 0;
  transport() {
    return {
      write: async (scope, payload) => {
        const id = `f${++this.counter}`;
        this.files.set(id, { scope, payload });
        return id;
      },
      read: async (scope, known) => {
        const shown = [...this.files].filter(([, f]) => f.scope === scope);
        return { files: shown.filter(([id]) => !known.includes(id)).map(([id, f]) => ({ id, payload: f.payload })), pending: [], damaged: [], present: shown.map(([id]) => id) };
      },
      remove: async (_scope, ids) => ids.forEach((id) => this.files.delete(id)),
    };
  }
}

async function pinnedPair(run) {
  {
    const k = kit(21000 + run);
    const folder = new FuzzFolder();
    const devices = ["a", "b"].map((id, i) => {
      if (i === 0) pinnedWorld(k);
      else S().hydrate({});
      return { id, browser: S(), scope: emptyScope(), clock: new Clock(id) };
    });
    const sync = async (d) => {
      useBrowser.setState(d.browser, true);
      try {
        await syncScope({ scope: "p", state: d.scope, transport: folder.transport(), adapters: pinned.pinnedAreaAdapters("default"), clock: d.clock, device: d.id });
      } catch (error) {
        if (process.env.ADAPTER_FUZZ_LOUD) console.error(`pinned sync fuzz: ${error?.stack ?? error}`);
      } finally {
        d.browser = S();
      }
    };
    for (let round = 0; round < 4; round++) {
      const d = k.pick(devices);
      useBrowser.setState(d.browser, true);
      const s = S();
      const w = s.windowOrder.find((id) => !s.windows[id]?.incognito) ?? S().createWindow();
      const tabs = (S().windows[w]?.tabIds ?? []).filter((id) => S().tabs[id]?.profileId === "default");
      attempt(() => {
        const pick = k.pick(tabs);
        switch (k.pick(["pin", "row", "unpin", "group", "color", "folder", "rename", "new"])) {
          case "pin": if (pick) S().pinTabs([pick], true); break;
          case "row": if (pick) S().pinTabs([pick], true, true); break;
          case "unpin": if (pick) S().pinTabs([pick], false); break;
          case "group": if (tabs.length >= 2) S().groupTabs(tabs.slice(-2), { pinned: true, name: "Synced" }); break;
          case "color": { const g = Object.values(S().groups).find((x) => x.pinned); if (g) S().updateGroup(g.id, { color: k.pick(["none", "blue"]) }); break; }
          case "folder": { const t = tabs.filter((id) => S().tabs[id]?.pinned && !S().tabs[id].pinnedAsRow); if (t.length >= 2) useBrowser.setState(tileFolders.newTileFolder(S(), t.slice(0, 2), "F").state, true); break; }
          case "rename": { const t = tabs.find((id) => S().tabs[id]?.tileFolder); if (t) useBrowser.setState(tileFolders.renameTileFolder(S(), w, S().tabs[t].tileFolder.id, k.pick(["Renamed", "Other"])), true); break; }
          default: S().newTab(w, { url: k.pick(PIN_URLS.filter(Boolean)), background: true });
        }
      });
      d.browser = S();
      await sync(d);
      await sync(k.pick(devices));
    }
  }
}

for (let run = 0; run < Math.max(2, Math.floor(RUNS / 4)); run++) {
  test(`pinned area: two Macs edit pins at random and sync, run ${run}`, () => pinnedPair(run));
}

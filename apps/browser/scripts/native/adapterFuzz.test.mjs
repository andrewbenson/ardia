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

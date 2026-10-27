#!/usr/bin/env node
import { fork } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { registerHooks } from "node:module";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { deflateRawSync } from "node:zlib";

const HELP = `usage: node scripts/native/engineScenario.mjs [--out <dir>] [--runs <n>] [--steps <n>] [--seed <n>]

Runs sync engine scenarios through the real engine.ts, the JS store and every JS adapter, over fake
natives (a shared in-memory sync folder, sealing as "sealed:<text>", documents in memory, timers that
only fire when a step fires them). A second Mac runs in a child process with its own module memory and
reaches the folder through the parent, so the folder holds what two real Macs would leave in it.

Each scenario's trace is per step: the native calls this Mac made in order (folder reads, writes and
removes with their answers, chain status, device ids, phrases, unlock, forget, deviceName,
readPasswords, the extension probe), each sync.json and journal-before-write save, and each UI publish;
then at the step's end, drained, the documents (sync.json and the plaintext of the sealed state and
journal), the store's state, the bookmark tree, the history lists, the engine's memory and its pending
timers. Writes of the sealed state and later journal rewrites happen on a detached chain in JS, so they
are left out of the ordered calls and compared at step ends instead. Every folder write also records
whether the journal on disk already held its batch.

SolaraSyncTests replays the scripts through the Swift engine, answering native calls from the trace.
Default out: native/SolaraKit/Tests/SolaraSyncTests/Scenarios (engine.json.deflate).`;

const args = process.argv.slice(2);
if (args.includes("--help")) {
  console.log(HELP);
  process.exit(0);
}
const option = (name, fallback) => {
  const at = args.indexOf(name);
  return at < 0 ? fallback : args[at + 1];
};
const here = dirname(fileURLToPath(import.meta.url));
const app = resolve(here, "../..");
const out = resolve(option("--out", join(app, "../../native/SolaraKit/Tests/SolaraSyncTests/Scenarios")));
const runs = Number(option("--runs", "40"));
const stepsPerRun = Number(option("--steps", "45"));
const firstSeed = Number(option("--seed", "1"));
const role = option("--role", "parent");
const oracleRuns = Number(option("--oracle", "0"));

const START = 1_793_000_000_000;

function mulberry32(seed) {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const plain = (v) => (v === undefined ? null : JSON.parse(JSON.stringify(v)));

async function environment(prefix, folderOps) {
  let now = START;
  Date.now = () => now;
  Math.random = mulberry32(prefix === "o" ? 0xbeef : 0x5eed);
  globalThis.__DEV__ = false;
  const pendingTimers = [];
  let timerIds = 0;
  let calls = null;
  globalThis.setTimeout = (fn, delay = 0, ...rest) => {
    const id = ++timerIds;
    if (delay === 100 || delay === 250) setImmediate(() => fn(...rest));
    else {
      pendingTimers.push({ id, delay, fn: () => fn(...rest) });
      calls?.push({ timer: delay });
    }
    return id;
  };
  globalThis.clearTimeout = (id) => {
    const at = pendingTimers.findIndex((t) => t.id === id);
    if (at < 0) return;
    calls?.push({ cancel: pendingTimers[at].delay });
    pendingTimers.splice(at, 1);
  };
  const heldNatives = new Set();
  const nativeGates = [];
  const gate = async (name) => {
    if (heldNatives.has(name)) await new Promise((resolve) => nativeGates.push(resolve));
  };
  const modes = { chain: "ok", unlock: true, phrase: true };
  let deviceIds = 0;
  const recordCall = (n, a, r) => calls?.push(r === undefined ? { n, a: plain(a) } : { n, a: plain(a), r: plain(r) });
  const shellFake = { docs: null, journalHolds: null };
  const native = {
    newDeviceId: () => {
      const id = `${prefix}dev${++deviceIds}`;
      recordCall("newDeviceId", [], id);
      return id;
    },
    deviceName: () => {
      const name = prefix === "o" ? "Other Mac" : "This Mac";
      recordCall("deviceName", [], name);
      return name;
    },
    createPhrase: async (account) => (await gate("createPhrase"), recordCall("createPhrase", [account], modes.phrase), modes.phrase),
    enterPhrase: async (account, text, folder) => {
      await gate("enterPhrase");
      const result = modes.phrase ? { ok: true } : { error: "mismatch" };
      recordCall("enterPhrase", [account, text, folder], result);
      return result;
    },
    unlock: async (account) => (await gate("unlock"), recordCall("unlock", [account], modes.unlock), modes.unlock),
    forget: async (account) => (await gate("forget"), void recordCall("forget", [account])),
    chainStatus: async (folder) => (await gate("chainStatus"), recordCall("chainStatus", [folder], modes.chain), modes.chain),
    createChain: async (folder) => {
      await folderOps("createChain", []);
      recordCall("createChain", [folder]);
    },
    deleteChain: async (folder) => {
      await folderOps("deleteChain", []);
      recordCall("deleteChain", [folder]);
    },
    write: async (folder, scope, payload) => {
      await gate("write");
      const file = JSON.parse(payload);
      const held = shellFake.journalHolds(scope, file);
      const id = await folderOps("write", [scope, payload]);
      calls?.push({ n: "write", a: [folder, scope, payload], r: id, journaled: held });
      return id;
    },
    read: async (folder, scope, known) => {
      await gate("read");
      const listing = await folderOps("read", [scope, known]);
      recordCall("read", [folder, scope, known], listing);
      return listing;
    },
    remove: async (folder, scope, ids) => {
      await folderOps("remove", [scope, ids]);
      recordCall("remove", [folder, scope, ids]);
    },
    sealLocal: async (text) => (await gate("sealLocal"), `sealed:${text}`),
    openLocal: async (sealed) => (await gate("openLocal"), sealed.startsWith("sealed:") ? sealed.slice(7) : null),
    readPasswords: async (profile) => (recordCall("readPasswords", [profile], null), null),
    folderInfo: async () => ({ path: "/sync", defaultPath: "/sync", iCloudAvailable: false, inICloud: false, exists: true, writable: true, hasSyncData: true }),
    chooseFolder: async () => null,
  };
  globalThis.acTestNativeModules = { ArdiaSync: native };
  await import(pathToFileURL(join(app, "src/test-loader.mjs")).href);
  registerHooks({
    load(url, context, next) {
      const loaded = next(url, context);
      if (loaded.source == null) return loaded;
      let source = typeof loaded.source === "string" ? loaded.source : new TextDecoder().decode(loaded.source);
      if (url.includes("/src/sync/engine.ts")) {
        source = source.replace(
          "if (profiles.length && (await probeExtensionSync(profiles[0]!))) watchExtensionIntents(profiles);",
          "if (profiles.length && (await globalThis.__traceProbe(profiles[0]!, () => probeExtensionSync(profiles[0]!)))) watchExtensionIntents(profiles);",
        );
        source = source.replace("  useBrowser.subscribe((s, prev) => {", "  globalThis.__engineUnsubscribe = useBrowser.subscribe((s, prev) => {");
        source += `\nglobalThis.__engineMemory = () => ({ loaded, doc, savedJson, savedState, journal, journalOnDisk, forcePasswords, running, again, sealing: !!sealing, passwords: Object.fromEntries([...passwordAdapters].map(([k, a]) => [k, a.__replayMemory?.() ?? null])), extensions: [...extensionAdapters.keys()] });\nglobalThis.__engineUi = useSync;\n`;
      } else if (url.endsWith("/src/sync/adapters.ts")) {
        source = source.replace('  return {\n    prefix: "pw:",', '  return {\n    __replayMemory: () => ({ lastRead, quietUntil, created: [...created] }),\n    prefix: "pw:",');
      } else if (url.endsWith("/src/store/model.ts")) {
        source += "\nglobalThis.__modelMemory = { read: () => ({ launch, counter, navSeq }) };\n";
      } else if (url.endsWith("/src/sync/pinned.ts")) {
        source += "\nglobalThis.__pinnedMemory = { read: () => Object.fromEntries([...localFolders].map(([k, v]) => [k, [...v].sort()])) };\n";
      } else {
        return loaded;
      }
      return { ...loaded, source };
    },
  });
  globalThis.__traceProbe = async (profile, run) => {
    const answer = await run();
    recordCall("probeExtensionSync", [profile], answer);
    return answer;
  };
  const shell = await import(pathToFileURL(join(app, "src/test-native/index.ts")).href);
  const disk = new Map();
  const staged = new Map();
  const landing = [];
  const retrying = [];
  const docMode = { hold: false, fail: false };
  let generation = 0;
  const stage = (name, contents, done) => {
    const old = staged.get(name);
    const mine = ++generation;
    staged.set(name, { generation: mine, contents, waiters: [...(old?.waiters ?? []), ...(done ? [done] : [])] });
    landing.push([name, mine]);
    if (name === "sync.json") calls?.push({ doc: name, contents });
    else if (process.env.ENGINE_DOC_EVENTS) calls?.push({ staged: name, generation: mine, contents: contents.slice(0, 400), waiter: !!done });
  };
  const landOne = ([name, mine]) => {
    const save = staged.get(name);
    if (!save || save.generation !== mine) return;
    const waiters = save.waiters;
    if (docMode.fail) {
      save.waiters = [];
      retrying.push([name, mine]);
      for (const done of waiters) done(new Error("disk full"));
      return;
    }
    disk.set(name, save.contents);
    staged.delete(name);
    if (process.env.ENGINE_DOC_EVENTS) calls?.push({ landed: name, generation: mine, waiters: waiters.length });
    for (const done of waiters) done(null);
  };
  const landAll = () => {
    if (!docMode.fail) landing.push(...retrying.splice(0));
    while (landing.length) landOne(landing.shift());
  };
  const shellModule = shell.shellNativeModules.ArdiaShell;
  shellModule.readDocument = (name) => staged.get(name)?.contents ?? disk.get(name) ?? null;
  shellModule.writeDocument = (name, contents) => stage(name, contents, null);
  shellModule.saveDocument = (name, contents) => new Promise((resolve, reject) => stage(name, contents, (error) => (error ? reject(error) : resolve())));
  shellModule.removeDocument = (name) => {
    staged.delete(name);
    disk.delete(name);
  };
  shellFake.journalHolds = (scope, file) => {
    if (file.kind !== "log") return null;
    const holds = (list) => (list ?? []).some((f) => f.device === file.device && f.seq === file.seq);
    const opened = (name) => {
      const text = disk.get(name);
      if (!text?.startsWith("sealed:")) return null;
      try {
        return JSON.parse(text.slice(7));
      } catch {
        return null;
      }
    };
    return holds(opened("sync-journal.nns")?.journal?.[scope]) || holds(opened("sync-state.nns")?.[scope]?.journal);
  };
  const { useBrowser } = await import(pathToFileURL(join(app, "src/store/browser.ts")).href);
  const { encodeArgs } = await import(pathToFileURL(join(app, "../../packages/store/src/encode.ts")).href);
  const S = () => useBrowser.getState();
  S().hydrate({});
  useBrowser.setState({ bookmarksReady: { default: true }, historyReady: { default: true }, history: { default: [] } });
  S().createWindow();

  let engine = null;
  let launches = 0;
  const edits = [];
  let everUpdated = false;
  const edited = (kind, key, value) => edits.push({ kind, key, value, cycles: 0, exempt: kind !== "bookmark" && !everUpdated });
  const inFlight = [];
  let unsubscribe = null;
  const launch = async () => {
    unsubscribe?.();
    globalThis.__engineUnsubscribe?.();
    globalThis.__engineUnsubscribe = null;
    pendingTimers.splice(0);
    inFlight.splice(0);
    heldNatives.clear();
    nativeGates.splice(0);
    engine = await import(`${pathToFileURL(join(app, "src/sync/engine.ts")).href}?${prefix}${++launches}`);
    const ui = globalThis.__engineUi;
    unsubscribe = ui.subscribe((state) => {
      calls?.push({ publish: plain(state) });
      if (state.status === "updated") {
        everUpdated = true;
        for (const edit of edits) edit.cycles++;
      }
    });
  };
  await launch();

  const drain = async () => {
    for (let i = 0; i < 400; i++) {
      if (!docMode.hold) landAll();
      await new Promise((r) => setImmediate(r));
    }
  };

  const command = (name, ...callArgs) => {
    const result = S()[name](...callArgs);
    calls?.push({ store: { name, args: plain(encodeArgs(name, callArgs)) } });
    return result;
  };
  const jsOnly = () => calls?.push({ host: plain({ bookmarks: S().bookmarks, history: S().history, historyReady: S().historyReady, bookmarksReady: S().bookmarksReady }) });

  const remoteProfiles = () => globalThis.__engineUi.getState().remoteProfiles;
  const profileIds = () => S().profileOrder;

  async function runStep(step) {
    const pick = (list, i) => (list.length ? list[Math.abs(i ?? 0) % list.length] : undefined);
    switch (step.op) {
      case "start":
        engine.startSync();
        break;
      case "turnOn":
        inFlight.push(engine.turnOnSync(step.folder));
        break;
      case "join":
        inFlight.push(engine.enterRecoveryPhrase(step.folder, step.phrase));
        break;
      case "syncNow":
        inFlight.push(engine.syncNow());
        break;
      case "fire": {
        const due = pendingTimers.splice(0);
        for (const t of due) t.fn();
        break;
      }
      case "stop":
        inFlight.push(engine.stopSync({ deleteData: !!step.deleteData }));
        break;
      case "type":
        engine.setTypeSynced(step.type, step.value);
        break;
      case "profileSynced": {
        const id = pick(profileIds(), step.profile);
        if (id) engine.setProfileSynced(id, step.value);
        break;
      }
      case "addRemote": {
        const remote = pick(remoteProfiles(), step.pick);
        if (remote) engine.addRemoteProfile(remote.syncId);
        break;
      }
      case "adoptTheme": {
        const id = pick(profileIds(), step.profile);
        if (id) engine.adoptProfileTheme(id);
        break;
      }
      case "relaunch":
        if (docMode.fail && globalThis.__engineMemory().doc.rebuilding?.length) for (const edit of edits) if (edit.cycles < 2 && edit.kind !== "bookmark") edit.exempt = true;
        if (!docMode.fail) for (const [name, save] of staged) disk.set(name, save.contents);
        staged.clear();
        landing.splice(0);
        retrying.splice(0);
        await launch();
        break;
      case "snapshot":
        globalThis.__snapshot = new Map(disk);
        break;
      case "crash":
        if (globalThis.__engineMemory().doc.rebuilding?.length) for (const edit of edits) if (edit.cycles < 2 && edit.kind !== "bookmark") edit.exempt = true;
        staged.clear();
        landing.splice(0);
        retrying.splice(0);
        if (step.snapshot && globalThis.__snapshot) {
          disk.clear();
          for (const [k, v] of globalThis.__snapshot) disk.set(k, v);
        }
        await launch();
        break;
      case "damage": {
        if (step.how === "newer") {
          const text = staged.get(step.doc)?.contents ?? disk.get(step.doc);
          if (!text?.startsWith("sealed:")) break;
          let parsed;
          try {
            parsed = JSON.parse(text.slice(7));
          } catch {
            break;
          }
          for (const scope of Object.values(parsed)) if (scope && typeof scope === "object") delete scope.seen, (scope.newerField = { added: true });
          staged.delete(step.doc);
          disk.set(step.doc, `sealed:${JSON.stringify(parsed)}`);
          break;
        }
        for (const edit of edits) if (edit.cycles < 2 && edit.kind !== "bookmark") edit.exempt = true;
        const damaged = { drop: null, corrupt: "sealed:{\"app\":", foreign: "sealed-elsewhere:{}", malformed: 'sealed:{"journal":{"app":[{"v":1,"kind":"log","device":"x","seq":1}]}}' }[step.how];
        staged.delete(step.doc);
        if (damaged === null) disk.delete(step.doc);
        else disk.set(step.doc, damaged);
        break;
      }
      case "holdNative":
        for (const name of step.names) heldNatives.add(name);
        break;
      case "releaseNative":
        heldNatives.clear();
        for (const release of nativeGates.splice(0)) release();
        break;
      case "mode":
        modes[step.key] = step.value;
        break;
      case "hold":
        docMode.hold = step.value;
        break;
      case "failDocs":
        docMode.fail = step.value;
        break;
      case "land":
        landAll();
        break;
      case "advance":
        now += step.ms;
        break;
      case "bookmark": {
        const profileId = pick(profileIds(), step.profile) ?? "default";
        S().addBookmark({ profileId, url: step.url, title: step.title });
        if (profileId === "default") edited("bookmark", `${step.url}|${step.title}`, true);
        jsOnly();
        break;
      }
      case "visit": {
        const profileId = pick(profileIds(), step.profile) ?? "default";
        const list = [...(S().history[profileId] ?? [])].filter((e) => e.url !== step.url);
        list.unshift({ url: step.url, title: step.title, favicon: null, visits: step.visits ?? 1, lastVisit: now, visitTimes: [now] });
        useBrowser.setState({ history: { ...S().history, [profileId]: list }, historyReady: { ...S().historyReady, [profileId]: true } });
        jsOnly();
        break;
      }
      case "createProfile": {
        const id = command("createProfile", { name: step.name, color: step.color ?? "blue", icon: null, ...(step.share ? { shareWith: "default" } : {}) });
        useBrowser.setState({ bookmarksReady: { ...S().bookmarksReady, [id]: true } });
        jsOnly();
        break;
      }
      case "rename": {
        const id = pick(profileIds(), step.profile);
        if (id) command("updateProfile", id, { name: step.name });
        if (id === "default") edited("name", "default", step.name);
        break;
      }
      case "theme": {
        const id = pick(profileIds(), step.profile);
        if (id) command("updateProfile", id, { theme: step.theme });
        break;
      }
      case "settings":
        command("updateSettings", step.patch);
        for (const [key, value] of Object.entries(step.patch)) edited("setting", key, value);
        break;
      case "recover": {
        const status = globalThis.__engineUi.getState().status;
        if (status === "locked") inFlight.push(engine.enterRecoveryPhrase("/sync", "abandon ability"));
        break;
      }
      case "pin": {
        const w = S().windowOrder[0];
        if (!w) break;
        const tab = command("newTab", w, { url: step.url });
        command("togglePin", tab);
        break;
      }
      case "deleteProfile": {
        const id = pick(profileIds().filter((p) => p !== "default"), step.profile);
        if (id) command("deleteProfile", id);
        break;
      }
      default:
        throw new Error(`unknown step ${step.op}`);
    }
  }

  const sorted = (map) =>
    Object.fromEntries(
      [...map]
        .filter(([name]) => name.startsWith("sync"))
        .sort(([a], [b]) => (a < b ? -1 : 1))
        .map(([name, value]) => [name, typeof value === "string" ? value : value.contents]),
    );
  const snapshotDocs = () => ({ disk: sorted(disk), staged: sorted(staged) });

  const boundary = () => {
    const s = S();
    return plain({
      docs: snapshotDocs(),
      state: projectState(s),
      host: { bookmarks: s.bookmarks, history: s.history, historyReady: s.historyReady, bookmarksReady: s.bookmarksReady },
      memory: globalThis.__engineMemory(),
      model: globalThis.__modelMemory.read(),
      tileFolders: globalThis.__pinnedMemory?.read() ?? {},
      timers: pendingTimers.map((t) => t.delay),
      held: landing.length + retrying.length,
      heldNatives: nativeGates.length,
      inFlight: inFlight.length,
    });
  };

  const report = () => {
    const s = S();
    const roots = s.bookmarks.roots.default;
    const inside = new Set();
    const walk = (id) => {
      const node = s.bookmarks.nodes[id];
      if (!node) return;
      if (node.kind === "url") inside.add(`${node.url}|${node.title}`);
      else node.children.forEach(walk);
    };
    if (roots) [roots.bar, roots.other].forEach(walk);
    return plain({
      status: globalThis.__engineUi.getState().status,
      bookmarks: [...inside].sort(),
      settings: Object.fromEntries(["searchEngine", "tabLayout", "warnBeforeQuitting", "appearance"].map((k) => [k, s.settings[k]])),
      name: s.profiles.default?.name,
      edits,
    });
  };

  return {
    report,
    init: () =>
      plain({ state: projectState(S()), model: globalThis.__modelMemory.read(), host: { bookmarks: S().bookmarks, history: S().history, historyReady: S().historyReady, bookmarksReady: S().bookmarksReady } }),
    async step(step) {
      calls = [];
      const loadedBefore = globalThis.__engineMemory().loaded;
      await runStep(step);
      await drain();
      const memory = globalThis.__engineMemory();
      if (memory.loaded && (!loadedBefore || step.op === "start") && memory.doc.rebuilding?.length)
        for (const edit of edits) if (edit.cycles < 2 && edit.kind !== "bookmark") edit.exempt = true;
      for (const p of [...inFlight]) {
        const settled = await Promise.race([p.then(() => true, () => true), new Promise((r) => setImmediate(() => r(false)))]);
        if (settled) inFlight.splice(inFlight.indexOf(p), 1);
      }
      const made = calls;
      calls = null;
      return { calls: made, after: boundary() };
    },
  };
}

function projectState(s) {
  return plain({
    profiles: s.profiles,
    profileOrder: s.profileOrder,
    orphanedProfileData: s.orphanedProfileData,
    windows: s.windows,
    windowOrder: s.windowOrder,
    tabs: s.tabs,
    groups: s.groups,
    splits: s.splits,
    peeks: s.peeks,
    closedTabs: s.closedTabs,
    closedWindows: s.closedWindows,
    closedGroups: s.closedGroups,
    deletedGroups: s.deletedGroups,
    cleanedTabs: s.cleanedTabs,
    privateCleanedTabs: s.privateCleanedTabs,
    privateSiteMutes: s.privateSiteMutes,
    parkedPins: s.parkedPins,
    pinChoices: s.pinChoices,
    pinSync: s.pinSync,
    downloads: s.downloads,
    settings: s.settings,
    ui: { focusedWindowId: s.ui.focusedWindowId, focusOrder: s.ui.focusOrder, lastProfileId: s.ui.lastProfileId },
  });
}

const THEME = { stops: [{ x: 0.2, y: 0.3, color: { r: 0.3, g: 0.75, b: 0.45, a: 1 } }], intensity: 0.8, mode: "auto", grain: 0.4, texture: "grain", translucency: 1, angle: 30 };

export function randomScript(seed, steps) {
  const rand = mulberry32(seed);
  const pick = (list) => list[Math.floor(rand() * list.length)];
  const n = () => Math.floor(rand() * 4);
  const script = { name: `random ${seed}`, steps: [] };
  const push = (mac, step) => script.steps.push({ mac, ...step });
  push("local", { op: "start" });
  push("other", { op: "start" });
  if (rand() < 0.5) {
    push("local", { op: "turnOn", folder: "/sync" });
    push("other", { op: "join", folder: "/sync", phrase: "abandon ability" });
  } else {
    push("other", { op: "turnOn", folder: "/sync" });
    push("local", { op: "join", folder: "/sync", phrase: "abandon ability" });
  }
  for (let i = 0; i < steps; i++) {
    const mac = rand() < 0.65 ? "local" : "other";
    const r = rand();
    if (r < 0.2) push(mac, { op: pick(["syncNow", "fire", "fire"]) });
    else if (r < 0.3) push(mac, { op: "bookmark", profile: n(), url: pick(["https://a.com/", "https://b.org/x", "https://c.net/"]), title: pick(["A", "B", "Ünï"]) });
    else if (r < 0.36) push(mac, { op: "visit", profile: n(), url: pick(["https://a.com/", "https://h.org/"]), title: "Visited" });
    else if (r < 0.42) push(mac, { op: "createProfile", name: pick(["Work", "School", "Ünï"]), share: rand() < 0.3 });
    else if (r < 0.47) push(mac, { op: "rename", profile: n(), name: pick(["Renamed", "Other", "Work"]) });
    else if (r < 0.5) push(mac, { op: "theme", profile: n(), theme: rand() < 0.3 ? null : { ...THEME, angle: Math.floor(rand() * 360) } });
    else if (r < 0.55) push(mac, { op: "settings", patch: pick([{ searchEngine: "duckduckgo" }, { tabLayout: "topbar" }, { warnBeforeQuitting: false }, { appearance: "dark" }]) });
    else if (r < 0.6) push(mac, { op: "pin", url: pick(["https://p.com/", "https://q.com/"]) });
    else if (r < 0.63) push(mac, { op: "addRemote", pick: n() });
    else if (r < 0.65) push(mac, { op: "profileSynced", profile: n(), value: rand() < 0.5 });
    else if (r < 0.67) push(mac, { op: "type", type: pick(["bookmarks", "history", "tabs", "pinned", "passwords", "extensions", "settings"]), value: rand() < 0.5 });
    else if (r < 0.69) push(mac, { op: "adoptTheme", profile: n() });
    else if (r < 0.71) push(mac, { op: "relaunch" }), push(mac, { op: "start" });
    else if (r < 0.73) push(mac, { op: "snapshot" });
    else if (r < 0.745) push(mac, { op: "crash", snapshot: rand() < 0.4 }), push(mac, { op: "start" });
    else if (r < 0.76) push(mac, { op: "mode", key: "chain", value: pick(["ok", "ok", "unavailable", "missing"]) });
    else if (r < 0.77) push(mac, { op: "mode", key: "unlock", value: rand() < 0.6 });
    else if (r < 0.79) push(mac, { op: "hold", value: rand() < 0.5 });
    else if (r < 0.81) push(mac, { op: "land" });
    else if (r < 0.83) push(mac, { op: "deleteProfile", profile: n() });
    else if (r < 0.845) push(mac, { op: "stop", deleteData: rand() < 0.3 });
    else if (r < 0.86) push(mac, { op: pick(["turnOn", "join"]), folder: "/sync", phrase: "abandon ability" });
    else if (r < 0.9) push(mac, { op: "holdNative", names: [pick(["read", "write", "chainStatus", "unlock", "sealLocal", "openLocal", "forget", "createPhrase", "enterPhrase"])] });
    else if (r < 0.93) push(mac, { op: "releaseNative" });
    else if (r < 0.945) push(mac, { op: "damage", doc: pick(["sync-state.nns", "sync-journal.nns"]), how: pick(["drop", "corrupt", "foreign", "malformed"]) }), push(mac, { op: "relaunch" }), push(mac, { op: "start" });
    else if (r < 0.955) push(mac, { op: "failDocs", value: rand() < 0.5 });
    else push(mac, { op: "advance", ms: pick([1000, 60_000, 3_600_000, 91 * 86_400_000]) });
  }
  for (const mac of ["local", "other"]) {
    push(mac, { op: "mode", key: "chain", value: "ok" });
    push(mac, { op: "mode", key: "unlock", value: true });
    push(mac, { op: "hold", value: false });
    push(mac, { op: "failDocs", value: false });
    push(mac, { op: "releaseNative" });
    push(mac, { op: "land" });
  }
  for (let round = 0; round < 3; round++) for (const mac of ["local", "other"]) push(mac, { op: "syncNow" });
  return script;
}

export const namedScripts = () => [
  {
    name: "turn on, edit, sync both ways",
    steps: [
      { mac: "local", op: "start" },
      { mac: "local", op: "turnOn", folder: "/sync" },
      { mac: "local", op: "bookmark", profile: 0, url: "https://one.example/", title: "One" },
      { mac: "local", op: "syncNow" },
      { mac: "other", op: "start" },
      { mac: "other", op: "join", folder: "/sync", phrase: "abandon ability" },
      { mac: "other", op: "syncNow" },
      { mac: "other", op: "bookmark", profile: 0, url: "https://two.example/", title: "Two" },
      { mac: "other", op: "syncNow" },
      { mac: "local", op: "fire" },
      { mac: "local", op: "syncNow" },
    ],
  },
  {
    name: "a crash after a batch lands is sent again as it was",
    steps: [
      { mac: "local", op: "start" },
      { mac: "local", op: "turnOn", folder: "/sync" },
      { mac: "local", op: "bookmark", profile: 0, url: "https://one.example/", title: "One" },
      { mac: "local", op: "syncNow" },
      { mac: "local", op: "snapshot" },
      { mac: "local", op: "bookmark", profile: 0, url: "https://two.example/", title: "Two" },
      { mac: "local", op: "syncNow" },
      { mac: "local", op: "crash", snapshot: true },
      { mac: "local", op: "start" },
      { mac: "local", op: "bookmark", profile: 0, url: "https://three.example/", title: "Three" },
      { mac: "local", op: "syncNow" },
    ],
  },
  {
    name: "a held journal save holds the batch back",
    steps: [
      { mac: "local", op: "start" },
      { mac: "local", op: "turnOn", folder: "/sync" },
      { mac: "local", op: "syncNow" },
      { mac: "local", op: "hold", value: true },
      { mac: "local", op: "bookmark", profile: 0, url: "https://held.example/", title: "Held" },
      { mac: "local", op: "syncNow" },
      { mac: "local", op: "hold", value: false },
      { mac: "local", op: "land" },
      { mac: "local", op: "syncNow" },
    ],
  },
  {
    name: "locked, then the phrase, then reset from elsewhere",
    steps: [
      { mac: "local", op: "start" },
      { mac: "local", op: "turnOn", folder: "/sync" },
      { mac: "local", op: "syncNow" },
      { mac: "local", op: "mode", key: "unlock", value: false },
      { mac: "local", op: "relaunch" },
      { mac: "local", op: "start" },
      { mac: "local", op: "join", folder: "/sync", phrase: "abandon ability" },
      { mac: "local", op: "syncNow" },
      { mac: "local", op: "mode", key: "chain", value: "missing" },
      { mac: "local", op: "syncNow" },
      { mac: "local", op: "mode", key: "chain", value: "ok" },
      { mac: "local", op: "turnOn", folder: "/sync" },
      { mac: "local", op: "syncNow" },
    ],
  },
  {
    name: "profiles: remote ones are added, shared data follows, themes pair",
    steps: [
      { mac: "other", op: "start" },
      { mac: "other", op: "createProfile", name: "Work" },
      { mac: "other", op: "createProfile", name: "Shared", share: true },
      { mac: "other", op: "theme", profile: 1, theme: THEME },
      { mac: "other", op: "turnOn", folder: "/sync" },
      { mac: "other", op: "syncNow" },
      { mac: "local", op: "start" },
      { mac: "local", op: "createProfile", name: "Work" },
      { mac: "local", op: "join", folder: "/sync", phrase: "abandon ability" },
      { mac: "local", op: "syncNow" },
      { mac: "local", op: "addRemote", pick: 0 },
      { mac: "local", op: "addRemote", pick: 0 },
      { mac: "local", op: "fire" },
      { mac: "local", op: "adoptTheme", profile: 1 },
      { mac: "local", op: "syncNow" },
      { mac: "local", op: "profileSynced", profile: 1, value: false },
      { mac: "local", op: "syncNow" },
      { mac: "local", op: "stop", deleteData: false },
    ],
  },
];

function inChild(roleName, message) {
  return new Promise((resolve, reject) => {
    const child = fork(fileURLToPath(import.meta.url), ["--role", roleName], { execArgv: ["--no-warnings", "--max-old-space-size=4096"], cwd: app, stdio: ["ignore", "inherit", "inherit", "ipc"] });
    const deadline = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`${roleName} hung for 60 s`));
    }, 60_000);
    child.once("message", (reply) => {
      clearTimeout(deadline);
      child.kill();
      resolve(reply);
    });
    child.once("exit", (code) => code && reject(new Error(`${roleName} exited with ${code}`)));
    child.send(message);
  });
}

async function parent() {
  if (oracleRuns) return oracle();
  const scripts = [...namedScripts(), ...Array.from({ length: runs }, (_, i) => randomScript(firstSeed + i, stepsPerRun))];
  const cases = [];
  let crashed = 0;
  for (const script of scripts) {
    try {
      cases.push((await inChild("local", { script })).trace);
    } catch (error) {
      crashed++;
      console.error(`${script.name}: ${error.message}`);
    }
  }
  if (crashed) console.error(`${crashed} scenarios crashed`);
  mkdirSync(out, { recursive: true });
  const text = JSON.stringify({ cases });
  writeFileSync(join(out, "engine.json.deflate"), deflateRawSync(Buffer.from(text), { level: 9 }));
  const steps = cases.reduce((n, c) => n + c.steps.length, 0);
  const writes = cases.reduce((n, c) => n + c.steps.reduce((m, s) => m + (s.calls ?? []).filter((x) => x.n === "write").length, 0), 0);
  const unjournaled = cases.reduce((n, c) => n + c.steps.reduce((m, s) => m + (s.calls ?? []).filter((x) => x.n === "write" && x.journaled === false).length, 0), 0);
  console.log(`${cases.length} scenarios, ${steps} steps, ${writes} folder writes (${unjournaled} before their journal), ${(text.length / 1e6).toFixed(1)} MB`);
  process.exit(0);
}

async function oracle() {
  let failed = 0;
  for (let i = 0; i < oracleRuns; i++) {
    const script = oracleScript(firstSeed + i, stepsPerRun);
    let verdict;
    try {
      verdict = (await inChild("local", { script })).trace.oracle;
    } catch (error) {
      verdict = [`crashed: ${error.message}`];
    }
    if (verdict.length) {
      failed++;
      if (failed <= 8) console.log(`${script.name}: ${verdict.slice(0, 3).join("; ")}`);
    }
  }
  console.log(`oracle: ${oracleRuns - failed} of ${oracleRuns} scenarios converge with every kept edit and no seq reused`);
  process.exit(failed ? 1 : 0);
}

async function runScenario(script) {
  const folder = new Map();
  let counter = 0;
  const published = new Map();
  const reused = [];
  const folderOps = async (op, a) => {
    switch (op) {
      case "write": {
        const [scope, payload] = a;
        const file = JSON.parse(payload);
        if (file.kind === "log") {
          const key = `${scope} ${file.device} ${file.seq}`;
          const ops = JSON.stringify(file.ops);
          if (published.has(key) && published.get(key) !== ops) reused.push(key);
          published.set(key, ops);
        }
        const id = `f${++counter}`;
        folder.set(id, { scope, payload });
        return id;
      }
      case "read": {
        const [scope, known] = a;
        const here = [...folder].filter(([, f]) => f.scope === scope);
        return { files: here.filter(([id]) => !known.includes(id)).map(([id, f]) => ({ id, payload: f.payload })), pending: [], damaged: [], present: here.map(([id]) => id) };
      }
      case "remove":
        for (const id of a[1]) folder.delete(id);
        return null;
      case "deleteChain":
        folder.clear();
        return null;
      default:
        return null;
    }
  };
  const child = fork(fileURLToPath(import.meta.url), ["--role", "other"], { execArgv: ["--no-warnings"], cwd: app, stdio: ["ignore", "ignore", "inherit", "ipc"] });
  child.once("exit", (code) => code && process.exit(3));
  const waiting = new Map();
  let ids = 0;
  child.on("message", async (message) => {
    if (message.folder) child.send({ reply: message.id, value: await folderOps(message.folder, message.args) });
    else if (message.done !== undefined) waiting.get(message.done)?.(message);
  });
  const ask = (payload) =>
    new Promise((resolve) => {
      const id = ++ids;
      waiting.set(id, resolve);
      child.send({ id, ...payload });
    });
  await ask({ ready: true });
  const local = await environment("", folderOps);
  const trace = { name: script.name, script, init: local.init(), steps: [] };
  for (const step of script.steps) {
    if (step.mac === "other") {
      const reply = await ask({ step });
      trace.steps.push({ other: true, error: reply.error ?? null, folder: [...folder.keys()] });
      continue;
    }
    try {
      trace.steps.push(await local.step(step));
    } catch (error) {
      trace.steps.push({ error: String(error?.message ?? error) });
    }
  }
  if (script.oracle) trace.oracle = oracleVerdict(local.report(), (await ask({ report: true })).report, reused);
  child.kill();
  return trace;
}

function oracleVerdict(local, other, reused) {
  const problems = reused.map((key) => `seq ${key} carried two different batches`);
  for (const mac of [local, other]) if (mac.status !== "updated") problems.push(`a Mac ended ${mac.status}`);
  if (JSON.stringify(local.bookmarks) !== JSON.stringify(other.bookmarks)) problems.push(`bookmarks differ: ${JSON.stringify(local.bookmarks)} vs ${JSON.stringify(other.bookmarks)}`);
  if (JSON.stringify(local.settings) !== JSON.stringify(other.settings)) problems.push(`settings differ: ${JSON.stringify(local.settings)} vs ${JSON.stringify(other.settings)}`);
  if (local.name !== other.name) problems.push(`profile names differ: ${local.name} vs ${other.name}`);
  const edits = [...local.edits, ...other.edits];
  for (const edit of edits.filter((e) => e.kind === "bookmark")) if (!local.bookmarks.includes(edit.key)) problems.push(`bookmark ${edit.key} was lost`);
  const allowed = (kind, key) => edits.filter((e) => e.kind === kind && e.key === key).map((e) => JSON.stringify(e.value));
  for (const key of Object.keys(local.settings)) {
    const values = allowed("setting", key);
    const kept = edits.filter((e) => e.kind === "setting" && e.key === key && !e.exempt);
    if (kept.length && !values.includes(JSON.stringify(local.settings[key]))) problems.push(`setting ${key} ended ${JSON.stringify(local.settings[key])}, which no one chose`);
  }
  const names = allowed("name", "default");
  if (edits.some((e) => e.kind === "name" && !e.exempt) && !names.includes(JSON.stringify(local.name)))
    problems.push(`the profile name ended ${local.name}, which no one chose (${JSON.stringify(edits.filter((e) => e.kind === "name"))})`);
  return problems;
}

export function oracleScript(seed, steps) {
  const rand = mulberry32(seed);
  const pick = (list) => list[Math.floor(rand() * list.length)];
  const script = { name: `oracle ${seed}`, oracle: true, steps: [] };
  const push = (mac, step) => script.steps.push({ mac, ...step });
  push("local", { op: "start" });
  push("other", { op: "start" });
  const [first, second] = rand() < 0.5 ? ["local", "other"] : ["other", "local"];
  push(first, { op: "turnOn", folder: "/sync" });
  push(first, { op: "syncNow" });
  push(second, { op: "join", folder: "/sync", phrase: "abandon ability" });
  push(second, { op: "syncNow" });
  let made = 0;
  for (let i = 0; i < steps; i++) {
    const mac = rand() < 0.55 ? "local" : "other";
    const r = rand();
    if (r < 0.22) push(mac, { op: pick(["syncNow", "fire", "fire"]) });
    else if (r < 0.36) push(mac, { op: "bookmark", profile: 0, url: `https://${mac[0]}${++made}.example/`, title: pick(["A", "B", "Ünï"]) });
    else if (r < 0.44) push(mac, { op: "settings", patch: pick([{ searchEngine: pick(["duckduckgo", "bing", "google"]) }, { tabLayout: pick(["topbar", "sidebar"]) }, { warnBeforeQuitting: rand() < 0.5 }, { appearance: pick(["dark", "light"]) }]) });
    else if (r < 0.49) push(mac, { op: "rename", profile: 0, name: pick(["Personal", "Home", "Mine"]) });
    else if (r < 0.53) push(mac, { op: "relaunch" }), push(mac, { op: "start" });
    else if (r < 0.56) push(mac, { op: "snapshot" });
    else if (r < 0.6) push(mac, { op: "crash", snapshot: rand() < 0.4 }), push(mac, { op: "start" });
    else if (r < 0.63) push(mac, { op: "damage", doc: pick(["sync-state.nns", "sync-journal.nns"]), how: pick(["drop", "corrupt", "foreign", "malformed"]) }), push(mac, { op: "relaunch" }), push(mac, { op: "start" });
    else if (r < 0.65) push(mac, { op: "damage", doc: "sync-state.nns", how: "newer" }), push(mac, { op: "relaunch" }), push(mac, { op: "start" });
    else if (r < 0.68) push(mac, { op: "holdNative", names: [pick(["read", "write", "chainStatus", "unlock", "sealLocal", "openLocal"])] });
    else if (r < 0.72) push(mac, { op: "releaseNative" });
    else if (r < 0.75) push(mac, { op: "hold", value: rand() < 0.5 });
    else if (r < 0.78) push(mac, { op: "land" });
    else if (r < 0.8) push(mac, { op: "failDocs", value: rand() < 0.4 });
    else if (r < 0.83) push(mac, { op: "mode", key: "chain", value: pick(["ok", "ok", "unavailable"]) });
    else if (r < 0.85) push(mac, { op: "mode", key: "unlock", value: rand() < 0.7 });
    else push(mac, { op: "advance", ms: pick([1000, 60_000, 3_600_000]) });
  }
  for (const mac of ["local", "other"]) {
    for (const step of [{ op: "mode", key: "chain", value: "ok" }, { op: "mode", key: "unlock", value: true }, { op: "failDocs", value: false }, { op: "hold", value: false }, { op: "releaseNative" }, { op: "land" }, { op: "recover" }])
      push(mac, step);
  }
  for (let round = 0; round < 4; round++) for (const mac of ["local", "other"]) push(mac, { op: "syncNow" }), push(mac, { op: "fire" });
  return script;
}

async function other() {
  let ids = 0;
  const waiting = new Map();
  let env = null;
  const folderOps = (op, a) =>
    new Promise((resolve) => {
      const id = ++ids;
      waiting.set(id, resolve);
      process.send({ folder: op, args: a, id });
    });
  process.on("message", async (message) => {
    if (message.reply !== undefined) {
      waiting.get(message.reply)?.(message.value);
      waiting.delete(message.reply);
      return;
    }
    if (message.ready) {
      env = await environment("o", folderOps);
      process.send({ done: message.id });
      return;
    }
    if (message.report) {
      process.send({ done: message.id, report: env.report() });
      return;
    }
    try {
      await env.step(message.step);
      process.send({ done: message.id });
    } catch (error) {
      process.send({ done: message.id, error: String(error?.message ?? error) });
    }
  });
}

if (role === "other") await other();
else if (role === "local") process.once("message", async ({ script }) => process.send({ trace: await runScenario(script) }));
else if (process.argv[1] === fileURLToPath(import.meta.url)) await parent();

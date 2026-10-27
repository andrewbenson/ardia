import assert from "node:assert/strict";
import { test } from "node:test";

const realSetTimeout = globalThis.setTimeout;
globalThis.setTimeout = () => 0;
globalThis.clearTimeout = () => {};
globalThis.__DEV__ = false;

const folder = new Map();
let ids = 0;
const fake = {
  locked: false,
  unlockGate: null,
  unlockResult: true,
  failWrite: null,
  readGate: null,
  forgetGate: null,
  phraseGate: null,
  passwordReads: 0,
  seals: 0,
};
const guard = () => {
  if (fake.locked) throw new Error("locked");
};
globalThis.acTestNativeModules = {
  ArdiaSync: {
    newDeviceId: () => `dev${++ids}`,
    deviceName: () => "Test Mac",
    createPhrase: async () => {
      if (fake.phraseGate) await fake.phraseGate;
      fake.locked = false;
      return true;
    },
    enterPhrase: async () => ((fake.locked = false), { ok: true }),
    createChain: async () => {},
    unlock: async () => {
      if (fake.unlockGate) await fake.unlockGate;
      if (fake.unlockResult) fake.locked = false;
      return fake.unlockResult;
    },
    forget: async () => {
      if (fake.forgetGate) await fake.forgetGate;
    },
    chainStatus: async () => (guard(), "ok"),
    write: async (_folder, scope, payload) => {
      guard();
      if (fake.failWrite?.(scope, JSON.parse(payload))) throw new Error("offline");
      const id = `f${++ids}`;
      folder.set(id, { scope, payload });
      return id;
    },
    read: async (_folder, scope, known) => {
      guard();
      const gate = fake.readGate?.(scope);
      if (gate) await gate;
      const here = [...folder].filter(([, f]) => f.scope === scope);
      return { files: here.filter(([id]) => !known.includes(id)).map(([id, f]) => ({ id, payload: f.payload })), pending: [], damaged: [], present: here.map(([id]) => id) };
    },
    remove: async (_folder, _scope, list) => list.forEach((id) => folder.delete(id)),
    deleteChain: async () => folder.clear(),
    sealLocal: async (text) => (fake.seals++, guard(), `sealed:${text}`),
    openLocal: async (sealed) => (guard(), sealed.startsWith("sealed:") ? sealed.slice(7) : null),
    readPasswords: async () => (fake.passwordReads++, []),
  },
};

const shell = await import("../test-native/index.ts");
const { useBrowser } = await import("../store/browser.ts");
const S = () => useBrowser.getState();
const settle = async (n = 30) => {
  for (let i = 0; i < n; i++) await new Promise((resolve) => setImmediate(resolve));
};
let launches = 0;
const launch = async () => import(`./engine.ts?safety${++launches}`);

function reset() {
  S().hydrate({});
  useBrowser.setState({ bookmarksReady: { default: true } });
  folder.clear();
  shell.docs.clear();
  shell.heldSaves.on = false;
  shell.heldSaves.fail = false;
  shell.heldSaves.only = null;
  shell.heldSaves.queue.length = 0;
  Object.assign(fake, { locked: false, unlockGate: null, unlockResult: true, failWrite: null, readGate: null, forgetGate: null, phraseGate: null, passwordReads: 0, seals: 0 });
}

const files = () => [...folder.values()].map((f) => ({ scope: f.scope, file: JSON.parse(f.payload), payload: f.payload }));

function assertNoSeqReused() {
  const seen = new Map();
  for (const { scope, file, payload } of files()) {
    if (file.kind !== "log") continue;
    const key = `${scope} ${file.device} ${file.seq}`;
    const ops = JSON.stringify(file.ops);
    assert.equal(seen.get(key) ?? ops, ops, `${key} was published twice with different changes`);
    seen.set(key, ops);
    void payload;
  }
}

async function onAndSynced() {
  const engine = await launch();
  engine.startSync();
  assert.ok("ok" in (await engine.turnOnSync("/sync")));
  S().addBookmark({ profileId: "default", url: "https://one.example/", title: "One" });
  await engine.syncNow();
  await settle();
  return engine;
}

test("B1: a locked Mac doesn't run cycles, stays locked, and the phrase unlocks the same device", async () => {
  reset();
  const first = await onAndSynced();
  const device = first.useSync.getState().devices.find((d) => d.current)?.id;
  fake.locked = true;
  fake.unlockResult = false;
  const engine = await launch();
  engine.startSync();
  await settle();
  assert.equal(engine.useSync.getState().status, "locked");
  S().addBookmark({ profileId: "default", url: "https://two.example/", title: "Two" });
  await engine.syncNow();
  await settle();
  assert.equal(engine.useSync.getState().status, "locked", "a cycle while locked doesn't turn it into stalled");
  assert.ok("ok" in (await engine.enterRecoveryPhrase("/sync", "words")));
  await engine.syncNow();
  await settle();
  const now = engine.useSync.getState().devices.find((d) => d.current)?.id;
  assert.equal(now, device, "the phrase unlocks this device, not a new one");
});

test("B2: a cycle that starts before the saved state is loaded doesn't reuse a seq", async () => {
  reset();
  const first = await onAndSynced();
  S().addBookmark({ profileId: "default", url: "https://two.example/", title: "Two" });
  await first.syncNow();
  await settle();
  let open;
  fake.unlockGate = new Promise((resolve) => (open = resolve));
  const engine = await launch();
  engine.startSync();
  S().addBookmark({ profileId: "default", url: "https://three.example/", title: "Three" });
  const early = engine.syncNow();
  await settle();
  open();
  await early;
  await settle();
  await engine.syncNow();
  await settle();
  assertNoSeqReused();
});

test("B3: a seal that keeps failing doesn't retry in a loop", async () => {
  reset();
  const engine = await onAndSynced();
  shell.heldSaves.fail = true;
  const before = fake.seals;
  S().addBookmark({ profileId: "default", url: "https://two.example/", title: "Two" });
  await engine.syncNow();
  await settle(200);
  assert.ok(fake.seals - before < 10, `sealed ${fake.seals - before} times`);
  shell.heldSaves.fail = false;
});

test("B4: a save before the state is loaded keeps the seqs and the sealed state", async () => {
  reset();
  await onAndSynced();
  const json = JSON.parse(shell.docs.get("sync.json"));
  const state = shell.docs.get("sync-state.nns");
  let open;
  fake.unlockGate = new Promise((resolve) => (open = resolve));
  const engine = await launch();
  engine.startSync();
  engine.setTypeSynced("history", false);
  await settle();
  assert.deepEqual(JSON.parse(shell.docs.get("sync.json")).seqs, json.seqs, "sync.json keeps its seqs");
  open();
  await settle(5);
  assert.equal(shell.docs.get("sync-state.nns"), state, "the sealed state isn't replaced before it is read");
  await settle();
});

test("B5: a deleted profile's scope is gone for good, and syncing that profile again doesn't reuse its seqs", async () => {
  reset();
  const engine = await launch();
  engine.startSync();
  const work = S().createProfile({ name: "Work" });
  useBrowser.setState({ bookmarksReady: { ...S().bookmarksReady, [work]: true } });
  assert.ok("ok" in (await engine.turnOnSync("/sync")));
  await engine.syncNow();
  S().addBookmark({ profileId: work, url: "https://work.example/", title: "Work" });
  await engine.syncNow();
  await settle();
  const syncId = engine.useSync.getState().profiles[work].syncId;
  S().deleteProfile(work);
  await engine.syncNow();
  await engine.syncNow();
  await settle();
  const journal = shell.docs.get("sync-journal.nns");
  assert.ok(!journal || !JSON.parse(journal.slice(7)).journal?.[`p:${syncId}`], "the journal has nothing left for the deleted scope");
  const again = await launch();
  again.startSync();
  await settle();
  assert.equal(again.appScopeRecords()[`prof:${syncId}`]?.v === undefined, false, "the remote profile record is still there to add back");
  const id = again.addRemoteProfile(syncId);
  if (id) {
    useBrowser.setState({ bookmarksReady: { ...S().bookmarksReady, [id]: true } });
    S().addBookmark({ profileId: id, url: "https://back.example/", title: "Back" });
    await again.syncNow();
    await again.syncNow();
    await settle();
  }
  assertNoSeqReused();
});

test("B7: Sync Now during a cycle still forces the next password read", async () => {
  reset();
  const engine = await onAndSynced();
  const timers = [];
  globalThis.setTimeout = (fn, delay) => (timers.push({ fn, delay }), timers.length);
  await engine.syncNow();
  await settle();
  let release;
  const gate = new Promise((resolve) => (release = resolve));
  fake.readGate = (scope) => (scope.startsWith("p:") ? gate : null);
  const first = engine.syncNow();
  await settle();
  void engine.syncNow();
  fake.readGate = null;
  release();
  await first;
  await settle();
  const reads = fake.passwordReads;
  const next = timers.filter((t) => t.delay === 0).pop();
  timers.length = 0;
  next?.fn();
  await settle();
  globalThis.setTimeout = () => 0;
  assert.ok(next, "the Sync Now that arrived mid-cycle asked for another cycle");
  assert.ok(fake.passwordReads > reads, "and that cycle read the passwords");
});

test("B8: a cycle that fails after pulling keeps the clock it saw, so a later edit isn't dropped", async () => {
  reset();
  const engine = await onAndSynced();
  const future = (Date.now() + 86_400_000).toString(36).padStart(9, "0");
  folder.set("remote1", {
    scope: "app",
    payload: JSON.stringify({ v: 1, kind: "log", device: "far", seq: 1, at: Date.now(), ops: [{ k: "set:searchEngine", h: `${future}.0000.far`, v: { v: "bing" } }] }),
  });
  S().addBookmark({ profileId: "default", url: "https://two.example/", title: "Two" });
  fake.failWrite = (scope) => scope.startsWith("p:");
  await engine.syncNow();
  await settle();
  fake.failWrite = null;
  assert.equal(S().settings.searchEngine, "bing");
  S().updateSettings({ searchEngine: "duckduckgo" });
  await engine.syncNow();
  await engine.syncNow();
  await settle();
  const published = files().filter(({ scope }) => scope === "app").flatMap(({ file }) => file.ops ?? []).filter((op) => op.k === "set:searchEngine" && op.v?.v === "duckduckgo");
  assert.equal(published.length, 1, "the later choice is published");
});

test("B9: stopping while the state is being sealed leaves no sealed state behind", async () => {
  reset();
  const engine = await onAndSynced();
  shell.heldSaves.on = true;
  shell.heldSaves.only = "sync-state.nns";
  S().addBookmark({ profileId: "default", url: "https://two.example/", title: "Two" });
  await engine.syncNow();
  await settle();
  assert.ok(shell.heldSaves.queue.length > 0, "the sealed state's save is in flight");
  await engine.stopSync();
  await settle();
  shell.heldSaves.on = false;
  for (const land of shell.heldSaves.queue.splice(0)) land();
  await settle();
  assert.equal(shell.docs.get("sync-state.nns") ?? "", "", "nothing sealed outlives the stop");
});

test("B6: Sync Now while sync is being turned off doesn't publish this Mac again", async () => {
  reset();
  const engine = await onAndSynced();
  let release;
  fake.forgetGate = new Promise((resolve) => (release = resolve));
  const stopping = engine.stopSync();
  await settle();
  await engine.syncNow();
  await settle();
  release();
  await stopping;
  await settle();
  const ops = files().filter(({ scope }) => scope === "app").flatMap(({ file }) => file.ops ?? []).filter((op) => op.k === "dev:dev1");
  assert.equal(ops.at(-1)?.v ?? null, null, "the last word on this Mac is that it left");
});

test("B10: turning sync on twice at once makes one device", async () => {
  reset();
  const engine = await launch();
  engine.startSync();
  let release;
  fake.phraseGate = new Promise((resolve) => (release = resolve));
  const a = engine.turnOnSync("/sync");
  const b = engine.turnOnSync("/sync");
  await settle();
  release();
  await a;
  await b;
  await engine.syncNow();
  await settle();
  const devices = new Set(files().map(({ file }) => file.device));
  assert.equal(devices.size, 1, `devices: ${[...devices]}`);
});

test("B10b: turning on or joining while sync is on keeps the device, and a cycle in flight never writes after its journal is cleared", async () => {
  reset();
  const engine = await onAndSynced();
  shell.heldSaves.on = true;
  S().addBookmark({ profileId: "default", url: "https://two.example/", title: "Two" });
  const cycle = engine.syncNow();
  await settle();
  assert.ok("error" in (await engine.turnOnSync("/sync")), "turning on again is refused");
  assert.ok("error" in (await engine.enterRecoveryPhrase("/sync", "words")), "so is joining");
  shell.heldSaves.on = false;
  for (const land of shell.heldSaves.queue.splice(0)) land();
  await cycle;
  await settle();
  assert.equal(new Set(files().map(({ file }) => file.device)).size, 1);
});

test("B11: a saved state that parses but isn't scopes doesn't stop sync from starting", async () => {
  reset();
  await onAndSynced();
  shell.docs.set("sync-state.nns", 'sealed:{"journal":{"app":[{"v":1}]},"app":7}');
  const engine = await launch();
  engine.startSync();
  await settle();
  await engine.syncNow();
  await settle();
  assert.equal(engine.useSync.getState().status, "updated");
  assertNoSeqReused();
});

test("B12: a journal entry from another device or without changes doesn't keep this device's batch out of the journal", async () => {
  reset();
  await onAndSynced();
  const synced = JSON.parse(shell.docs.get("sync.json"));
  shell.docs.set("sync-journal.nns", `sealed:${JSON.stringify({ journal: { app: [{ v: 1, kind: "log", device: "someone", seq: synced.seqs.app + 1, ops: [] }, { v: 1, kind: "log", device: synced.deviceId, seq: 99 }] } })}`);
  const engine = await launch();
  engine.startSync();
  await settle();
  let journaled = null;
  fake.failWrite = (scope, file) => {
    if (scope !== "app" || file.kind !== "log") return false;
    const list = JSON.parse(shell.docs.get("sync-journal.nns").slice(7)).journal?.app ?? [];
    journaled = list.some((f) => f.device === file.device && f.seq === file.seq && f.ops?.length);
    return false;
  };
  S().updateSettings({ searchEngine: "duckduckgo" });
  await engine.syncNow();
  await settle();
  assert.equal(journaled, true, "the batch is in the journal before it goes out");
});

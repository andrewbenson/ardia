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
    enterPhrase: async () => {
      if (fake.phraseGate) await fake.phraseGate;
      fake.locked = false;
      return { ok: true };
    },
    createChain: async () => {},
    unlock: async () => {
      if (fake.unlockGate) await fake.unlockGate;
      if (fake.unlockResult) fake.locked = false;
      return fake.unlockResult;
    },
    forget: async () => {
      if (fake.forgetGate) await fake.forgetGate;
    },
    chainStatus: async () => (guard(), fake.chain ?? "ok"),
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
    openLocal: async (sealed) => {
      guard();
      if (fake.openFails) throw new Error("couldn't open");
      return sealed.startsWith("sealed:") ? sealed.slice(7) : null;
    },
    readPasswords: async () => (fake.passwordReads++, []),
  },
};

const shell = await import("../test-native/index.ts");
const sync = await import("@ardia/sync");
const { useBrowser } = await import("../store/browser.ts");
const S = () => useBrowser.getState();
const emptyBookmarks = S().bookmarks;
const settle = async (n = 30) => {
  for (let i = 0; i < n; i++) await new Promise((resolve) => setImmediate(resolve));
};
let launches = 0;
const launch = async () => import(`./engine.ts?rev${++launches}`);

function reset() {
  S().hydrate({});
  useBrowser.setState({ bookmarks: emptyBookmarks, bookmarksReady: { default: true } });
  folder.clear();
  shell.docs.clear();
  shell.heldSaves.on = false;
  shell.heldSaves.fail = false;
  shell.heldSaves.only = null;
  shell.heldSaves.queue.length = 0;
  Object.assign(fake, { locked: false, unlockGate: null, unlockResult: true, failWrite: null, readGate: null, forgetGate: null, phraseGate: null, openFails: false, chain: "ok", passwordReads: 0, seals: 0 });
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

const rawTransport = {
  write: async (scope, payload) => {
    const id = `f${++ids}`;
    folder.set(id, { scope, payload });
    return id;
  },
  read: async (scope, known) => {
    const here = [...folder].filter(([, f]) => f.scope === scope);
    return { files: here.filter(([id]) => !known.includes(id)).map(([id, f]) => ({ id, payload: f.payload })), pending: [], damaged: [], present: here.map(([id]) => id) };
  },
  remove: async (_scope, list) => list.forEach((id) => folder.delete(id)),
};

function otherMac(scope) {
  const store = new Map();
  const state = sync.emptyScope();
  state.joined = true;
  const clock = new sync.Clock("otherMac");
  const adapter = {
    prefix: "bm:",
    extract: () => ({ values: new Map(store) }),
    apply: (visible, changed) => {
      for (const k of changed) visible.has(k) ? store.set(k, visible.get(k)) : store.delete(k);
    },
  };
  return { store, sync: () => sync.syncScope({ scope, state, transport: rawTransport, adapters: [adapter], clock, device: "otherMac" }) };
}

test("B25: a crash after a mid-cycle seal leaves sync.json's clock behind the sealed records, and a later local edit is dropped", async () => {
  reset();
  const first = await onAndSynced();
  const future = (Date.now() + 120_000).toString(36).padStart(9, "0");
  folder.set("remote1", {
    scope: "app",
    payload: JSON.stringify({ v: 1, kind: "log", device: "far", seq: 1, at: Date.now(), ops: [{ k: "set:searchEngine", h: `${future}.0000.far`, v: { v: "bing" } }] }),
  });
  let release;
  const held = new Promise((resolve) => (release = resolve));
  fake.readGate = (scope) => (scope.startsWith("p:") ? held : null);
  void first.syncNow();
  await settle();
  assert.equal(S().settings.searchEngine, "bing", "the app scope pulled and applied the remote choice");
  first.setTypeSynced("history", true);
  await settle();
  const sealed = JSON.parse(shell.docs.get("sync-state.nns").slice(7));
  assert.ok(sealed.app.records["set:searchEngine"].h.startsWith(future), "the sealed state holds the future-stamped record");
  assert.ok((JSON.parse(shell.docs.get("sync.json")).clock ?? "") < `${future}`, "while sync.json's clock is behind it");
  fake.readGate = null;
  const again = await launch();
  again.startSync();
  await settle();
  S().updateSettings({ searchEngine: "duckduckgo" });
  S().addBookmark({ profileId: "default", url: "https://control.example/", title: "Control" });
  await again.syncNow();
  await again.syncNow();
  await again.syncNow();
  await settle();
  const published = files().filter(({ scope }) => scope === "app").flatMap(({ file }) => file.ops ?? []).filter((op) => op.k === "set:searchEngine" && op.v?.v === "duckduckgo");
  assert.equal(again.useSync.getState().status, "updated", "control: the relaunched engine syncs");
  assert.ok(files().some(({ file }) => (file.ops ?? []).some((op) => op.v?.t === "Control")), "control: a bookmark made after the relaunch is published");
  assert.equal(S().settings.searchEngine, "duckduckgo", "the local choice stands on this Mac");
  const remote = files().filter(({ scope }) => scope === "app").flatMap(({ file }) => file.ops ?? []).filter((op) => op.k === "set:searchEngine").map((op) => op.v?.v);
  assert.equal(published.length, 1, `the edit made after the relaunch is published; this Mac shows duckduckgo, the folder only ever has ${remote}`);
  void release;
});

test("B25b: same, with no user action: the previous cycle's seal lands during the next cycle and re-seals mid-cycle", async () => {
  reset();
  const first = await onAndSynced();
  shell.heldSaves.on = true;
  shell.heldSaves.only = "sync-state.nns";
  S().addBookmark({ profileId: "default", url: "https://two.example/", title: "Two" });
  await first.syncNow();
  await settle();
  assert.ok(shell.heldSaves.queue.length > 0, "the end-of-cycle seal is in flight");
  const future = (Date.now() + 120_000).toString(36).padStart(9, "0");
  folder.set("remote1", {
    scope: "app",
    payload: JSON.stringify({ v: 1, kind: "log", device: "far", seq: 1, at: Date.now(), ops: [{ k: "set:searchEngine", h: `${future}.0000.far`, v: { v: "bing" } }] }),
  });
  const held = new Promise(() => {});
  fake.readGate = (scope) => (scope.startsWith("p:") ? held : null);
  void first.syncNow();
  await settle();
  shell.heldSaves.on = false;
  for (const land of shell.heldSaves.queue.splice(0)) land();
  await settle();
  const sealed = JSON.parse(shell.docs.get("sync-state.nns").slice(7));
  assert.ok(sealed.app.records["set:searchEngine"]?.h.startsWith(future), "the re-seal captured the mid-cycle record");
  fake.readGate = null;
  const again = await launch();
  again.startSync();
  await settle();
  S().updateSettings({ searchEngine: "duckduckgo" });
  S().addBookmark({ profileId: "default", url: "https://control.example/", title: "Control" });
  await again.syncNow();
  await again.syncNow();
  await again.syncNow();
  await settle();
  const published = files().filter(({ scope }) => scope === "app").flatMap(({ file }) => file.ops ?? []).filter((op) => op.k === "set:searchEngine" && op.v?.v === "duckduckgo");
  assert.equal(again.useSync.getState().status, "updated", "control: the relaunched engine syncs");
  assert.ok(files().some(({ file }) => (file.ops ?? []).some((op) => op.v?.t === "Control")), "control: a bookmark made after the relaunch is published");
  assert.equal(S().settings.searchEngine, "duckduckgo", "the local choice stands on this Mac");
  const remote = files().filter(({ scope }) => scope === "app").flatMap(({ file }) => file.ops ?? []).filter((op) => op.k === "set:searchEngine").map((op) => op.v?.v);
  assert.equal(published.length, 1, `the edit made after the relaunch is published; this Mac shows duckduckgo, the folder only ever has ${remote}`);
});

async function rebuildClobbers(corrupt) {
  reset();
  const engine = await onAndSynced();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const other = otherMac(`p:${syncId}`);
  await other.sync();
  const [key, value] = [...other.store].find(([, v]) => v.t === "One");
  other.store.set(key, { ...value, t: "Renamed on B" });
  await other.sync();
  await engine.syncNow();
  await settle();
  const here = () => Object.values(S().bookmarks.nodes).filter((n) => n.kind === "url").map((n) => n.title);
  assert.ok(here().includes("Renamed on B"), "control: with a readable state this Mac takes B's rename");
  other.store.set(key, { ...value, t: "Renamed again on B" });
  await other.sync();
  corrupt();
  const again = await launch();
  again.startSync();
  await settle();
  await again.syncNow();
  await again.syncNow();
  await settle();
  await other.sync();
  assert.equal(again.useSync.getState().status, "updated");
  assert.equal(other.store.get(key)?.t, "Renamed again on B", `B's newer rename survives this Mac's rebuild (B now has ${other.store.get(key)?.t}, this Mac ${here()})`);
}

test("B26: a sealed state that won't open (openLocal returns null, as native does on any decrypt failure) is rebuilt by republishing stale local values over newer remote edits", () =>
  rebuildClobbers(() => shell.docs.set("sync-state.nns", "not-sealed-by-this-key")));

test("B26b: same for a state B22 rejects", () =>
  rebuildClobbers(() => {
    const state = JSON.parse(shell.docs.get("sync-state.nns").slice(7));
    for (const scope of Object.values(state)) scope.records["junk"] = null;
    shell.docs.set("sync-state.nns", `sealed:${JSON.stringify(state)}`);
  }));

test("B27: a mid-cycle seal prunes a batch that sync.json doesn't count yet; if that sealed state is later unreadable, the rebuild reuses the batch's seq", async () => {
  reset();
  await onAndSynced();
  const engine = await launch();
  engine.startSync();
  await settle();
  await engine.syncNow();
  await settle();
  const before = JSON.parse(shell.docs.get("sync.json")).seqs.app;
  shell.heldSaves.on = true;
  shell.heldSaves.only = "sync-journal.nns";
  fake.readGate = (scope) => (scope === "app" ? new Promise(() => {}) : null);
  S().updateSettings({ searchEngine: "bing" });
  void engine.syncNow();
  await settle();
  assert.equal(shell.heldSaves.queue.length, 1, "batch N's journal save is in flight");
  engine.setTypeSynced("history", true);
  await settle();
  assert.equal(shell.docs.get("sync-journal.nns"), "", "the mid-cycle seal landed and cleared the journal");
  assert.equal(JSON.parse(shell.docs.get("sync.json")).seqs.app, before, "sync.json still counts N as unwritten");
  shell.heldSaves.on = false;
  const land = shell.heldSaves.queue.shift();
  land();
  shell.docs.set("sync-journal.nns", "");
  await settle();
  assert.ok(files().some(({ scope, file }) => scope === "app" && file.seq === before + 1), "batch N is in the folder");
  fake.readGate = null;
  shell.docs.set("sync-state.nns", "unreadable");
  const again = await launch();
  again.startSync();
  await settle();
  S().updateSettings({ searchEngine: "duckduckgo" });
  await again.syncNow();
  await settle();
  assertNoSeqReused();
});

test("B27-control: without the mid-cycle seal prunes a batch that sync.json doesn't count yet; if that sealed state is later unreadable, the rebuild reuses the batch's seq", async () => {
  reset();
  await onAndSynced();
  const engine = await launch();
  engine.startSync();
  await settle();
  await engine.syncNow();
  await settle();
  const before = JSON.parse(shell.docs.get("sync.json")).seqs.app;
  shell.heldSaves.on = true;
  shell.heldSaves.only = "sync-journal.nns";
  fake.readGate = (scope) => (scope === "app" ? new Promise(() => {}) : null);
  S().updateSettings({ searchEngine: "bing" });
  void engine.syncNow();
  await settle();
  assert.equal(shell.heldSaves.queue.length, 1, "batch N's journal save is in flight");
  assert.equal(JSON.parse(shell.docs.get("sync.json")).seqs.app, before, "sync.json still counts N as unwritten");
  shell.heldSaves.on = false;
  const land = shell.heldSaves.queue.shift();
  land();
  await settle();
  assert.ok(files().some(({ scope, file }) => scope === "app" && file.seq === before + 1), "batch N is in the folder");
  fake.readGate = null;
  shell.docs.set("sync-state.nns", "unreadable");
  const again = await launch();
  again.startSync();
  await settle();
  S().updateSettings({ searchEngine: "duckduckgo" });
  await again.syncNow();
  await settle();
  assertNoSeqReused();
});

async function stuckAfter(damage) {
  reset();
  await onAndSynced();
  const state = JSON.parse(shell.docs.get("sync-state.nns").slice(7));
  damage(state.app);
  shell.docs.set("sync-state.nns", `sealed:${JSON.stringify(state)}`);
  const engine = await launch();
  engine.startSync();
  await settle();
  for (let i = 0; i < 3; i++) {
    S().updateSettings({ searchEngine: i % 2 ? "bing" : "duckduckgo" });
    await engine.syncNow();
    await settle();
  }
  assert.equal(engine.useSync.getState().status, "updated", `status ${engine.useSync.getState().status}: ${engine.useSync.getState().error}`);
}

test("B28: an unapplied entry that isn't a string passes readableScope and stalls every cycle", () => stuckAfter((app) => (app.unapplied = [null])));
test("B28b: an extra entry for this device that isn't an array stalls every cycle that writes", () =>
  stuckAfter((app) => (app.extra = { [JSON.parse(shell.docs.get("sync.json")).deviceId]: 5 })));

test("B30: a Mac's first cycle after turning sync on publishes its profiles, so a Mac that joins right after can pair with them", async () => {
  reset();
  const engine = await launch();
  engine.startSync();
  assert.ok("ok" in (await engine.turnOnSync("/sync")));
  await engine.syncNow();
  await settle();
  const ops = files().filter(({ scope }) => scope === "app").flatMap(({ file }) => file.ops ?? []);
  assert.ok(ops.some((op) => op.k.startsWith("prof:") && op.v?.d), "the default profile's record is out after one cycle");
});

test("B31: a sync state rolled back to an older copy (a restored backup) doesn't reuse the seqs it had already published", async () => {
  reset();
  const engine = await onAndSynced();
  const older = new Map(shell.docs);
  for (const title of ["Two", "Three"]) {
    S().addBookmark({ profileId: "default", url: `https://${title}.example/`, title });
    await engine.syncNow();
  }
  await settle();
  shell.docs.clear();
  for (const [name, contents] of older) shell.docs.set(name, contents);
  const again = await launch();
  again.startSync();
  await settle();
  S().addBookmark({ profileId: "default", url: "https://four.example/", title: "Four" });
  await again.syncNow();
  await again.syncNow();
  await settle();
  assertNoSeqReused();
});

test("B32: an edit made while a lost state is being rebuilt is published, not replaced by the remote value", async () => {
  reset();
  const engine = await onAndSynced();
  void engine;
  shell.docs.set("sync-state.nns", "not-sealed-by-this-key");
  const again = await launch();
  again.startSync();
  await settle();
  S().updateProfile("default", { name: "Renamed while rebuilding" });
  await again.syncNow();
  await again.syncNow();
  await settle();
  const names = files().filter(({ scope }) => scope === "app").flatMap(({ file }) => file.ops ?? []).filter((op) => op.k.startsWith("prof:")).map((op) => op.v?.n);
  assert.equal(names.at(-1), "Renamed while rebuilding");
  assert.equal(S().profiles.default.name, "Renamed while rebuilding");
});

async function retiredAndReadded() {
  const engine = await launch();
  engine.startSync();
  const work = S().createProfile({ name: "Work" });
  useBrowser.setState({ bookmarksReady: { ...S().bookmarksReady, [work]: true } });
  assert.ok("ok" in (await engine.turnOnSync("/sync")));
  await engine.syncNow();
  for (let i = 0; i < 3; i++) {
    S().addBookmark({ profileId: work, url: `https://w${i}.example/`, title: `W${i}` });
    await engine.syncNow();
  }
  await settle();
  const syncId = engine.useSync.getState().profiles[work].syncId;
  const scope = `p:${syncId}`;
  S().deleteProfile(work);
  await engine.syncNow();
  await engine.syncNow();
  await settle();
  const saved = JSON.parse(shell.docs.get("sync.json"));
  const again = S().createProfile({ name: "Work" });
  useBrowser.setState({ bookmarksReady: { ...S().bookmarksReady, [again]: true } });
  const older = { v: 1, kind: "log", device: saved.deviceId, seq: 1, at: Date.now(), ops: [{ k: "bm:older", h: "0zzzzzzzz.0000.older", v: { k: "u", p: "bar", t: "Older", u: "https://older.example/", a: 1, pos: "m" } }] };
  shell.docs.set("sync.json", JSON.stringify({ ...saved, profiles: { ...saved.profiles, [again]: { syncId, enabled: true } }, seqs: { ...saved.seqs, [scope]: 0 } }));
  shell.docs.set("sync-journal.nns", `sealed:${JSON.stringify({ journal: { [scope]: [older] } })}`);
  return { scope, floor: saved.retired[scope], deviceId: saved.deviceId };
}

const olderOut = (scope) => files().filter((f) => f.scope === scope && f.file.kind === "log" && f.file.ops.some((op) => op.k === "bm:older" && op.h === "0zzzzzzzz.0000.older"));

test("B33: a relaunch before the revived scope's batches go out keeps them, even if the journal can't be saved meanwhile", async () => {
  reset();
  const { scope, floor } = await retiredAndReadded();
  shell.heldSaves.fail = true;
  const first = await launch();
  first.startSync();
  await settle();
  first.setTypeSynced("history", true);
  await settle();
  shell.heldSaves.fail = false;
  const second = await launch();
  second.startSync();
  await settle();
  await second.syncNow();
  await second.syncNow();
  await settle();
  const out = olderOut(scope);
  assert.ok(out.length && out.every((f) => f.file.seq > floor), "the older build's batch still goes out above the floor");
  assertNoSeqReused();
});

test("B34: a revived scope's resent batches never take a seq an older build already wrote to the folder", async () => {
  reset();
  const { scope, floor, deviceId } = await retiredAndReadded();
  folder.set("older-slot", { scope, payload: JSON.stringify({ v: 1, kind: "log", device: deviceId, seq: floor + 1, at: Date.now(), ops: [{ k: "bm:slot", h: "0zzzzzzzz.0001.older", v: { k: "u", p: "bar", t: "Slot", u: "https://slot.example/", a: 1, pos: "n" } }] }) });
  const next = await launch();
  next.startSync();
  await settle();
  await next.syncNow();
  await next.syncNow();
  await settle();
  assert.ok(olderOut(scope).length, "the older batch goes out");
  assertNoSeqReused();
});

test("B35: a sync.json from a newer format is left alone instead of being rebuilt over", async () => {
  reset();
  await onAndSynced();
  const newer = { ...JSON.parse(shell.docs.get("sync.json")), v: 2, future: true };
  shell.docs.set("sync.json", JSON.stringify(newer));
  const writes = folder.size;
  const engine = await launch();
  engine.startSync();
  await settle();
  engine.setTypeSynced("history", false);
  await engine.syncNow();
  await settle();
  assert.equal(engine.useSync.getState().status, "unavailable");
  assert.deepEqual(JSON.parse(shell.docs.get("sync.json")), newer, "sync.json is untouched");
  assert.equal(folder.size, writes, "nothing is published");
  assert.ok("error" in (await engine.turnOnSync("/sync")));
});

const native = globalThis.acTestNativeModules.ArdiaSync;

test("B36: a rebuild whose baseline is taken before bookmarks are ready republishes every stale bookmark over newer remote edits", async () => {
  reset();
  const engine = await onAndSynced();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const other = otherMac(`p:${syncId}`);
  await other.sync();
  const [key, value] = [...other.store].find(([, v]) => v.t === "One");
  other.store.set(key, { ...value, t: "Renamed on B" });
  await other.sync();
  await engine.syncNow();
  await settle();
  other.store.set(key, { ...value, t: "Renamed again on B" });
  await other.sync();
  shell.docs.set("sync-state.nns", "not-sealed-by-this-key");
  useBrowser.setState({ bookmarksReady: {} });
  const again = await launch();
  again.startSync();
  await settle();
  useBrowser.setState({ bookmarksReady: { default: true } });
  await again.syncNow();
  await again.syncNow();
  await settle();
  await other.sync();
  assert.equal(again.useSync.getState().status, "updated");
  assert.equal(other.store.get(key)?.t, "Renamed again on B", `B's newer rename survives (B now has ${other.store.get(key)?.t})`);
});

test("B36-control: same with bookmarks ready at load", async () => {
  reset();
  const engine = await onAndSynced();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const other = otherMac(`p:${syncId}`);
  await other.sync();
  const [key, value] = [...other.store].find(([, v]) => v.t === "One");
  other.store.set(key, { ...value, t: "Renamed on B" });
  await other.sync();
  await engine.syncNow();
  await settle();
  other.store.set(key, { ...value, t: "Renamed again on B" });
  await other.sync();
  shell.docs.set("sync-state.nns", "not-sealed-by-this-key");
  const again = await launch();
  again.startSync();
  await settle();
  await again.syncNow();
  await again.syncNow();
  await settle();
  await other.sync();
  assert.equal(other.store.get(key)?.t, "Renamed again on B");
});

const realReadPasswords = native.readPasswords;

test("B37: a rebuild that ends while bookmarks couldn't be applied republishes stale local bookmarks on the next cycle", async () => {
  reset();
  const engine = await onAndSynced();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const other = otherMac(`p:${syncId}`);
  await other.sync();
  const [key, value] = [...other.store].find(([, v]) => v.t === "One");
  other.store.set(key, { ...value, t: "Renamed on B" });
  await other.sync();
  shell.docs.set("sync-state.nns", "not-sealed-by-this-key");
  const again = await launch();
  again.startSync();
  await settle();
  useBrowser.setState({ bookmarksReady: {} });
  await again.syncNow();
  await settle();
  useBrowser.setState({ bookmarksReady: { default: true } });
  await again.syncNow();
  await again.syncNow();
  await settle();
  await other.sync();
  assert.equal(other.store.get(key)?.t, "Renamed on B", `B's rename survives (B now has ${other.store.get(key)?.t})`);
});

function passwordMac(scope) {
  const store = new Map();
  const state = sync.emptyScope();
  state.joined = true;
  const clock = new sync.Clock("pwMac");
  const adapter = {
    prefix: "pw:",
    extract: () => ({ values: new Map(store) }),
    apply: (visible, changed) => {
      for (const k of changed) visible.has(k) ? store.set(k, visible.get(k)) : store.delete(k);
    },
  };
  return { store, sync: () => sync.syncScope({ scope, state, transport: rawTransport, adapters: [adapter], clock, device: "pwMac" }) };
}

test("B38: a rebuilt passwords scope keeps the stale local password, then republishes it over B's newer one", async () => {
  reset();
  const here = new Map([["https://site.example\nme", { origin: "https://site.example/", url: "https://site.example/", username: "me", password: "old", created: 1 }]]);
  shell.passwordStores.set(null, here);
  native.readPasswords = async () => [...here.values()];
  const realST = globalThis.setTimeout;
  globalThis.setTimeout = (fn, ms) => (ms === 250 ? realSetTimeout(fn, 0) : 0);
  try {
    const engine = await onAndSynced();
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    const key = "pw:https://site.example\nme";
    assert.equal(b.store.get(key)?.p, "old", "control: B has this Mac's password");
    b.store.set(key, { ...b.store.get(key), p: "new-from-B" });
    await b.sync();
    shell.docs.set("sync-state.nns", "not-sealed-by-this-key");
    const again = await launch();
    again.startSync();
    await settle();
    for (let i = 0; i < 3; i++) {
      await again.syncNow();
      await settle(60);
    }
    const realNow = Date.now;
    Date.now = () => realNow() + 60_000;
    try {
      await again.syncNow();
      await settle(60);
    } finally {
      Date.now = realNow;
    }
    await b.sync();
    assert.equal(b.store.get(key)?.p, "new-from-B", `B's newer password survives this Mac's rebuild (B has ${b.store.get(key)?.p}, this Mac ${here.get("https://site.example\nme")?.password})`);
  } finally {
    globalThis.setTimeout = realST;
    native.readPasswords = realReadPasswords;
  }
});

test("B39: an adapter that throws while the rebuild baseline is taken locks a healthy, unlocked Mac", async () => {
  reset();
  await onAndSynced();
  shell.docs.set("sync-state.nns", "not-sealed-by-this-key");
  native.readPasswords = async () => {
    throw new Error("password store not ready");
  };
  try {
    const again = await launch();
    again.startSync();
    await settle();
    assert.notEqual(again.useSync.getState().status, "locked", `status ${again.useSync.getState().status}: ${again.useSync.getState().error}`);
  } finally {
    native.readPasswords = realReadPasswords;
  }
});

const realRead = native.read;
const realNow = Date.now;

test("B40: a rebuilt scope with one file that never downloads never finishes the rebuild, so local deletions are never published", async () => {
  reset();
  const engine = await onAndSynced();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  native.read = async (...args) => {
    const listing = await realRead(...args);
    return args[1] === `p:${syncId}` ? { ...listing, pending: ["stuck"], present: [...listing.present, "stuck"] } : listing;
  };
  try {
    shell.docs.set("sync-state.nns", "not-sealed-by-this-key");
    const again = await launch();
    again.startSync();
    await settle();
    S().addBookmark({ profileId: "default", url: "https://early.example/", title: "Early" });
    await again.syncNow();
    await again.syncNow();
    await settle();
    const early = files().filter(({ scope }) => scope === `p:${syncId}`).flatMap(({ file }) => file.ops ?? []);
    const skew = 25 * 3_600_000;
    Date.now = () => realNow() + skew;
    S().addBookmark({ profileId: "default", url: "https://control.example/", title: "Control" });
    const one = Object.values(S().bookmarks.nodes).find((n) => n.kind === "url" && n.title === "One");
    S().removeBookmark(one.id);
    assert.ok(!Object.values(S().bookmarks.nodes).some((n) => n.kind === "url" && n.title === "One"), "control: One is gone here");
    for (let i = 0; i < 3; i++) await again.syncNow();
    await settle();
    const ops = files().filter(({ scope }) => scope === `p:${syncId}`).flatMap(({ file }) => file.ops ?? []);
    assert.ok(ops.some((op) => op.v?.t === "Control"), "control: an added bookmark is published after the 24 h give-up");
    const oneKey = ops.find((op) => op.v?.t === "One")?.k;
    assert.ok(ops.some((op) => op.k === oneKey && op.v === null), "the deletion of One is published");
  } finally {
    native.read = realRead;
    Date.now = realNow;
  }
});

test("B41: a rolled-back (but readable) sync state republishes values this Mac took from B since the backup, over B's newer edit", async () => {
  reset();
  const engine = await onAndSynced();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const other = otherMac(`p:${syncId}`);
  await other.sync();
  const older = new Map(shell.docs);
  const [key, value] = [...other.store].find(([, v]) => v.t === "One");
  other.store.set(key, { ...value, t: "Renamed on B" });
  await other.sync();
  await engine.syncNow();
  await settle();
  const here = () => Object.values(S().bookmarks.nodes).filter((n) => n.kind === "url").map((n) => n.title);
  assert.ok(here().includes("Renamed on B"), "control: this Mac took B's first rename");
  other.store.set(key, { ...value, t: "Renamed again on B" });
  await other.sync();
  shell.docs.clear();
  for (const [name, contents] of older) shell.docs.set(name, contents);
  const again = await launch();
  again.startSync();
  await settle();
  await again.syncNow();
  await again.syncNow();
  await settle();
  await other.sync();
  assertNoSeqReused();
  assert.equal(again.useSync.getState().status, "updated");
  assert.equal(other.store.get(key)?.t, "Renamed again on B", `B's newer rename survives this Mac's rollback (B now has ${other.store.get(key)?.t}, this Mac ${here()})`);
});

test("B42: a rolled-back state sealed mid-publish (outbox not empty) writes its outbox before the pull raises the seq", async () => {
  reset();
  const engine = await onAndSynced();
  const older = new Map(shell.docs);
  for (const title of ["Two", "Three"]) {
    S().addBookmark({ profileId: "default", url: `https://${title}.example/`, title });
    await engine.syncNow();
  }
  S().updateSettings({ searchEngine: "bing" });
  await engine.syncNow();
  await settle();
  const state = JSON.parse(older.get("sync-state.nns").slice(7));
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const scope = state[`p:${syncId}`];
  const dev = JSON.parse(older.get("sync.json")).deviceId;
  const h = `${Date.now().toString(36).padStart(9, "0")}.0000.${dev}`;
  scope.outbox = [{ k: "bm:outboxed", h, v: { k: "u", p: "bar", t: "Outboxed", u: "https://outboxed.example/", a: 1, pos: "z" } }];
  scope.records["bm:outboxed"] = { h, v: scope.outbox[0].v, o: [dev, scope.seq + 1] };
  older.set("sync-state.nns", `sealed:${JSON.stringify(state)}`);
  shell.docs.clear();
  for (const [name, contents] of older) shell.docs.set(name, contents);
  const again = await launch();
  again.startSync();
  await settle();
  await again.syncNow();
  await settle();
  assertNoSeqReused();
});

const bookmarkOps = (syncId) => files().filter(({ scope }) => scope === `p:${syncId}`).flatMap(({ file }) => file.ops ?? Object.entries(file.records ?? {}).map(([k, r]) => ({ k, v: r.v })));
const titles = () => Object.values(S().bookmarks.nodes).filter((n) => n.kind === "url").map((n) => n.title).sort();

test("B43: after a relaunch with a healthy state, an edit made just before quitting goes out in the first cycle, ahead of a later edit elsewhere", async () => {
  reset();
  const engine = await onAndSynced();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const one = Object.values(S().bookmarks.nodes).find((n) => n.kind === "url" && n.title === "One");
  S().updateBookmark(one.id, { title: "Renamed before quitting" });
  const again = await launch();
  again.startSync();
  await settle();
  await again.syncNow();
  await settle();
  assert.ok(bookmarkOps(syncId).some((op) => op.v?.t === "Renamed before quitting"), "the rename went out in the first cycle after the relaunch");
});

test("B44: an adapter that never becomes ready doesn't keep the others rebuilding, so a later relaunch keeps an edit made before quitting", async () => {
  reset();
  const engine = await onAndSynced();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  void engine;
  shell.docs.set("sync-state.nns", "not-sealed-by-this-key");
  const rebuilt = await launch();
  rebuilt.startSync();
  await settle();
  for (let i = 0; i < 3; i++) await rebuilt.syncNow();
  await settle();
  assert.ok(!S().historyReady?.default, "control: history never became ready");
  const one = Object.values(S().bookmarks.nodes).find((n) => n.kind === "url" && n.title === "One");
  S().updateBookmark(one.id, { title: "Renamed before quitting" });
  const again = await launch();
  again.startSync();
  await settle();
  await again.syncNow();
  await again.syncNow();
  await settle();
  assert.deepEqual(titles(), ["Renamed before quitting"]);
  assert.ok(bookmarkOps(syncId).some((op) => op.v?.t === "Renamed before quitting"), "the rename was published");
});

function appMac(prefix) {
  const store = new Map();
  const state = sync.emptyScope();
  state.joined = true;
  const clock = new sync.Clock("appMac");
  const adapter = {
    prefix,
    extract: () => ({ values: new Map(store) }),
    apply: (visible, changed) => {
      for (const k of changed) visible.has(k) ? store.set(k, visible.get(k)) : store.delete(k);
    },
  };
  return { store, sync: () => sync.syncScope({ scope: "app", state, transport: rawTransport, adapters: [adapter], clock, device: "appMac" }) };
}

test("B45: after a relaunch with a healthy state, a setting first chosen here while another Mac's older choice waited in the folder is kept, not replaced by it", async () => {
  reset();
  await onAndSynced();
  const other = appMac("set:");
  await other.sync();
  other.store.set("set:appearance", { v: "dark" });
  await other.sync();
  S().updateSettings({ appearance: "light" });
  const again = await launch();
  again.startSync();
  await settle();
  await again.syncNow();
  await again.syncNow();
  await settle();
  await other.sync();
  assert.equal(S().settings.appearance, "light");
  assert.deepEqual(other.store.get("set:appearance"), { v: "light" });
});

test("B46: a rebuild doesn't count a bookmark as edited when only its position moved because a sibling was deleted here, so it doesn't bring back a bookmark another Mac deleted", async () => {
  reset();
  const engine = await onAndSynced();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  S().addBookmark({ profileId: "default", url: "https://two.example/", title: "Two" });
  S().addBookmark({ profileId: "default", url: "https://three.example/", title: "Three" });
  await engine.syncNow();
  await settle();
  const other = otherMac(`p:${syncId}`);
  await other.sync();
  const [twoKey] = [...other.store].find(([, v]) => v.t === "Two");
  other.store.delete(twoKey);
  await other.sync();
  shell.docs.set("sync-state.nns", "not-sealed-by-this-key");
  const again = await launch();
  again.startSync();
  await settle();
  const one = Object.values(S().bookmarks.nodes).find((n) => n.kind === "url" && n.title === "One");
  S().removeBookmark(one.id);
  for (let i = 0; i < 3; i++) await again.syncNow();
  await settle();
  await other.sync();
  assert.ok(!other.store.has(twoKey), `Two stays deleted in the folder (B has ${[...other.store.values()].map((v) => v.t)})`);
  assert.deepEqual(titles(), ["Three"]);
});

test("B47: during a rebuild, a bookmark renamed right after the bookmarks load, before the first cycle, keeps the rename", async () => {
  reset();
  const engine = await onAndSynced();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  shell.docs.set("sync-state.nns", "not-sealed-by-this-key");
  useBrowser.setState({ bookmarksReady: {} });
  const again = await launch();
  again.startSync();
  await settle();
  useBrowser.setState({ bookmarksReady: { default: true } });
  await settle();
  const one = Object.values(S().bookmarks.nodes).find((n) => n.kind === "url" && n.title === "One");
  S().updateBookmark(one.id, { title: "Renamed after loading" });
  for (let i = 0; i < 3; i++) await again.syncNow();
  await settle();
  assert.deepEqual(titles(), ["Renamed after loading"]);
  assert.ok(bookmarkOps(syncId).some((op) => op.v?.t === "Renamed after loading"), "the rename was published");
});

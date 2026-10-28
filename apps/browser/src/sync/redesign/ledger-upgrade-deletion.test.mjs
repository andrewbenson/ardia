import assert from "node:assert/strict";
import { test } from "node:test";
await import("../../store/browser.ts");
const { Clock, emptyScope, syncScope } = await import("@ardia/sync");
const { ledgerPasswordsAdapter } = await import("../ledgerPasswords.ts");
const stub = await import("../../test-native/index.ts");
const { plainOf, sealMarked, sealedCalls } = await import("./fakeSeal.mjs");
const { judge, digestOf } = await import("../passwordLedger.ts");

const SITE = "https://site.example";
const KEY = `pw:${SITE}\nbob`;
const LOGIN = `${SITE}\nbob`;
const login = (password, at) => ({ origin: `${SITE}/`, url: SITE, username: "bob", password, created: at, modified: at });
const userLogin = (username, password, at) => ({ origin: `${SITE}/`, url: SITE, username, password, created: at, modified: at });
const users = (n) => Array.from({ length: n }, (_, i) => `user${i}`);
const keyOf = (username) => `pw:${SITE}\n${username}`;

async function world(run) {
  let now = 1_800_000_000_000;
  const realNow = Date.now;
  Date.now = () => now;
  const marks = new Map();
  stub.docs.clear();
  const hooks = { read: null, mark: null };
  globalThis.acTestEngineCall = (name, _profile, args) => {
    if (name !== "ac_passwords_mark") return {};
    const device = stub.current.device;
    const parked = hooks.mark?.(device);
    const land = () => (marks.set(device, args.value), { ok: true });
    return parked instanceof Promise ? parked.then(land) : land();
  };
  try {
    const files = new Map();
    const transport = {
      write: async (scope, payload) => (files.set(`f${files.size + 1}`, { scope, payload }), `f${files.size}`),
      read: async (scope, known) => {
        const shown = [...files].filter(([, f]) => f.scope === scope);
        return { files: shown.filter(([id]) => !known.includes(id)).map(([id, f]) => ({ id, payload: f.payload })), pending: [], damaged: [], present: shown.map(([id]) => id) };
      },
      remove: async () => {},
    };
    const calls = sealedCalls(() => stub.ardiaCoreNativeModules.ArdiaCEF);
    const device = (name) => {
      stub.passwordStores.set(name, new Map());
      const store = stub.passwordStores.get(name);
      const unopened = new Set();
      let missing = false;
      const read = sealMarked(async () => (hooks.read?.(name), missing ? null : { logins: [...store.values()], mark: marks.get(name) ?? null }));
      const check = async (values) => (await calls.check(values)).map((opens, i) => opens && !unopened.has(`pw:${values[i].o}\n${values[i].u}`));
      const pw = ledgerPasswordsAdapter(name, () => true, read, () => "s", { ...calls, check });
      const state = emptyScope();
      state.joined = true;
      const clock = new Clock(name);
      const sync = async () => {
        stub.current.device = name;
        now += 60_000;
        return syncScope({ scope: "s", state, transport, adapters: [pw], clock, device: name, now: () => now, options: { writtenKeysOnly: true } });
      };
      const upgrade = () => {
        const ledger = JSON.parse(stub.docs.get("sync-pw-ledger.json") ?? "null");
        if (ledger?.profiles) delete ledger.profiles[name];
        stub.docs.set("sync-pw-ledger.json", JSON.stringify(ledger ?? { v: 2, profiles: {} }));
        marks.delete(name);
      };
      const setMissing = (value) => {
        missing = value;
      };
      return { store, state, sync, upgrade, pw, unopened, setMissing };
    };
    await run({ device, later: (ms) => (now += ms), now: () => now, hooks });
  } finally {
    Date.now = realNow;
  }
}

test("UPGRADE-delete: a login this Mac agreed with and then deleted before its first ledger goes out as a deletion", () =>
  world(async ({ device, now }) => {
    const a = device("A");
    const b = device("B");
    a.store.set(LOGIN, login("p1", now()));
    a.store.set(`${SITE}\nother`, userLogin("other", "o1", now()));
    await a.sync();
    await b.sync();
    assert.equal(plainOf(b.state.records[KEY]?.v), "p1", "control: B has A's login");
    assert.equal(b.store.get(LOGIN)?.password, "p1", "control: and saved it");

    a.upgrade();
    a.store.delete(LOGIN);
    for (let i = 0; i < 3; i++) await a.sync();
    assert.equal(a.state.records[KEY]?.v ?? null, null, "A's deletion is recorded");
    assert.equal(a.store.has(LOGIN), false, "and A doesn't take the login back");
    await b.sync();
    assert.equal(b.store.has(LOGIN), false, "B removes it");
  }));

test("UPGRADE-delete-conflict: a login changed elsewhere since this Mac last agreed comes back rather than being deleted", () =>
  world(async ({ device, now, later }) => {
    const a = device("A");
    const b = device("B");
    a.store.set(LOGIN, login("p1", now()));
    await a.sync();
    await b.sync();
    later(1000);
    b.store.set(LOGIN, login("p2", now()));
    await b.sync();

    a.upgrade();
    a.store.delete(LOGIN);
    await a.sync();
    await a.sync();
    assert.equal(a.store.get(LOGIN)?.password, "p2", "A takes B's newer value");
    await b.sync();
    assert.equal(b.store.get(LOGIN)?.password, "p2", "and B keeps it");
  }));

test("UPGRADE-never-applied: a login this Mac never had is applied at its first ledger, not deleted", () =>
  world(async ({ device, now }) => {
    const a = device("A");
    const b = device("B");
    b.store.set(LOGIN, login("p1", now()));
    await b.sync();

    a.upgrade();
    await a.sync();
    await a.sync();
    assert.equal(a.store.get(LOGIN)?.password, "p1", "A applies it");
    await b.sync();
    assert.equal(b.store.get(LOGIN)?.password, "p1", "and B keeps it");
  }));

test("UPGRADE-unapplied: a login still waiting to be applied here is applied at the first ledger, not read as deleted", () =>
  world(async ({ device, now }) => {
    const a = device("A");
    const b = device("B");
    a.store.set(LOGIN, login("p1", now()));
    await a.sync();
    await b.sync();

    a.upgrade();
    a.store.delete(LOGIN);
    a.state.unapplied = [...a.state.unapplied, KEY];
    await a.sync();
    await a.sync();
    assert.equal(a.store.get(LOGIN)?.password, "p1", "A applies it");
    await b.sync();
    assert.equal(b.store.get(LOGIN)?.password, "p1", "and B keeps it");
  }));

test("UPGRADE-empty: an empty Login Data at the first ledger deletes nothing and gets every login back", () =>
  world(async ({ device, now }) => {
    const a = device("A");
    const b = device("B");
    for (const u of users(5)) a.store.set(`${SITE}\n${u}`, userLogin(u, `p-${u}`, now()));
    await a.sync();
    await b.sync();
    assert.equal(b.store.size, 5, "control: B has all five");

    a.upgrade();
    a.store.clear();
    for (let i = 0; i < 3; i++) await a.sync();
    for (const u of users(5)) assert.equal(plainOf(a.state.records[keyOf(u)]?.v), `p-${u}`, `${u} isn't deleted`);
    for (const u of users(5)) assert.equal(a.store.get(`${SITE}\n${u}`)?.password, `p-${u}`, `A gets ${u} back`);
    await b.sync();
    assert.equal(b.store.size, 5, "and B keeps all five");
  }));

test("UPGRADE-missing: a Login Data that can't be read at the first ledger deletes nothing", () =>
  world(async ({ device, now }) => {
    const a = device("A");
    const b = device("B");
    for (const u of users(5)) a.store.set(`${SITE}\n${u}`, userLogin(u, `p-${u}`, now()));
    await a.sync();
    await b.sync();

    a.upgrade();
    a.store.clear();
    a.setMissing(true);
    for (let i = 0; i < 3; i++) await a.sync();
    for (const u of users(5)) assert.equal(plainOf(a.state.records[keyOf(u)]?.v), `p-${u}`, `${u} isn't deleted`);
    await b.sync();
    assert.equal(b.store.size, 5, "B keeps all five");

    a.setMissing(false);
    for (let i = 0; i < 3; i++) await a.sync();
    for (const u of users(5)) assert.equal(a.store.get(`${SITE}\n${u}`)?.password, `p-${u}`, `once it reads empty, A gets ${u} back`);
  }));

test("UPGRADE-one-of-twenty: one login deleted before the first ledger goes out as one deletion", () =>
  world(async ({ device, now }) => {
    const a = device("A");
    const b = device("B");
    for (const u of users(20)) a.store.set(`${SITE}\n${u}`, userLogin(u, `p-${u}`, now()));
    await a.sync();
    await b.sync();
    assert.equal(b.store.size, 20, "control: B has all twenty");

    a.upgrade();
    a.store.delete(`${SITE}\nuser3`);
    for (let i = 0; i < 3; i++) await a.sync();
    assert.equal(a.pw.held(), 0, "nothing is held");
    assert.equal(a.state.records[keyOf("user3")]?.v ?? null, null, "user3's deletion is recorded");
    assert.equal(a.store.has(`${SITE}\nuser3`), false, "and A doesn't take it back");
    for (const u of users(20).filter((u) => u !== "user3")) assert.equal(plainOf(a.state.records[keyOf(u)]?.v), `p-${u}`, `${u} is left alone`);
    await b.sync();
    assert.equal(b.store.has(`${SITE}\nuser3`), false, "B removes user3");
    assert.equal(b.store.size, 19, "and keeps the rest");
  }));

test("UPGRADE-mass: fifteen of twenty deleted before the first ledger are held by the mass-change gate, not published", () =>
  world(async ({ device, now }) => {
    const a = device("A");
    const b = device("B");
    for (const u of users(20)) a.store.set(`${SITE}\n${u}`, userLogin(u, `p-${u}`, now()));
    await a.sync();
    await b.sync();

    a.upgrade();
    const gone = users(20).slice(0, 15);
    for (const u of gone) a.store.delete(`${SITE}\n${u}`);
    for (let i = 0; i < 4; i++) await a.sync();
    assert.equal(a.pw.held(), 15, "all fifteen are held");
    for (const u of users(20)) assert.equal(plainOf(a.state.records[keyOf(u)]?.v), `p-${u}`, `${u} isn't deleted`);
    for (const u of gone) assert.equal(a.store.has(`${SITE}\n${u}`), false, `and A doesn't quietly take ${u} back`);
    await b.sync();
    assert.equal(b.store.size, 20, "B keeps all twenty");
  }));

test("UPGRADE-unopened: a record whose seal doesn't open here isn't read as deleted at the first ledger", () =>
  world(async ({ device, now }) => {
    const a = device("A");
    const b = device("B");
    a.store.set(LOGIN, login("p1", now()));
    a.store.set(`${SITE}\nother`, userLogin("other", "o1", now()));
    await a.sync();
    await b.sync();

    a.upgrade();
    a.store.delete(LOGIN);
    a.unopened.add(KEY);
    for (let i = 0; i < 3; i++) await a.sync();
    assert.equal(plainOf(a.state.records[KEY]?.v), "p1", "no deletion goes out");
    await b.sync();
    assert.equal(b.store.get(LOGIN)?.password, "p1", "and B keeps it");
  }));

test("JUDGE-upgrade-unapplied: a key still unapplied is applied even when base agrees with the record", () => {
  const value = { o: SITE, u: "bob", s: "sealed" };
  const local = new Map([[keyOf("other"), { value: { o: SITE, u: "other", s: "x" }, modified: 1 }]]);
  const records = new Map([[KEY, { v: value, h: "0000000001000" }]]);
  const j = judge(local, null, null, records, 10, () => value, (key) => key === KEY);
  assert.equal(j.mode, "upgrade");
  assert.ok(j.apply.has(KEY), "it's applied");
  assert.equal(j.claims.some((c) => c.key === KEY), false, "no claim for it");
  assert.equal(j.deletedBeforeUpgrade.has(KEY), false, "and it isn't read as deleted");
  const agreed = judge(local, null, null, records, 10, () => value, () => false);
  assert.ok(agreed.deletedBeforeUpgrade.has(KEY), "control: without unapplied it's read as deleted");
  assert.equal(digestOf(value), digestOf(records.get(KEY).v));
});

test("UPGRADE-crash-after-mark: a crash between Login Data's mark and the first ledger still sends the deletion made before the upgrade", () =>
  world(async ({ device, now }) => {
    const a = device("A");
    const b = device("B");
    a.store.set(LOGIN, login("p1", now()));
    a.store.set(`${SITE}\nother`, userLogin("other", "o1", now()));
    await a.sync();
    await b.sync();

    a.upgrade();
    a.store.delete(LOGIN);
    await a.sync();
    const ledger = JSON.parse(stub.docs.get("sync-pw-ledger.json"));
    assert.ok(ledger.profiles.A, "control: the first cycle wrote a ledger");
    delete ledger.profiles.A;
    stub.docs.set("sync-pw-ledger.json", JSON.stringify(ledger));
    for (let i = 0; i < 3; i++) await a.sync();
    assert.equal(a.state.records[KEY]?.v ?? null, null, "A's deletion is recorded");
    assert.equal(a.store.has(LOGIN), false, "and A doesn't take the login back");
    await b.sync();
    assert.equal(b.store.has(LOGIN), false, "B removes it");
    assert.equal(b.store.get(`${SITE}\nother`)?.password, "o1", "and keeps the other");
  }));

const LEDGER = "sync-pw-ledger.json";

async function pausedWhileUnreadable(spoil) {
  await world(async ({ device, now }) => {
    const a = device("A");
    const b = device("B");
    a.store.set(LOGIN, login("p1", now()));
    a.store.set(`${SITE}\nother`, userLogin("other", "o1", now()));
    await a.sync();
    await b.sync();
    a.upgrade();
    await a.sync();
    await a.sync();
    assert.ok(JSON.parse(stub.docs.get(LEDGER)).profiles.A, "control: A has a ledger and a mark");

    a.store.delete(LOGIN);
    spoil();
    const bytes = stub.docs.get(LEDGER);
    for (let i = 0; i < 3; i++) await a.sync();
    assert.equal(plainOf(a.state.records[KEY]?.v), "p1", "no deletion goes out");
    assert.equal(stub.docs.get(LEDGER), bytes, "the ledger doc isn't written over");
    assert.equal(a.store.has(LOGIN), false, "nor is the login put back while passwords are paused");
    await b.sync();
    assert.equal(b.store.get(LOGIN)?.password, "p1", "and B keeps it");
  });
  stub.unreadableDocs.clear();
}

test("LEDGER-unreadable: a ledger doc that fails to read pauses passwords: no claim, no write", () =>
  pausedWhileUnreadable(() => stub.unreadableDocs.set(LEDGER, "EIO")));

test("LEDGER-corrupt: a ledger doc that doesn't parse pauses passwords: no claim, no write", () =>
  pausedWhileUnreadable(() => stub.docs.set(LEDGER, `${stub.docs.get(LEDGER).slice(0, 20)}`)));

test("LEDGER-other-profiles: a profile whose entry is missing writes its first ledger without wiping another profile's", () =>
  world(async ({ device, now }) => {
    const a = device("A");
    const b = device("B");
    a.store.set(LOGIN, login("p1", now()));
    await a.sync();
    await b.sync();
    await a.sync();
    const before = JSON.parse(stub.docs.get(LEDGER)).profiles;
    assert.ok(before.A && before.B, "control: both profiles have ledgers");
    b.upgrade();
    await b.sync();
    const after = JSON.parse(stub.docs.get(LEDGER)).profiles;
    assert.ok(after.B, "B writes its first ledger again");
    assert.deepEqual(after.A, before.A, "and A's ledger is untouched");
  }));

test("JUDGE-modes: only a missing ledger is upgrade mode; a ledger without its mark is still a rebuild", () => {
  const records = new Map([[KEY, { v: { o: SITE, u: "bob", s: "x" }, h: "0000000001000" }]]);
  const local = new Map([[keyOf("other"), { value: { o: SITE, u: "other", s: "y" }, modified: 1 }]]);
  const ledger = { v: 1, L: 2, t: 5, keys: {} };
  assert.equal(judge(local, null, null, records, 10).mode, "upgrade");
  assert.equal(judge(local, { L: 2, t: 5 }, null, records, 10).mode, "upgrade", "a mark without its ledger means nothing");
  assert.equal(judge(local, null, ledger, records, 10).mode, "rebuild");
  assert.equal(judge(local, { L: 1, t: 5 }, ledger, records, 10).mode, "rebuild");
  assert.equal(judge(local, { L: 2, t: 5 }, ledger, records, 10).mode, "consistent");
});

function ledgerReadsFail(count = Infinity) {
  let left = count;
  stub.unreadableDocs.has = (name) => name === LEDGER && left-- > 0;
  stub.unreadableDocs.get = (name) => (name === LEDGER ? "EIO" : undefined);
}

function ledgerReadsWork() {
  delete stub.unreadableDocs.has;
  delete stub.unreadableDocs.get;
}

async function twoProfilesSynced({ device, now }) {
  const a = device("A");
  const b = device("B");
  a.store.set(LOGIN, login("p1", now()));
  a.store.set(`${SITE}\nother`, userLogin("other", "o1", now()));
  await a.sync();
  await b.sync();
  await a.sync();
  await b.sync();
  const profiles = JSON.parse(stub.docs.get(LEDGER)).profiles;
  assert.ok(profiles.A && profiles.B, "control: both profiles have ledgers");
  return { a, b };
}

test("LEDGER-transient-extract: a ledger read that fails after the writable check stops the cycle and changes nothing", () =>
  world(async ({ device, now, hooks }) => {
    const { a, b } = await twoProfilesSynced({ device, now });
    a.store.delete(LOGIN);
    const bytes = stub.docs.get(LEDGER);
    let armed = false;
    hooks.read = (name) => name === "A" && !armed && ((armed = true), ledgerReadsFail(2));
    try {
      await a.sync();
    } finally {
      hooks.read = null;
      ledgerReadsWork();
    }
    assert.equal(plainOf(a.state.records[KEY]?.v), "p1", "no deletion goes out");
    assert.equal(stub.docs.get(LEDGER), bytes, "the ledger doc is unchanged, B's entry with it");
    assert.equal(a.pw.held(), 0, "nothing is held");
    for (let i = 0; i < 2; i++) await a.sync();
    assert.equal(a.state.records[KEY]?.v ?? null, null, "control: once the doc reads again, the deletion goes out");
    await b.sync();
    assert.equal(b.store.has(LOGIN), false);
  }));

test("LEDGER-transient-write: a ledger read that fails between Login Data's mark and the doc write writes nothing", () =>
  world(async ({ device, now, hooks }) => {
    const { a } = await twoProfilesSynced({ device, now });
    const before = JSON.parse(stub.docs.get(LEDGER)).profiles;
    a.store.set(`${SITE}\nnew`, userLogin("new", "n1", now()));
    hooks.mark = (name) => name === "A" && ledgerReadsFail();
    try {
      await a.sync();
    } finally {
      hooks.mark = null;
      ledgerReadsWork();
    }
    const after = JSON.parse(stub.docs.get(LEDGER)).profiles;
    assert.deepEqual(after.B, before.B, "B's ledger isn't wiped");
    assert.deepEqual(after.A, before.A, "and A's isn't written from a failed read");
  }));

test("LEDGER-transient-apply: a ledger read that fails inside apply writes no password", () =>
  world(async ({ device, now, later, hooks }) => {
    const { a, b } = await twoProfilesSynced({ device, now });
    later(1000);
    b.store.set(LOGIN, login("p2", now()));
    await b.sync();
    const bytes = stub.docs.get(LEDGER);
    let reads = 0;
    hooks.read = (name) => name === "A" && ++reads === 2 && ledgerReadsFail();
    try {
      await a.sync();
    } finally {
      hooks.read = null;
      ledgerReadsWork();
    }
    assert.ok(reads >= 2, "control: apply read Login Data");
    assert.equal(a.store.get(LOGIN)?.password, "p1", "B's change isn't written while the ledger can't be read");
    assert.equal(stub.docs.get(LEDGER), bytes, "nor is the doc");
    for (let i = 0; i < 2; i++) await a.sync();
    assert.equal(a.store.get(LOGIN)?.password, "p2", "control: once it reads, the change lands");
  }));

async function resolveDuringParkedWrite(choice) {
  await world(async ({ device, now, later, hooks }) => {
    const a = device("A");
    const b = device("B");
    for (const u of users(8)) a.store.set(`${SITE}\n${u}`, userLogin(u, `p-${u}`, now()));
    await a.sync();
    await b.sync();
    await a.sync();
    const gone = users(8).slice(0, 7);
    for (const u of gone) a.store.delete(`${SITE}\n${u}`);
    for (let i = 0; i < 2; i++) await a.sync();
    assert.equal(a.pw.held(), 7, "control: the seven deletions are held");
    assert.equal(JSON.parse(stub.docs.get(LEDGER)).profiles.A.held.length, 7, "control: and the hold is saved");

    later(1000);
    b.store.set(`${SITE}\nuser7`, userLogin("user7", "changed", now()));
    await b.sync();
    let release;
    let parked;
    const parkedOnMark = new Promise((resolve) => (parked = resolve));
    hooks.mark = (name) => {
      if (name !== "A") return undefined;
      hooks.mark = null;
      parked();
      return new Promise((r) => (release = r));
    };
    const cycle = a.sync();
    const first = await Promise.race([parkedOnMark.then(() => "parked"), cycle.then(() => "done")]);
    assert.equal(first, "parked", "control: applying B's change parks a ledger write on the mark");
    a.pw.resolveHeld(choice);
    assert.deepEqual(JSON.parse(stub.docs.get(LEDGER)).profiles.A.held, [], `control: ${choice} saves an empty hold`);
    release();
    await cycle;
    for (let i = 0; i < 5; i++) await new Promise((r) => setTimeout(r, 0));
    assert.ok(JSON.parse(stub.docs.get(LEDGER)).profiles.A.L > 1, "control: the parked write landed");
    assert.deepEqual(JSON.parse(stub.docs.get(LEDGER)).profiles.A.held, [], "the parked write doesn't put the old hold back");

    for (let i = 0; i < 3; i++) await a.sync();
    assert.equal(a.pw.held(), 0, "nothing is held again");
    await b.sync();
    if (choice === "confirm") {
      for (const u of gone) assert.equal(a.state.records[keyOf(u)]?.v ?? null, null, `Confirm sends ${u}'s deletion`);
      for (const u of gone) assert.equal(b.store.has(`${SITE}\n${u}`), false, `and B removes ${u}`);
    } else {
      for (const u of gone) assert.equal(a.store.get(`${SITE}\n${u}`)?.password, `p-${u}`, `Restore puts ${u} back here`);
      assert.equal(b.store.size, 8, "and B keeps all eight");
    }
  });
}

test("HELD-resolve-during-write: a Confirm made while a ledger write waits on Login Data's mark isn't undone by that write", () => resolveDuringParkedWrite("confirm"));

test("HELD-restore-during-write: a Restore made while a ledger write waits on Login Data's mark isn't undone by that write", () => resolveDuringParkedWrite("restore"));

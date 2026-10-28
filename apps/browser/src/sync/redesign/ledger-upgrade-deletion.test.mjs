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
  globalThis.acTestEngineCall = (name, _profile, args) => (name === "ac_passwords_mark" ? (marks.set(stub.current.device, args.value), { ok: true }) : {});
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
      const read = sealMarked(async () => (missing ? null : { logins: [...store.values()], mark: marks.get(name) ?? null }));
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
    await run({ device, later: (ms) => (now += ms), now: () => now });
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

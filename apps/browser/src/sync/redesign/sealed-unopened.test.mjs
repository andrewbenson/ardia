import assert from "node:assert/strict";
import { test } from "node:test";
await import("../../store/browser.ts");
const { Clock, emptyScope, syncScope } = await import("@solara/sync");
const { ledgerPasswordsAdapter } = await import("../ledgerPasswords.ts");
const stub = await import("../../test-native/index.ts");
const { plainOf, sealMarked, sealedCalls } = await import("./fakeSeal.mjs");

const SITE = "https://site.example";
const KEY = `pw:${SITE}\nme`;
const OTHER = `pw:${SITE}\nother`;
const login = (username, password, at) => ({ origin: `${SITE}/`, url: SITE, username, password, created: at, modified: at });

test("SEALED-unopened: a login whose seal doesn't open is ignored, not removed, not published, and offered again next cycle", async () => {
  let now = 1_800_000_000_000;
  const realNow = Date.now;
  Date.now = () => now;
  let mark = null;
  globalThis.acTestEngineCall = (name, _profile, args) => (name === "ac_passwords_mark" ? ((mark = args.value), { ok: true }) : {});
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
    stub.passwordStores.set("A", new Map());
    const here = stub.passwordStores.get("A");
    const unopened = new Set();
    const calls = sealedCalls(() => stub.solaraCoreNativeModules.SolaraCEF);
    const check = async (values) => (await calls.check(values)).map((opens, i) => opens && !unopened.has(`pw:${values[i].o}\n${values[i].u}`));
    const read = sealMarked(async () => ({ logins: [...here.values()], mark }));
    const pw = ledgerPasswordsAdapter("A", () => true, read, () => "s", { ...calls, check });
    const state = emptyScope();
    state.joined = true;
    const clock = new Clock("A");
    const sync = async () => {
      stub.current.device = "A";
      now += 60_000;
      await syncScope({ scope: "s", state, transport, adapters: [pw], clock, device: "A", now: () => now, options: { writtenKeysOnly: true } });
    };
    const ops = (key) => [...files.values()].flatMap((f) => JSON.parse(f.payload).ops ?? []).filter((op) => op.k === key);
    const ledgerEntry = (key) => JSON.parse(stub.docs.get("sync-pw-ledger.json") ?? "null")?.profiles?.A?.keys?.[key];

    here.set(`${SITE}\nme`, login("me", "first", now));
    here.set(`${SITE}\nother`, login("other", "o1", now));
    await sync();
    assert.equal(plainOf(state.records[KEY]?.v), "first", "control: both logins go out while their seals open");
    const entryBefore = ledgerEntry(KEY);
    assert.ok(entryBefore, "control: the ledger holds the published login");

    here.set(`${SITE}\nme`, login("me", "second", now + 1000));
    here.set(`${SITE}\nother`, login("other", "o2", now + 1000));
    unopened.add(KEY);
    const sentBefore = ops(KEY).length;
    await sync();
    assert.equal(plainOf(state.records[OTHER]?.v), "o2", "control: a login whose seal opens still goes out in the same cycle");
    assert.equal(ops(KEY).length, sentBefore, "nothing is published for the unopened login");
    assert.ok(ops(KEY).every((op) => op.v), "and no deletion goes out for it");
    assert.equal(plainOf(state.records[KEY]?.v), "first", "its record is left as it was");
    assert.deepEqual(ledgerEntry(KEY), entryBefore, "nor is it stamped in the ledger");
    assert.equal(here.get(`${SITE}\nme`)?.password, "second", "and the login here isn't overwritten");

    unopened.clear();
    await sync();
    assert.equal(plainOf(state.records[KEY]?.v), "second", "once its seal opens, the next cycle offers it again and it goes out");
    assert.equal(plainOf(ops(KEY).at(-1)?.v), "second");
  } finally {
    Date.now = realNow;
  }
});

test("SEALED-unopened: a newer folder record doesn't overwrite a login whose seal doesn't open, and isn't reapplied or stamped", async () => {
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
    const unopened = new Set();
    const calls = sealedCalls(() => stub.solaraCoreNativeModules.SolaraCEF);
    const check = async (values) => (await calls.check(values)).map((opens, i) => opens && !unopened.has(`pw:${values[i].o}\n${values[i].u}`));
    const reapplied = [];
    const device = (name) => {
      stub.passwordStores.set(name, new Map());
      const store = stub.passwordStores.get(name);
      const read = sealMarked(async () => ({ logins: [...store.values()], mark: marks.get(name) ?? null }));
      const pw = ledgerPasswordsAdapter(name, () => true, read, () => "s", { ...calls, check });
      const extract = pw.extract;
      pw.extract = async (...args) => {
        const result = await extract(...args);
        if (name === "A" && result) reapplied.push(new Set(result.reapply));
        return result;
      };
      const state = emptyScope();
      state.joined = true;
      const clock = new Clock(name);
      const sync = async () => {
        stub.current.device = name;
        now += 60_000;
        return syncScope({ scope: "s", state, transport, adapters: [pw], clock, device: name, now: () => now, options: { writtenKeysOnly: true } });
      };
      return { store, state, sync };
    };
    const a = device("A");
    const b = device("B");
    const ledgerEntry = (key) => JSON.parse(stub.docs.get("sync-pw-ledger.json") ?? "null")?.profiles?.A?.keys?.[key];

    a.store.set(`${SITE}\nme`, login("me", "first", now));
    await a.sync();
    await b.sync();
    await b.sync();
    assert.equal(b.store.get(`${SITE}\nme`)?.password, "first", "control: the other device takes the login");

    now += 60_000;
    b.store.set(`${SITE}\nme`, login("me", "from-b", now));
    await b.sync();
    assert.equal(plainOf(b.state.records[KEY]?.v), "from-b", "control: the other device publishes a newer value");

    unopened.add(KEY);
    const entryBefore = ledgerEntry(KEY);
    reapplied.length = 0;
    await a.sync();
    assert.ok(reapplied.length > 0, "control: the cycle judged the passwords");
    assert.ok(reapplied.every((keys) => !keys.has(KEY)), "the unopened login isn't reapplied");
    assert.ok(a.state.unapplied.includes(KEY), "it stays pending, so the record is offered again next cycle");
    assert.notEqual(plainOf(a.state.base[KEY] ? JSON.parse(a.state.base[KEY]) : null), "from-b", "and the base doesn't move past it");
    assert.equal(a.store.get(`${SITE}\nme`)?.password, "first", "the login here stays untouched");
    assert.deepEqual(ledgerEntry(KEY), entryBefore, "and its ledger entry isn't stamped");

    unopened.clear();
    await a.sync();
    assert.equal(a.store.get(`${SITE}\nme`)?.password, "from-b", "once its seal opens, the newer record lands");
  } finally {
    Date.now = realNow;
  }
});

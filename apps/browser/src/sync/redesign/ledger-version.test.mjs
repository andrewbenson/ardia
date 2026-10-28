import assert from "node:assert/strict";
import { test } from "node:test";
const { fixedBy } = await import("./switchOn.mjs");
const shell = await import("../../test-native/index.ts");
const { ledgerPasswordsAdapter, readLedgerDoc } = await import("../ledgerPasswords.ts");
const { sealMarked, sealedCalls } = await import("./fakeSeal.mjs");

test("LEDGER-v: a sync-pw-ledger.json from a newer version is refused, not read as absent", fixedBy("step 3"), async () => {
  assert.equal(readLedgerDoc(JSON.stringify({ v: 3, profiles: {} })), "newer");
  assert.equal(readLedgerDoc(JSON.stringify({ v: "2", profiles: {} })), "newer");
  assert.equal(readLedgerDoc(JSON.stringify({ v: 1, profiles: {} })), "older", "a ledger over plain digests waits for its migration");
  assert.deepEqual(readLedgerDoc(JSON.stringify({ v: 2, profiles: { a: { L: 1, t: 2, keys: {} } } })), { v: 2, profiles: { a: { L: 1, t: 2, keys: {} } } });
  assert.equal(readLedgerDoc(JSON.stringify({ v: 2, profiles: { a: { L: 1 } } })), "unreadable", "an entry missing its fields pauses passwords");
  assert.equal(readLedgerDoc(JSON.stringify({ v: 2, profiles: { a: { L: 1, t: 2, keys: {}, held: "pw:a" } } })), "unreadable", "a held list that isn't one isn't read as its characters");
  assert.equal(readLedgerDoc("{"), "unreadable", "a ledger that doesn't parse isn't read as absent");
  assert.equal(readLedgerDoc(JSON.stringify({ profiles: {} })), "unreadable");
  assert.equal(readLedgerDoc(JSON.stringify({ v: 2 })), "unreadable");
  assert.deepEqual(readLedgerDoc(null), { v: 2, profiles: {} });
  for (const unread of [{ v: 3, profiles: { default: { L: 9, t: 9, keys: {}, sealed: true } } }, { v: 1, profiles: { default: { L: 9, t: 9, keys: { "pw:https://a.example\nme": { d: ["3.x"], h: null, m: 1 } } } } }]) {
    shell.docs.clear();
    const text = JSON.stringify(unread);
    shell.docs.set("sync-pw-ledger.json", text);
    let reads = 0;
    const adapter = ledgerPasswordsAdapter("default", () => true, sealMarked(async () => (reads++, { logins: [], mark: "1@1" })), () => "scope", sealedCalls(() => shell.ardiaCoreNativeModules.ArdiaCEF));
    const extraction = await adapter.extract(() => undefined, () => false, Date.now(), () => false, () => undefined, () => undefined, () => false);
    assert.equal(extraction, null, `v${unread.v}: nothing is extracted, so nothing publishes`);
    assert.equal(await adapter.apply(new Map(), new Set(["pw:https://a.example\nme"]), () => undefined, { known: () => false, now: Date.now(), horizon: 0, joined: true }), false, `v${unread.v}: nothing is applied`);
    assert.equal(reads, 0, `v${unread.v}: Login Data isn't even read`);
    adapter.resolveHeld("confirm");
    assert.equal(shell.docs.get("sync-pw-ledger.json"), text, `v${unread.v}: and the ledger is left as it was`);
  }
});

test("LEDGER-unwritable: a ledger that wouldn't read back isn't written, and the cycle sends nothing", async () => {
  shell.docs.clear();
  const { seal } = await import("./fakeSeal.mjs");
  const key = "pw:https://a.example\nme";
  const value = { o: "https://a.example", u: "me", s: seal("https://a.example", "me", "pw") };
  const read = async () => ({ logins: [{ origin: value.o, username: value.u, s: value.s }], mark: null });
  const adapter = ledgerPasswordsAdapter("default", () => true, read, () => "scope", sealedCalls(() => shell.ardiaCoreNativeModules.ArdiaCEF));
  const extraction = await adapter.extract(() => undefined, () => false, Date.now(), (k) => k === key, (k) => (k === key ? value : undefined), (k) => (k === key ? "0mubd9tsh.0000.dev1" : undefined), () => false);
  assert.equal(extraction, null, "a cycle whose ledger can't be written sends nothing");
  assert.equal(shell.docs.get("sync-pw-ledger.json"), undefined, "a login with no time would give m: null, so that ledger isn't written");
  assert.notEqual(readLedgerDoc(shell.docs.get("sync-pw-ledger.json") ?? null), "unreadable", "and the next read isn't unreadable");
});

import assert from "node:assert/strict";
import { test } from "node:test";
const { fixedBy } = await import("./switchOn.mjs");
const shell = await import("../../test-native/index.ts");
const { ledgerPasswordsAdapter, readLedgerDoc } = await import("../ledgerPasswords.ts");

test("LEDGER-v: a sync-pw-ledger.json from a newer version is refused, not read as absent", fixedBy("step 3"), async () => {
  assert.equal(readLedgerDoc(JSON.stringify({ v: 2, profiles: {} })), "newer");
  assert.equal(readLedgerDoc(JSON.stringify({ v: "1", profiles: {} })), "newer");
  assert.deepEqual(readLedgerDoc(JSON.stringify({ v: 1, profiles: { a: { L: 1 } } })), { v: 1, profiles: { a: { L: 1 } } });
  assert.deepEqual(readLedgerDoc("{"), { v: 1, profiles: {} }, "control: unreadable is still read as absent");
  assert.deepEqual(readLedgerDoc(null), { v: 1, profiles: {} });
  shell.docs.clear();
  const newer = JSON.stringify({ v: 2, profiles: { default: { L: 9, t: 9, keys: {}, sealed: true } } });
  shell.docs.set("sync-pw-ledger.json", newer);
  let reads = 0;
  const adapter = ledgerPasswordsAdapter("default", () => true, async () => (reads++, { logins: [], mark: "1@1" }), () => "scope");
  const extraction = await adapter.extract(() => undefined, () => false, Date.now(), () => false, () => undefined, () => undefined, () => false);
  assert.equal(extraction, null, "nothing is extracted, so nothing publishes");
  assert.equal(await adapter.apply(new Map(), new Set(["pw:https://a.example\nme"]), () => undefined, { known: () => false, now: Date.now(), horizon: 0, joined: true }), false, "nothing is applied");
  assert.equal(reads, 0, "Login Data isn't even read");
  assert.equal(shell.docs.get("sync-pw-ledger.json"), newer, "and the newer ledger is left as it was");
});

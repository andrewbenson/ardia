import assert from "node:assert/strict";
import { test } from "node:test";

const load = () => import("../passwordLedger.ts");
const v = (p, u = "me") => ({ o: "https://site.example", u, p });
const K = "pw:https://site.example\nme";
const at = (ms, device = "B") => `${Math.floor(ms).toString(36).padStart(9, "0")}.0000.${device}`;

async function setup({ ledger: ledgerPassword, local, record, mark = "same", modified = 5_000, ledgerModified = 1_000, history = [] }) {
  const { judge, digestOf } = await load();
  const ledger = ledgerPassword === undefined ? null : { v: 1, L: 3, t: 2_000, keys: ledgerPassword === null ? {} : { [K]: { d: [digestOf(v(ledgerPassword)), ...history.map((p) => digestOf(v(p)))], h: at(1_000), m: ledgerModified } } };
  const m = mark === "same" ? (ledger ? { L: ledger.L, t: ledger.t } : null) : mark;
  const localMap = new Map(local === undefined ? [] : [[K, { value: v(local), modified }]]);
  const records = new Map(record === undefined ? [] : [[K, { v: record === null ? null : v(record), h: at(3_000) }]]);
  return judge(localMap, m, ledger, records, 10_000);
}

test("JUDGE-equal: a login equal to its record is seeded, never claimed, ledger or not", async () => {
  for (const ledger of [undefined, null, "old"]) {
    const j = await setup({ ledger, local: "same", record: "same" });
    assert.deepEqual([j.claims.length, [...j.seed]], [0, [K]], `ledger ${ledger}`);
  }
});

test("JUDGE-edit-agreed: an edit over the value the folder still holds is stamped after the record", async () => {
  const j = await setup({ ledger: "p1", local: "p2", record: "p1" });
  assert.equal(j.mode, "consistent");
  assert.deepEqual(j.claims.map((c) => [c.v?.p, c.afterRecord]), [["p2", at(3_000)]]);
});

test("JUDGE-edit-conflict: an edit over a value changed elsewhere is stamped at its own modified time", async () => {
  const j = await setup({ ledger: "p1", local: "p2", record: "p3", modified: 4_000 });
  assert.deepEqual(j.claims.map((c) => [c.v?.p, c.at, c.afterRecord]), [["p2", 4_000, null]]);
});

test("JUDGE-rollback: a digest matching an older one, dated at or before the ledger's, takes the folder's value", async () => {
  const j = await setup({ ledger: "p2", history: ["p1"], local: "p1", record: "p2", modified: 900, ledgerModified: 1_000 });
  assert.deepEqual([j.claims.length, [...j.apply]], [0, [K]]);
});

test("JUDGE-revert: the same older digest dated after the ledger's is a deliberate edit", async () => {
  const j = await setup({ ledger: "p2", history: ["p1"], local: "p1", record: "p2", modified: 6_000, ledgerModified: 1_000 });
  assert.deepEqual(j.claims.map((c) => c.v?.p), ["p1"]);
});

test("JUDGE-delete-agreed: a ledger key missing here goes out as a deletion when the folder still holds what was agreed", async () => {
  const j = await setup({ ledger: "p1", record: "p1" });
  assert.deepEqual(j.claims.map((c) => [c.key, c.v]), [[K, null]]);
});

test("JUDGE-delete-conflict: a deletion over a value changed elsewhere is dropped and the folder's value applied back", async () => {
  const j = await setup({ ledger: "p1", record: "p3" });
  assert.deepEqual([j.claims.length, [...j.apply]], [0, [K]]);
});

test("JUDGE-rebuild: with the row off the ledger, only a login dated after both times is claimed", async () => {
  const late = await setup({ ledger: "p1", local: "p9", record: "p2", mark: { L: 5, t: 4_000 }, modified: 4_500 });
  assert.equal(late.mode, "rebuild");
  assert.deepEqual(late.claims.map((c) => c.v?.p), ["p9"]);
  const early = await setup({ ledger: "p1", local: "p3", record: "p2", mark: { L: 5, t: 4_000 }, modified: 4_000 });
  assert.deepEqual([early.claims.length, [...early.apply]], [0, [K]], "a date in the same millisecond as t isn't later");
});

test("JUDGE-rebuild-restore: Login Data older than the ledger (row below L) claims nothing older than the ledger's t", async () => {
  const j = await setup({ ledger: "p2", local: "p1", record: "p2", mark: { L: 2, t: 1_500 }, modified: 1_800 });
  assert.deepEqual([j.claims.length, [...j.apply]], [0, [K]]);
});

test("JUDGE-addition: a login the folder has no record of is an addition, except in a rebuild when it predates both write times", async () => {
  for (const [ledger, mark] of [[null, "same"], [undefined, "same"]]) {
    const j = await setup({ ledger, local: "new", mark, modified: 100 });
    assert.deepEqual(j.claims.map((c) => c.v?.p), ["new"], `ledger ${ledger}`);
  }
  const old = await setup({ ledger: "x", local: "new", mark: { L: 9, t: 9_999 }, modified: 100 });
  assert.deepEqual([old.claims.length, old.apply.size], [0, 0], "a rebuild can't trust that the folder lacks it");
  const late = await setup({ ledger: "x", local: "new", mark: { L: 9, t: 9_999 }, modified: 9_999_999 });
  assert.deepEqual(late.claims.map((c) => c.v?.p), ["new"]);
});

test("JUDGE-upgrade: no ledger and no row: a login Chrome changed after its record is claimed, an older one takes the folder's", async () => {
  const newer = await setup({ local: "mine", record: "folder", modified: 3_500 });
  assert.equal(newer.mode, "upgrade");
  assert.deepEqual(newer.claims.map((c) => [c.v?.p, c.at]), [["mine", 3_500]]);
  const older = await setup({ local: "mine", record: "folder", modified: 2_500 });
  assert.deepEqual([older.claims.length, [...older.apply]], [0, [K]]);
});

test("JUDGE-marks: the mark is L@t and parses back", async () => {
  const { formatMark, parseMark } = await load();
  assert.deepEqual(parseMark(formatMark({ L: 7, t: 1_793_000_000_123 })), { L: 7, t: 1_793_000_000_123 });
  assert.equal(parseMark("garbage"), null);
  assert.equal(parseMark(null), null);
});

test("JUDGE-addition-over-tombstone: a login new to the ledger, under a key the folder holds as deleted, goes out after the tombstone", async () => {
  const j = await setup({ ledger: null, local: "renamed", record: null, modified: 100 });
  assert.deepEqual(j.claims.map((c) => [c.v?.p, c.afterRecord]), [["renamed", at(3_000)]]);
});

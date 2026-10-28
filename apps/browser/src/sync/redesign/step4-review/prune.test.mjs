import assert from "node:assert/strict";
import { test } from "node:test";
import { fixedBy } from "../switchOn.mjs";

const host = await import("../../journalHost.ts");
const { unionFallback } = await import("../../editJournal.ts");
const DAY = 86_400_000;
const now = 1_800_000_000_000;
const base = { extractedThisCycle: true, localHas: false, localIgnored: false, now };

test("PRUNE-when: a seen key is pruned only once its local item is gone and its record is gone or a tombstone past 90 days", fixedBy("step 4"), () => {
  assert.equal(host.prunableSeen({ ...base, record: undefined }), true, "record collected, local gone");
  assert.equal(host.prunableSeen({ ...base, record: { v: null, wall: now - 91 * DAY } }), true, "tombstone past the hold");
  assert.equal(host.prunableSeen({ ...base, record: { v: null, wall: now - 30 * DAY } }), false, "tombstone inside the hold");
  assert.equal(host.prunableSeen({ ...base, record: { v: 1, wall: now - 400 * DAY } }), false, "a live record");
  assert.equal(host.prunableSeen({ ...base, localHas: true, record: undefined }), false, "the local item is still there");
});

test("PRUNE-complete: 'the local item is gone' counts only from a complete extraction run this cycle", fixedBy("step 4"), () => {
  assert.equal(host.prunableSeen({ ...base, extractedThisCycle: false, record: undefined }), false, "no extraction this cycle (skipped by a gate or a hold)");
  assert.equal(host.prunableSeen({ ...base, localIgnored: true, record: undefined }), false, "the extraction ignores the key, so it says nothing about it");
});

test("PRUNE-revived: a pruned key is exactly a never-seen key: no origin, not in the saved anchor, and the fallback treats a revived record the same", fixedBy("step 4"), async () => {
  const shell = await import("../../../test-native/index.ts");
  shell.docs.clear();
  host.forgetEditJournal();
  host.editJournal();
  host.noteSeen("app", "set:gone", ["B", 3]);
  host.noteSeen("app", "set:kept", ["B", 4]);
  host.pruneSeen("app", (key) => key === "set:gone");
  assert.equal(host.seenOrigin("app", "set:gone"), undefined);
  assert.deepEqual(Object.keys(host.journalAnchor().everSeen.scopes.app), ["set:kept"]);
  const everSeen = new Set(Object.keys(host.journalAnchor().everSeen.scopes.app));
  const input = (seen) => ({ scope: "app", T: 5000, vvT: { app: { B: 3 } }, local: new Map([["set:gone", 1]]), records: new Map(), everSeen: seen, tombstoned: new Set() });
  const afterPrune = unionFallback(input(everSeen));
  const neverSeen = unionFallback(input(new Set(["set:kept"])));
  assert.deepEqual([[...afterPrune.publish.keys()], [...afterPrune.apply]], [[...neverSeen.publish.keys()], [...neverSeen.apply]]);
});

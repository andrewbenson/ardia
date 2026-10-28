import assert from "node:assert/strict";
import { test } from "node:test";

const load = () => import("../editJournal.ts");

function disk(files = {}) {
  const docs = new Map(Object.entries(files));
  const order = [];
  return {
    docs,
    order,
    read: (name) => docs.get(name) ?? null,
    write: (name, text) => {
      order.push(name);
      docs.set(name, text);
    },
  };
}

const h = (ms, device = "dev1") => `${ms.toString(36).padStart(9, "0")}.0000.${device}`;

test("JOURNAL-order: an edit writes sync-edits.json before sync-edits.gen, synchronously, with the same g", async () => {
  const { openJournal } = await load();
  const d = disk();
  const j = openJournal(d, { storeG: 0 });
  j.record("p:1", "bm:a", { v: { t: "A" }, h: h(1000), seen: null });
  assert.deepEqual(d.order, ["sync-edits.json", "sync-edits.gen"]);
  assert.equal(JSON.parse(d.docs.get("sync-edits.json")).g, JSON.parse(d.docs.get("sync-edits.gen")).g);
  assert.equal(j.g, 1);
});

test("JOURNAL-reopen: a reopened journal has its entries and g", async () => {
  const { openJournal } = await load();
  const d = disk();
  const j = openJournal(d, { storeG: 0 });
  j.record("p:1", "bm:a", { v: { t: "A" }, h: h(1000), seen: null });
  const again = openJournal(d, { storeG: 1 });
  assert.equal(again.lost, false);
  assert.deepEqual(again.entry("p:1", "bm:a"), { v: { t: "A" }, h: h(1000), seen: null });
});

test("JOURNAL-gen-alone: a gen doc rolled back alone leaves the journal valid, and the gen doc is rewritten", async () => {
  const { openJournal } = await load();
  const d = disk();
  const j = openJournal(d, { storeG: 0 });
  j.record("p:1", "bm:a", { v: 1, h: h(1000), seen: null });
  const oldGen = d.docs.get("sync-edits.gen");
  j.record("p:1", "bm:b", { v: 2, h: h(2000), seen: null });
  j.record("p:1", "bm:c", { v: 3, h: h(3000), seen: null });
  d.docs.set("sync-edits.gen", oldGen);
  const again = openJournal(d, { storeG: 3 });
  assert.equal(again.lost, false);
  assert.equal(JSON.parse(d.docs.get("sync-edits.gen")).g, 3);
});

test("JOURNAL-missing-gen: no gen doc with a readable journal is valid", async () => {
  const { openJournal } = await load();
  const d = disk();
  openJournal(d, { storeG: 0 }).record("p:1", "bm:a", { v: 1, h: h(1000), seen: null });
  d.docs.delete("sync-edits.gen");
  assert.equal(openJournal(d, { storeG: 1 }).lost, false);
});

test("JOURNAL-behind-gen: a journal whose g is below the gen doc's is lost", async () => {
  const { openJournal } = await load();
  const d = disk();
  const j = openJournal(d, { storeG: 0 });
  j.record("p:1", "bm:a", { v: 1, h: h(1000), seen: null });
  j.inStepAt(1500, { "p:1": { dev1: 1 } });
  const oldJournal = d.docs.get("sync-edits.json");
  j.record("p:1", "bm:b", { v: 2, h: h(2000), seen: null });
  d.docs.set("sync-edits.json", oldJournal);
  const again = openJournal(d, { storeG: 2, storeT: 1500 });
  assert.equal(again.lost, true);
  assert.equal(again.fallback, "union");
  assert.equal(openJournal(d, { storeG: 2, storeT: 1000 }).fallback, "nothing", "a store saved before T gets no union");
});

test("JOURNAL-behind-store: the journal and gen doc rolled back together, under a store that reflects a later g, are lost", async () => {
  const { openJournal } = await load();
  const d = disk();
  const j = openJournal(d, { storeG: 0 });
  j.record("p:1", "bm:a", { v: 1, h: h(1000), seen: null });
  const both = [d.docs.get("sync-edits.json"), d.docs.get("sync-edits.gen")];
  j.record("p:1", "bm:b", { v: 2, h: h(2000), seen: null });
  d.docs.set("sync-edits.json", both[0]);
  d.docs.set("sync-edits.gen", both[1]);
  assert.equal(openJournal(d, { storeG: 2 }).lost, true);
});

test("JOURNAL-unreadable: an unreadable journal is lost; with no gen doc there's no union fallback", async () => {
  const { openJournal } = await load();
  const withGen = disk({ "sync-edits.json": "{not json", "sync-edits.gen": JSON.stringify({ v: 1, g: 4, T: 5000, vv: { "p:1": { dev1: 3 } } }) });
  const a = openJournal(withGen, { storeG: 4, storeT: 5000 });
  assert.deepEqual([a.lost, a.fallback], [true, "union"]);
  assert.deepEqual(a.inStep, { T: 5000, vv: { "p:1": { dev1: 3 } } });
  const noGen = disk({ "sync-edits.json": "{not json" });
  const b = openJournal(noGen, { storeG: 4 });
  assert.deepEqual([b.lost, b.fallback], [true, "nothing"]);
});

test("JOURNAL-fresh: no journal, no gen doc and a store at g 0 is a fresh journal, not a lost one", async () => {
  const { openJournal } = await load();
  const j = openJournal(disk(), { storeG: 0 });
  assert.equal(j.lost, false);
  assert.equal(j.g, 0);
});

test("JOURNAL-clear: an entry clears only for its own h; a newer edit's entry stays", async () => {
  const { openJournal } = await load();
  const d = disk();
  const j = openJournal(d, { storeG: 0 });
  j.record("p:1", "bm:a", { v: 1, h: h(1000), seen: null });
  j.record("p:1", "bm:a", { v: 2, h: h(2000), seen: null });
  j.clear("p:1", "bm:a", h(1000));
  assert.equal(j.entry("p:1", "bm:a")?.v, 2);
  j.clear("p:1", "bm:a", h(2000));
  assert.equal(j.entry("p:1", "bm:a"), undefined);
});

test("JOURNAL-in-step: the last in-step time and its version vectors go to the gen doc", async () => {
  const { openJournal } = await load();
  const d = disk();
  const j = openJournal(d, { storeG: 0 });
  j.inStepAt(7000, { "p:1": { dev1: 2, dev2: 5 } });
  assert.deepEqual(JSON.parse(d.docs.get("sync-edits.gen")).vv, { "p:1": { dev1: 2, dev2: 5 } });
  assert.equal(JSON.parse(d.docs.get("sync-edits.gen")).T, 7000);
});

test("FALLBACK-union: after a lost journal a local difference is published only where vv(T) covers the record's origin", async () => {
  const { unionFallback } = await load();
  const vvT = { "p:1": { dev1: 3, dev2: 4 } };
  const out = unionFallback({
    scope: "p:1",
    T: 5000,
    vvT,
    local: new Map([["bm:covered", 1], ["bm:late", 2], ["bm:new", 3], ["bm:seenGone", 4], ["bm:same", 5]]),
    records: new Map([
      ["bm:covered", { v: 0, o: ["dev2", 4] }],
      ["bm:late", { v: 0, o: ["dev2", 6] }],
      ["bm:same", { v: 5, o: ["dev2", 1] }],
    ]),
    everSeen: new Set(["bm:seenGone"]),
    tombstoned: new Set(),
  });
  assert.deepEqual(Object.fromEntries([...out.publish].map(([k, e]) => [k, e.at])), { "bm:covered": 5000, "bm:new": 5000 });
  assert.deepEqual([...out.apply].sort(), ["bm:late", "bm:seenGone"]);
  assert.equal(out.publishDeletions, false);
});

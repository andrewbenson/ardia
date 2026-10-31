import assert from "node:assert/strict";
import { test } from "node:test";
const { emptyScope } = await import("@solara/sync");
const d = await import("./stateDeltas.ts");

const clone = (x) => JSON.parse(JSON.stringify(x));

test("a delta carries only what changed, and replaying it over the last write gives the state", () => {
  const scopes = { app: { ...emptyScope(), records: { a: { h: "1", v: 1, o: ["x", 1] }, b: { h: "1", v: 2, o: ["x", 1] } }, base: { a: "1", b: "2" } } };
  const disk = clone(scopes);
  const written = d.writtenOf(scopes);
  assert.deepEqual(d.deltaOf(scopes, written), { whole: false, delta: null }, "nothing changed, nothing written");
  scopes.app.records.a = { h: "2", v: 3, o: ["x", 2] };
  delete scopes.app.records.b;
  delete scopes.app.base.b;
  scopes.app.records.c = { h: "3", v: 4, o: ["x", 3] };
  scopes.app.seq = 7;
  const result = d.deltaOf(scopes, written);
  assert.equal(result.whole, false);
  assert.deepEqual(Object.keys(result.delta.app.records).sort(), ["a", "c"]);
  assert.deepEqual(result.delta.app["~gone"], { records: ["b"], base: ["b"] });
  assert.ok(d.applyDelta(disk, clone(result.delta)));
  assert.deepEqual(disk, clone(scopes));
});

test("adding, removing or replacing a scope needs a full write", () => {
  const scopes = { app: emptyScope() };
  const written = d.writtenOf(scopes);
  assert.equal(d.deltaOf({ ...scopes, "p:x": emptyScope() }, written).whole, true);
  assert.equal(d.deltaOf({}, written).whole, true);
  assert.equal(d.deltaOf({ app: emptyScope() }, written).whole, true);
});

test("a malformed delta, or one for a scope that isn't there, applies nothing", () => {
  const scopes = { app: emptyScope() };
  const before = clone(scopes);
  for (const bad of [null, [], { app: 1 }, { other: { records: {}, base: {}, files: {} } }, { app: { records: {}, base: {} } }, { app: { records: {}, base: {}, files: {}, "~gone": { records: [1] } } }]) {
    assert.equal(d.applyDelta(scopes, bad), false, JSON.stringify(bad));
    assert.deepEqual(scopes, before);
  }
});

test("names round-trip, and a name that isn't ours parses as null", () => {
  const name = { device: "ABC234", n: 3, epoch: "0a1b", g: 12 };
  assert.deepEqual(d.parseDeltaName(d.deltaName(name)), name);
  assert.equal(d.deltaPart(name), "d.ABC234.3.0a1b.12");
  assert.deepEqual(d.parseBatchName(d.batchName("p:Ünï", 4)), { scope: "p:Ünï", seq: 4 });
  for (const other of ["sync-state.nns", "sync-state-d-ABC-1-0a-1.nns.sb-1-x", "sync-journal-b-zz-1.nns", "sync-journal-b-6-1.nns"]) {
    assert.equal(d.parseDeltaName(other) ?? d.parseBatchName(other), null, other);
  }
});

test("a long list of keys is written as what left and what joined, and a reorder writes it whole", () => {
  const keys = Array.from({ length: 100 }, (_, i) => `h:${i}`);
  const scopes = { app: { ...emptyScope(), unapplied: [...keys] } };
  const disk = clone(scopes);
  let written = d.writtenOf(scopes);
  scopes.app.unapplied = [...keys.filter((k) => k !== "h:5"), "h:new"];
  const edit = d.deltaOf(scopes, written).delta.app.unapplied;
  assert.deepEqual(edit, { "~list": { drop: ["h:5"], add: ["h:new"] } });
  assert.ok(d.applyDelta(disk, clone(d.deltaOf(scopes, written).delta)));
  assert.deepEqual(disk, clone(scopes));
  written = d.writtenOf(scopes);
  scopes.app.unapplied = [...scopes.app.unapplied].reverse();
  const whole = d.deltaOf(scopes, written).delta.app.unapplied;
  assert.deepEqual(whole, scopes.app.unapplied);
  assert.ok(d.applyDelta(disk, clone(d.deltaOf(scopes, written).delta)));
  assert.deepEqual(disk, clone(scopes));
  assert.equal(d.applyDelta({ app: { ...emptyScope(), unapplied: 7 } }, { app: { records: {}, base: {}, files: {}, unapplied: { "~list": { drop: [], add: ["x"] } } } }), false, "a list edit over something that isn't a list is refused");
});

test("names and epochs use only what Hermes has", async () => {
  const { readFile } = await import("node:fs/promises");
  const source = await readFile(new URL("./stateDeltas.ts", import.meta.url), "utf8");
  for (const missing of ["crypto", "TextEncoder", "TextDecoder"]) assert.ok(!source.includes(missing), `stateDeltas.ts uses ${missing}`);
  const epoch = d.newEpoch();
  assert.ok(epoch.match(/^[0-9a-f]{32}$/));
  assert.notEqual(epoch, d.newEpoch());
  for (const scope of ["app", "p:Ünï-☃"]) assert.deepEqual(d.parseBatchName(d.batchName(scope, 12)), { scope, seq: 12 });
});

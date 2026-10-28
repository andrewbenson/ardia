#!/usr/bin/env node
import { writeFileSync } from "node:fs";
import { deflateRawSync } from "node:zlib";
import { pinSources } from "../../../../packages/sync/scripts/pinSources.mjs";

const HELP = `usage: node apps/browser/scripts/native/stateCases.mjs [--out <file>] [--runs <n>] [--seed <n>]

Records the engine's validating decode of saved sync state (readable.ts: readableScope, readableBatch,
readableRebuild, readableRecord, readableOp) on seeded random scope states, each valid or broken in one
place (a missing seq, a field of the wrong type, a bad record, op, journal batch, held outbox or rebuild),
with engine-only and unknown keys mixed in. SolaraSyncTests replays each value through StateDecode.swift
and must give the same verdicts.
Default out: native/SolaraKit/Tests/SolaraSyncTests/Cases/state.json.deflate.`;

const args = process.argv.slice(2);
if (args.includes("--help")) {
  console.log(HELP);
  process.exit(0);
}
const option = (name, fallback) => {
  const at = args.indexOf(name);
  return at < 0 ? fallback : args[at + 1];
};
const root = new URL("../../../../", import.meta.url);
const readable = await import(new URL("apps/browser/src/sync/readable.ts", root).href);
const out = option("--out", new URL("native/SolaraKit/Tests/SolaraSyncTests/Cases/state.json.deflate", root).pathname);
const runs = Number(option("--runs", "3000"));
const firstSeed = Number(option("--seed", "1"));

function mulberry32(seed) {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function randomState(seed) {
  const rand = mulberry32(seed);
  const pick = (list) => list[Math.floor(rand() * list.length)];
  const h = () => `000${Math.floor(rand() * 1e6)}.0000.dev${Math.floor(rand() * 3)}`;
  const op = () => ({ k: pick(["x:1", "pw:a\nb", "set:t"]), h: h(), v: pick([1, null, { a: 1 }]) });
  const batch = () => ({ v: 1, kind: "log", device: "dev1", seq: 1 + Math.floor(rand() * 9), at: 1, ops: [op(), op()] });
  const state = {
    records: { "x:1": { h: h(), v: 1, o: ["dev1", 2] }, "x:2": { h: h(), v: null, o: ["dev2", 1] }, "x:Ünï🔑": { h: h(), v: "🔑", o: ["dévice", 1] } },
    base: { "x:1": "1", "x:Ünï🔑": "\"🔑\"" },
    unapplied: ["x:3"],
    vv: { dev1: 2 },
    extra: { dev2: [4, 6] },
    files: { f1: { d: "dev1", k: "log", s: 1, at: 5 } },
    damaged: { f9: 3 },
    seq: 3,
    outbox: [op()],
    seen: { dev1: 7 },
    joined: true,
    snapshotAt: 0,
    pending: 0,
  };
  if (rand() < 0.4) state.journal = [batch()];
  if (rand() < 0.3) state.heldOutbox = [op()];
  if (rand() < 0.3) state.rebuild = { since: 5, ...(rand() < 0.5 ? { settled: ["pw:"] } : {}), ...(rand() < 0.5 ? { noted: { "pw:": { "pw:a\nb": "4.abc" } } } : {}) };
  if (rand() < 0.3) state.rebuildBaseline = { anything: [1, 2] };
  if (rand() < 0.3) state.pendingSince = { f2: 9 };
  if (rand() < 0.2) state.somethingNewer = { kept: true };
  const breaks = [
    () => delete state.seq,
    () => (state.seq = "3"),
    () => (state.records = []),
    () => (state.records["x:1"].o = ["dev1", "2"]),
    () => delete state.records["x:2"].h,
    () => (state.base["x:1"] = 1),
    () => (state.vv.dev1 = null),
    () => (state.seen = null),
    () => (state.damaged.f9 = "3"),
    () => (state.extra.dev2 = [4, "6"]),
    () => (state.extra.dev2 = 4),
    () => (state.files.f1 = 1),
    () => (state.unapplied = ["x:3", 4]),
    () => delete state.unapplied,
    () => (state.outbox = [{ k: "x:1" }]),
    () => (state.journal = [{ ...batch(), seq: "1" }]),
    () => (state.journal = { not: "a list" }),
    () => (state.journal = [{ ...batch(), ops: [{ h: "x" }] }]),
    () => (state.heldOutbox = [{ k: 1, h: "x" }]),
    () => (state.rebuild = []),
    () => (state.rebuild = { since: 1, settled: [1] }),
    () => (state.rebuild = { since: 1, noted: { "pw:": { k: 1 } } }),
    () => (state.rebuild = { since: 1, noted: [] }),
    () => (state.records = { "x:1": null }),
  ];
  if (rand() < 0.6) pick(breaks)();
  if (rand() < 0.05) return pick([null, [], "state", 3]);
  return state;
}

export function verdicts(value) {
  const isObject = readable.isObject(value);
  return {
    scope: readable.readableScope(value),
    batch: readable.readableBatch(isObject && Array.isArray(value.journal) ? value.journal[0] : value),
    rebuild: readable.readableRebuild(isObject ? value.rebuild : value),
    record: readable.readableRecord(isObject && readable.isObject(value.records) ? Object.values(value.records)[0] : value),
    op: readable.readableOp(isObject && Array.isArray(value.outbox) ? value.outbox[0] : value),
  };
}

if (process.argv[1] === new URL(import.meta.url).pathname) {
  const cases = Array.from({ length: runs }, (_, i) => {
    const value = randomState(firstSeed + i);
    return { value, verdicts: verdicts(value) };
  });
  const text = JSON.stringify({ cases });
  writeFileSync(out, deflateRawSync(Buffer.from(text)));
  if (!option("--out", null)) pinSources("Cases/state.json.deflate", ["apps/browser/src/sync/readable.ts"]);
  const ok = cases.filter((c) => c.verdicts.scope).length;
  console.log(`${cases.length} state cases, ${ok} readable, ${cases.length - ok} rejected`);
}

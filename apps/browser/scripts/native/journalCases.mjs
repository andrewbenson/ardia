#!/usr/bin/env node
import { writeFileSync } from "node:fs";
import { deflateRawSync } from "node:zlib";
import { pinSources } from "../../../../packages/sync/scripts/pinSources.mjs";

const HELP = `usage: node apps/browser/scripts/native/journalCases.mjs [--out <file>] [--runs <n>] [--seed <n>]

Records the edit journal (editJournal.ts) on seeded random scripts: what sync-edits.json and sync-edits.gen
hold at open (missing, unreadable, the wrong shape, behind or ahead of each other and of the store), the
store's journalG and journalT, then records, clears and in-step points. After the open and after every call
it writes down what the journal reports (lost, fallback, inStep, g, lastInStepT, entries) and every document
it wrote, in order. It also records unionFallback on random inputs. SolaraSyncTests replays each case through
EditJournal.swift and must produce the same output, byte for byte.
Default out: native/SolaraKit/Tests/SolaraSyncTests/Cases/journal.json.deflate.`;

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
const journal = await import(new URL("apps/browser/src/sync/editJournal.ts", root).href);
const out = option("--out", new URL("native/SolaraKit/Tests/SolaraSyncTests/Cases/journal.json.deflate", root).pathname);
const runs = Number(option("--runs", "1500"));
const firstSeed = Number(option("--seed", "1"));

function mulberry32(seed) {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const hlc = (wall, counter, device) => `${wall.toString(36).padStart(9, "0")}.${counter.toString(36).padStart(4, "0")}.${device}`;

export function randomScript(seed) {
  const rand = mulberry32(seed);
  const pick = (list) => list[Math.floor(rand() * list.length)];
  const T = 1_790_000_000_000;
  const scopes = ["app", "p:abc", "10"];
  const keys = ["set:theme", "pin:1", "2", "bm:é", "bm:🔑Ünï"];
  const g = () => pick([0, 1, 2, 3, 5, 8]);
  const time = () => T + pick([0, 1, -1, 1000, -1000, 60_000]);
  const entry = () => ({ v: pick([{ v: "dark" }, null, 1, { b: 1, a: [2] }, { v: "Ünï 🔑" }]), h: hlc(time(), Math.floor(rand() * 3), pick(["dev1", "dev2"])), seen: pick([null, "[\"B\",1]"]) });
  const vectors = () => (rand() < 0.2 ? {} : { [pick(scopes)]: { [pick(["B", "C"])]: Math.floor(rand() * 4) } });
  const journalDoc = () => {
    const entries = {};
    for (const scope of scopes) if (rand() < 0.4) entries[scope] = Object.fromEntries(keys.filter(() => rand() < 0.5).map((k) => [k, entry()]));
    const doc = { v: 1, g: g(), newest: rand() < 0.5 ? null : hlc(time(), 0, "dev1"), entries };
    if (rand() < 0.2) doc.extra = "kept";
    return JSON.stringify(doc);
  };
  const genDoc = () => {
    const doc = { v: 1, g: g() };
    const t = rand();
    if (t < 0.6) doc.T = time();
    else if (t < 0.85) doc.T = null;
    const v = rand();
    if (v < 0.6) doc.vv = vectors();
    else if (v < 0.85) doc.vv = null;
    return JSON.stringify(doc);
  };
  const docText = (make) => pick([null, null, "{", JSON.stringify({ v: 2, g: 1 }), JSON.stringify([1]), make(), make(), make()]);
  const script = {
    journal: docText(journalDoc),
    gen: docText(genDoc),
    storeG: g(),
    ...(rand() < 0.7 ? { storeT: pick([0, time(), time()]) } : {}),
    probes: scopes.flatMap((s) => keys.map((k) => [s, k])),
    calls: [],
  };
  const live = [];
  for (let i = 0; i < 1 + Math.floor(rand() * 8); i++) {
    const r = rand();
    if (r < 0.45) {
      const call = { op: "record", scope: pick(scopes), key: pick(keys), entry: entry() };
      live.push(call);
      script.calls.push(call);
    } else if (r < 0.7) {
      const known = live.length && rand() < 0.7 ? pick(live) : null;
      script.calls.push({ op: "clear", scope: known?.scope ?? pick(scopes), key: known?.key ?? pick(keys), h: known && rand() < 0.8 ? known.entry.h : hlc(time(), 0, "dev3") });
    } else script.calls.push({ op: "inStepAt", at: time() + pick([0, -5000, 5000]), vv: vectors() });
  }
  return script;
}

export function runScript(script) {
  const docs = new Map();
  if (script.journal !== null) docs.set(journal.JOURNAL_DOC, script.journal);
  if (script.gen !== null) docs.set(journal.GEN_DOC, script.gen);
  let writes = [];
  const disk = { read: (name) => docs.get(name) ?? null, write: (name, text) => (docs.set(name, text), writes.push([name, text])) };
  const j = journal.openJournal(disk, "storeT" in script ? { storeG: script.storeG, storeT: script.storeT } : { storeG: script.storeG });
  const scopes = [...new Set(script.probes.map(([s]) => s))];
  const report = () => {
    const state = {
      lost: j.lost,
      fallback: j.fallback,
      inStep: j.inStep,
      g: j.g,
      lastInStepT: j.lastInStepT,
      probes: script.probes.map(([s, k]) => j.entry(s, k) ?? null),
      entries: scopes.map((s) => j.entries(s)),
      writes,
    };
    writes = [];
    return state;
  };
  const steps = [report()];
  for (const call of script.calls) {
    if (call.op === "record") j.record(call.scope, call.key, call.entry);
    else if (call.op === "clear") j.clear(call.scope, call.key, call.h);
    else j.inStepAt(call.at, call.vv);
    steps.push(report());
  }
  return steps;
}

export function randomUnion(seed) {
  const rand = mulberry32(seed);
  const pick = (list) => list[Math.floor(rand() * list.length)];
  const keys = ["a", "b", "c", "d", "1", "é", "🔑"];
  const value = () => pick([1, "v", { a: 1, b: 2 }, { b: 2, a: 1 }, null, [1], "Ünï", "🔑"]);
  const local = keys.filter(() => rand() < 0.7).map((k) => [k, value()]);
  const records = keys.filter(() => rand() < 0.6).map((k) => [k, { v: value(), o: [pick(["B", "C"]), Math.floor(rand() * 4)] }]);
  return {
    scope: "app",
    T: 1_790_000_000_000 + Math.floor(rand() * 1000),
    vvT: rand() < 0.2 ? {} : { app: { B: Math.floor(rand() * 4), ...(rand() < 0.5 ? { C: Math.floor(rand() * 4) } : {}) } },
    local,
    records,
    everSeen: keys.filter(() => rand() < 0.3),
    tombstoned: keys.filter(() => rand() < 0.2),
  };
}

export function runUnion(input) {
  const result = journal.unionFallback({
    ...input,
    local: new Map(input.local),
    records: new Map(input.records),
    everSeen: new Set(input.everSeen),
    tombstoned: new Set(input.tombstoned),
  });
  return { publish: [...result.publish], apply: [...result.apply], publishDeletions: result.publishDeletions };
}

if (process.argv[1] === new URL(import.meta.url).pathname) {
  const cases = Array.from({ length: runs }, (_, i) => {
    const script = randomScript(firstSeed + i);
    return { script, steps: runScript(script) };
  });
  const unions = Array.from({ length: runs }, (_, i) => {
    const input = randomUnion(firstSeed + i);
    return { input, output: runUnion(input) };
  });
  const text = JSON.stringify({ cases, unions });
  writeFileSync(out, deflateRawSync(Buffer.from(text)));
  if (!option("--out", null)) pinSources("Cases/journal.json.deflate", ["apps/browser/src/sync/editJournal.ts"]);
  const fallbacks = cases.reduce((m, c) => ((m[c.steps[0].fallback] = (m[c.steps[0].fallback] ?? 0) + 1), m), {});
  console.log(`${cases.length} journal scripts, ${unions.length} union cases, ${(text.length / 1e6).toFixed(1)} MB, fallbacks ${JSON.stringify(fallbacks)}`);
}

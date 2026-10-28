#!/usr/bin/env node
import { writeFileSync } from "node:fs";
import { deflateRawSync } from "node:zlib";
import { pinSources } from "../../../../packages/sync/scripts/pinSources.mjs";

const HELP = `usage: node apps/browser/scripts/native/ledgerCases.mjs [--out <file>] [--runs <n>] [--seed <n>]

Records the password ledger's pure functions (passwordLedger.ts: parseMark, formatMark, digestOf, judge,
nextLedger) on seeded random inputs: local logins, a Login Data mark, a ledger and folder records over a few
keys whose values and digests often coincide, so every branch of judge runs. SolaraSyncTests replays each
case through PasswordLedger.swift and must produce the same output, byte for byte.
Default out: native/SolaraKit/Tests/SolaraSyncTests/Cases/ledger.json.deflate.`;

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
const ledger = await import(new URL("apps/browser/src/sync/passwordLedger.ts", root).href);
const out = option("--out", new URL("native/SolaraKit/Tests/SolaraSyncTests/Cases/ledger.json.deflate", root).pathname);
const runs = Number(option("--runs", "2000"));
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

export function randomCase(seed) {
  const rand = mulberry32(seed);
  const pick = (list) => list[Math.floor(rand() * list.length)];
  const T = 1_790_000_000_000;
  const keys = ["pw:https://a.example\nme", "pw:https://b.example\nyou", "pw:https://c.example\n", "pw:https://ü.example\nü", "pw:https://a.example\njos\u00e9", "pw:https://a.example\njose\u0301"];
  const values = [
    { o: "https://a.example", u: "me", s: "one" },
    { o: "https://a.example", u: "me", s: "two" },
    { o: "https://b.example", u: "you", s: "pässwörd" },
    { o: "https://c.example", u: "", s: "🔑" },
    { o: "https://a.example", u: "me", s: "" },
    { o: "https://a.example", u: "jos\u00e9", s: "caf\u00e9" },
    { o: "https://a.example", u: "jose\u0301", s: "cafe\u0301" },
  ];
  const times = [];
  const time = () => {
    const t = times.length && rand() < 0.3 ? pick(times) : T + Math.floor((rand() - 0.5) * 2 * 3_600_000);
    times.push(t);
    return t;
  };
  const local = [];
  const records = [];
  for (const key of keys) {
    if (rand() < 0.7) local.push([key, { value: pick(values), modified: time() }]);
    if (rand() < 0.7) records.push([key, { v: rand() < 0.2 ? null : pick(values), h: hlc(time(), Math.floor(rand() * 3), pick(["dev1", "dev2"])) }]);
  }
  const markL = Math.floor(rand() * 5);
  const markT = time();
  const mark = rand() < 0.3 ? null : { L: markL, t: markT };
  let ledgerValue = null;
  if (rand() < 0.7) {
    const consistent = mark && rand() < 0.6;
    const entries = {};
    for (const key of keys) {
      if (rand() < 0.3) continue;
      const digests = [];
      const count = 1 + Math.floor(rand() * 4);
      for (let i = 0; i < count; i++) {
        const from = pick(["local", "record", "value", "junk"]);
        const localValue = local.find(([k]) => k === key)?.[1].value;
        const recordValue = records.find(([k]) => k === key)?.[1].v;
        digests.push(from === "local" ? ledger.digestOf(localValue) : from === "record" ? ledger.digestOf(recordValue) : from === "value" ? ledger.digestOf(pick(values)) : `${i}.junk`);
      }
      entries[key] = { d: digests, h: rand() < 0.3 ? null : hlc(time(), 0, "dev1"), m: time(), ...(rand() < 0.2 ? { later: { kept: true } } : {}) };
    }
    ledgerValue = { v: 1, L: consistent ? mark.L : Math.floor(rand() * 5), t: consistent ? mark.t : time(), keys: entries };
  }
  const now = time();
  const nextKeys = keys.filter(() => rand() < 0.6);
  const nextMark = { L: markL + 1, t: now };
  return { local, mark, ledger: ledgerValue, records, now, nextKeys, nextMark };
}

export function evaluate(input) {
  const local = new Map(input.local);
  const records = new Map(input.records);
  const judged = ledger.judge(local, input.mark, input.ledger, records, input.now);
  const next = ledger.nextLedger(input.ledger, local, records, input.nextMark, input.nextKeys);
  const markText = input.mark ? ledger.formatMark(input.mark) : "";
  return {
    judge: { mode: judged.mode, claims: judged.claims, apply: [...judged.apply], seed: [...judged.seed] },
    next,
    digests: input.local.map(([, l]) => ledger.digestOf(l.value)),
    mark: { text: markText, parsed: ledger.parseMark(markText), junk: ledger.parseMark(`${markText}x`) },
  };
}

if (process.argv[1] === new URL(import.meta.url).pathname) {
  const cases = Array.from({ length: runs }, (_, i) => {
    const input = randomCase(firstSeed + i);
    return { input, output: evaluate(input) };
  });
  const text = JSON.stringify({ cases });
  writeFileSync(out, deflateRawSync(Buffer.from(text)));
  if (!option("--out", null)) pinSources("Cases/ledger.json.deflate", ["apps/browser/src/sync/passwordLedger.ts"]);
  const modes = cases.reduce((m, c) => ((m[c.output.judge.mode] = (m[c.output.judge.mode] ?? 0) + 1), m), {});
  console.log(`${cases.length} ledger cases, ${(text.length / 1e6).toFixed(1)} MB, modes ${JSON.stringify(modes)}`);
}

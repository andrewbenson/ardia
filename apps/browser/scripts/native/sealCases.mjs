#!/usr/bin/env node
import { writeFileSync } from "node:fs";
import { deflateRawSync } from "node:zlib";
import { pinSources } from "../../../../packages/sync/scripts/pinSources.mjs";

const HELP = `usage: node apps/browser/scripts/native/sealCases.mjs [--out <file>] [--runs <n>] [--seed <n>]

Records what JS makes of a password value's text, for the native code that converts {o, u, p} and {o, u, s}
in place: each random string as JSON.stringify writes it (astral and control characters, "/", quotes,
backslashes, U+2028), the canonical text of {o, u, p} and {o, u, s} as scope.ts's canonical() writes it, the
engine's noted digest of each (notes.ts: digest(choice(v))) and the ledger's digest of the plain value
(passwordLedger.ts: digestOf). ArdiaSyncCore's tests replay every case and must write the same bytes.
Default out: packages/sync/tests/fixtures/seal-cases.json.deflate.`;

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
const { canonical } = await import(new URL("packages/sync/src/canon.ts", root).href);
const { choice, digest } = await import(new URL("apps/browser/src/sync/notes.ts", root).href);
const { digestOf } = await import(new URL("apps/browser/src/sync/passwordLedger.ts", root).href);
const out = option("--out", new URL("packages/sync/tests/fixtures/seal-cases.json.deflate", root).pathname);
const runs = Number(option("--runs", "4000"));
const firstSeed = Number(option("--seed", "1"));

function mulberry32(seed) {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function randomCase(seed) {
  const rand = mulberry32(seed);
  const pick = (list) => list[Math.floor(rand() * list.length)];
  const pieces = ["a", "Z", "0", "/", "\\", '"', "'", " ", "\n", "\t", "\r", "\b", "\f", "\u0000", "\u0001", "\u001f", "\u007f", "é", "e\u0301", "Ünï", "😀", "🔑", " ", " ", "﻿", "https://", "s1.", "p:", "{}", "[]", "€", "中"];
  const text = (max) => Array.from({ length: Math.floor(rand() * max) }, () => pick(pieces)).join("");
  const o = pick(["https://a.example", "http://ü.example:8080", "https://xn--n3h.example", `https://${text(3) || "x"}.example`]);
  const u = text(6);
  const p = text(10);
  const s = `AQ${text(8)}==`;
  return { o, u, p, s, extra: text(12) };
}

export function evaluate({ o, u, p, s, extra }) {
  const plain = { o, u, p };
  const sealed = { o, u, s };
  return {
    strings: [o, u, p, s, extra].map((t) => JSON.stringify(t)),
    canonicalPlain: canonical(plain),
    canonicalSealed: canonical(sealed),
    notedPlain: digest(choice(plain)),
    notedSealed: digest(choice(sealed)),
    ledgerPlain: digestOf({ o, u, s: p }),
  };
}

if (process.argv[1] === new URL(import.meta.url).pathname) {
  const cases = Array.from({ length: runs }, (_, i) => {
    const input = randomCase(firstSeed + i);
    const units = Object.fromEntries(Object.entries(input).map(([k, v]) => [k, [...v].flatMap((c) => [...Array(c.length)].map((_, j) => c.charCodeAt(j)))]));
    return { input, units, output: evaluate(input) };
  });
  const text = JSON.stringify({ cases });
  writeFileSync(out, deflateRawSync(Buffer.from(text)));
  if (!option("--out", null)) pinSources("seal-cases", ["packages/sync/src/canon.ts", "apps/browser/src/sync/notes.ts", "apps/browser/src/sync/passwordLedger.ts"]);
  console.log(`${cases.length} seal cases, ${(text.length / 1e6).toFixed(1)} MB`);
}

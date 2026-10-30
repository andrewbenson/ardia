const HELP = `Times one omnibox keystroke in packages/core (node, V8) and captures a workload for Swift.

  node native/SolaraKit/Scripts/omnibox-bench.mts [--rounds 300] [--seed-in <file>] [--seed-out <file>]

The workload is suggest-hermes.mjs's source extraction: 5,000 default-profile history rows, all 1,000
bookmark URL nodes (including 100 work-profile nodes), 158 default-profile tabs, command-bar actions,
and per key a findScope over known hosts plus buildSuggestions. The Hermes script uses 200 tabs and its
own clock, so it is an unmatched diagnostic. This bench types "github.com/net" and "react native perf"
one key at a time, 5 warm-up passes, then --rounds timed passes. Every prefix and target, plus all keys
combined, reports mean, median and p95. --keys remains accepted; prefix summaries are always printed.
--seed-out captures profile, actions, hosts, fixed now and Node answers. --seed-in replays that file
without rebuilding the seed or changing its clock and checks every Node answer before timing. Compare
the printed seed SHA-256 on every run. Then, from native/SolaraKit:

  SOLARA_OMNIBOX_BENCH=<file> swift test -c release -Xswiftc -enable-testing --filter OmniboxBench

Node's V8 is not Hermes: the app's JS runs on Hermes, which is slower.`;

import { deepStrictEqual, ok } from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { performance } from "node:perf_hooks";
import { BUILT_IN_ENGINES } from "../../../packages/core/src/engines.ts";
import { hostOf } from "../../../packages/core/src/omnibox.ts";
import { findScope } from "../../../packages/core/src/siteSearch.ts";
import { buildSuggestions, prepareSuggestions, type CommandAction, type SuggestionResult, type SuggestionSource } from "../../../packages/core/src/suggest.ts";
import { buildSeed } from "../../../apps/browser/scripts/perf/seed.mjs";

const args = process.argv.slice(2);
if (args.includes("-h") || args.includes("--help")) {
  console.log(HELP);
  process.exit(0);
}
const flag = (name: string, fallback: string) => {
  const index = args.indexOf(`--${name}`);
  if (index < 0) return fallback;
  const value = args[index + 1];
  if (!value || value.startsWith("--")) throw new Error(`--${name} needs a value`);
  return value;
};
const rounds = Number(flag("rounds", "300"));
ok(Number.isSafeInteger(rounds) && rounds > 0, "--rounds must be a positive integer");
const here = dirname(fileURLToPath(import.meta.url));
const targets = ["github.com/net", "react native perf"];
const prefixes = targets.flatMap(q => Array.from({ length: q.length }, (_, i) => q.slice(0, i + 1)));
type Workload = SuggestionSource & { bookmarks: NonNullable<SuggestionSource["bookmarks"]>; now: number; actions: CommandAction[]; hosts: string[]; expect: Record<string, SuggestionResult> };

const capture = (): Workload => {
  const seed = buildSeed("http://127.0.0.1:47817");
  const history = seed["history.json"].history.default.map((h: { url: string; title: string; favicon: string | null; visits: number; lastVisit: number }) => ({ url: h.url, title: h.title, favicon: h.favicon, visits: h.visits, lastVisit: h.lastVisit }));
  const tabs = seed["session.json"].tabs.filter((t: { profileId: string }) => t.profileId === "default").map((t: { id: string; url: string; title: string; favicon: string | null }) => ({ id: t.id, url: t.url, title: t.title, favicon: t.favicon }));
  const bookmarks: { url: string; title: string; favicon: string | null }[] = [];
  for (const n of Object.values(seed["bookmarks.json"].bookmarks.nodes) as { kind: string; url: string; title: string; favicon: string | null }[]) {
    if (n.kind === "url") bookmarks.push({ url: n.url, title: n.title, favicon: n.favicon });
  }
  const actions = JSON.parse(readFileSync(join(here, "../../../apps/browser/scripts/perf/bar-actions.json"), "utf8"));
  const seen = new Set<string>();
  const hosts: string[] = tabs.map((t: { url: string }) => hostOf(t.url));
  for (const h of history) seen.add(hostOf(h.url));
  seen.delete("");
  hosts.push(...seen);
  return { now: Date.now(), history, tabs, bookmarks, actions, hosts, expect: {} };
};

const seedIn = flag("seed-in", "");
let seedBytes = seedIn ? readFileSync(seedIn) : undefined;
const workload: Workload = seedBytes ? JSON.parse(seedBytes.toString("utf8")) : capture();
ok(workload && Number.isFinite(workload.now), "seed needs a finite fixed now");
for (const key of ["history", "tabs", "bookmarks", "actions", "hosts"] as const) ok(Array.isArray(workload[key]), `seed needs ${key}`);
ok(workload.expect && typeof workload.expect === "object", "seed needs Node expected answers");
const { now, history, tabs, bookmarks, actions, hosts } = workload;
const source = { tabs, history, bookmarks };
const keystroke = (q: string) => {
  findScope(q, { engines: BUILT_IN_ENGINES, hosts });
  return buildSuggestions(q, source, { now, actions });
};

let t0 = performance.now();
prepareSuggestions(source, Infinity);
console.log(`node ${process.version}: prepare (cold) ${(performance.now() - t0).toFixed(1)} ms; ${history.length} history, ${bookmarks.length} bookmarks, ${tabs.length} tabs, ${hosts.length} hosts`);
for (const q of prefixes) {
  const answer = keystroke(q);
  if (seedIn) {
    ok(Object.hasOwn(workload.expect, q), `seed is missing Node answer for ${JSON.stringify(q)}`);
    deepStrictEqual(answer, workload.expect[q], `captured Node answer differs for ${JSON.stringify(q)}`);
  } else {
    workload.expect[q] = answer;
  }
}
seedBytes ??= Buffer.from(JSON.stringify(workload));
const seedOut = flag("seed-out", "");
if (seedOut) writeFileSync(seedOut, seedBytes);
console.log(`seed sha256 ${createHash("sha256").update(seedBytes).digest("hex")}; rounds ${rounds}; warmups 5`);

const pct = (sorted: number[], p: number) => sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))]!;
const summary = (label: string, samples: number[]) => {
  const sorted = [...samples].sort((a, b) => a - b);
  const mean = sorted.reduce((a, b) => a + b, 0) / sorted.length;
  console.log(`${label}: n ${sorted.length}, mean ${mean.toFixed(0)} µs, median ${pct(sorted, 0.5).toFixed(0)} µs, p95 ${pct(sorted, 0.95).toFixed(0)} µs per key`);
};
const overall: number[] = [];
for (const q of targets) {
  for (let w = 0; w < 5; w++) for (let i = 1; i <= q.length; i++) keystroke(q.slice(0, i));
  const samples: number[] = [];
  const perKey: number[][] = Array.from({ length: q.length }, () => []);
  for (let r = 0; r < rounds; r++) {
    for (let i = 1; i <= q.length; i++) {
      t0 = performance.now();
      keystroke(q.slice(0, i));
      const dt = (performance.now() - t0) * 1000;
      samples.push(dt);
      perKey[i - 1]!.push(dt);
    }
  }
  overall.push(...samples);
  summary(JSON.stringify(q), samples);
  for (const [i, list] of perKey.entries()) summary(`  ${JSON.stringify(q.slice(0, i + 1))}`, list);
}
summary("overall", overall);

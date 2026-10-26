const HELP = `Times one omnibox keystroke in packages/core (node, V8) and writes the workload for the Swift side.

  node native/SolaraKit/Scripts/omnibox-bench.mts [--rounds 300] [--seed-out <file>]

The workload is suggest-hermes.mjs's: the perf seed's default profile (5,000 history rows, 900 bookmarks, its
tabs), the command bar's actions, and per key a findScope over the known hosts plus buildSuggestions. It types
"github.com/net" and "react native perf" one key at a time, 5 warm-up passes, then --rounds timed passes, and
prints the median and p95 per key. --seed-out writes the same profile, actions and hosts as JSON; then

  SOLARA_OMNIBOX_BENCH=<file> swift test -c release -Xswiftc -enable-testing --filter OmniboxBench

times SolaraOmnibox on it. Node's V8 is not Hermes: the app's JS runs on Hermes, which is slower.`;

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { performance } from "node:perf_hooks";
import { BUILT_IN_ENGINES } from "../../../packages/core/src/engines.ts";
import { hostOf } from "../../../packages/core/src/omnibox.ts";
import { findScope } from "../../../packages/core/src/siteSearch.ts";
import { buildSuggestions, prepareSuggestions } from "../../../packages/core/src/suggest.ts";
import { buildSeed } from "../../../apps/browser/scripts/perf/seed.mjs";

const args = process.argv.slice(2);
if (args.includes("-h") || args.includes("--help")) {
  console.log(HELP);
  process.exit(0);
}
const flag = (name: string, fallback: string) => (args.includes(`--${name}`) ? args[args.indexOf(`--${name}`) + 1]! : fallback);
const rounds = Number(flag("rounds", "300"));
const here = dirname(fileURLToPath(import.meta.url));

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
const now = Date.now();
const source = { tabs, history, bookmarks };

const seedOut = flag("seed-out", "");
if (seedOut) {
  const expect: Record<string, unknown> = {};
  for (const q of ["github.com/net", "react native perf"]) for (let i = 1; i <= q.length; i++) expect[q.slice(0, i)] = buildSuggestions(q.slice(0, i), source, { now, actions });
  writeFileSync(seedOut, JSON.stringify({ now, history, tabs, bookmarks, actions, hosts, expect }));
}

const keystroke = (q: string) => {
  findScope(q, { engines: BUILT_IN_ENGINES, hosts });
  return buildSuggestions(q, source, { now, actions });
};

let t0 = performance.now();
prepareSuggestions(source, Infinity);
console.log(`node ${process.version}: prepare (cold) ${(performance.now() - t0).toFixed(1)} ms; ${history.length} history, ${bookmarks.length} bookmarks, ${tabs.length} tabs, ${hosts.length} hosts`);

const pct = (sorted: number[], p: number) => sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))]!;
for (const q of ["github.com/net", "react native perf"]) {
  for (let w = 0; w < 5; w++) for (let i = 1; i <= q.length; i++) keystroke(q.slice(0, i));
  const samples: number[] = [];
  const perKey: number[][] = Array.from({ length: q.length }, () => []);
  for (let r = 0; r < rounds; r++) {
    for (let i = 1; i <= q.length; i++) {
      t0 = performance.now();
      keystroke(q.slice(0, i));
      const dt = performance.now() - t0;
      samples.push(dt);
      perKey[i - 1]!.push(dt);
    }
  }
  samples.sort((a, b) => a - b);
  const mean = samples.reduce((a, b) => a + b, 0) / samples.length;
  console.log(`${JSON.stringify(q)}: mean ${(mean * 1000).toFixed(0)} µs, median ${(pct(samples, 0.5) * 1000).toFixed(0)} µs, p95 ${(pct(samples, 0.95) * 1000).toFixed(0)} µs per key`);
  if (args.includes("--keys")) {
    for (const [i, list] of perKey.entries()) {
      list.sort((a, b) => a - b);
      console.log(`  ${JSON.stringify(q.slice(0, i + 1))} median ${(pct(list, 0.5) * 1000).toFixed(0)} µs`);
    }
  }
}

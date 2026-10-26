#!/usr/bin/env node
// Groups acsample.c's scenario-mode samples (main-thread stacks taken inside run-loop iterations of 50 ms or more)
// by the code they ran: Chrome, React Native / Hermes, the app's own code, or the system.
//
//   node apps/browser/scripts/perf/stall-samples.mjs [--symbols <Chromium Framework (dSYM DWARF file)>] [--app-dsym <the app's dSYM DWARF file>]
//        [--windows <kept.json>] [--top <n>] [--json <file>] <dir>...
//
// Each <dir> is searched for acsample-stalls.txt (one per instance's data folder; native-baseline.mjs passes the
// bench's --out). A sample counts for the first image, from the leaf up, that isn't the system's, so time in
// malloc called from Chrome is Chrome's. React Native, Yoga, Folly and Expo are static pods linked into the app's
// executable, so its frames are told apart by symbol name: "react" is RCT…, facebook::react/yoga, YG…, folly::, EX…
// and Expo…; "hermes" is hermes:: and facebook::hermes; the rest is "app". Release builds are stripped, so pass
// --app-dsym (the .app.dSYM next to the build) or those frames count as "app". Without --symbols, Chromium frames
// show as offsets. --windows lists the [scenario, from ms, to ms] windows to keep (the bench's reps that passed their
// check); iterations that start outside them are left out.
import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";

const { values: o, positionals: dirs } = parseArgs({
  allowPositionals: true,
  options: { symbols: { type: "string" }, "app-dsym": { type: "string" }, windows: { type: "string" }, top: { type: "string", default: "8" }, json: { type: "string" }, help: { type: "boolean", short: "h" } },
});
if (o.help || !dirs.length) {
  const lines = readFileSync(new URL(import.meta.url), "utf8").split("\n").slice(1);
  console.log(lines.slice(0, lines.findIndex((l) => !l.startsWith("//"))).map((l) => l.replace(/^\/\/ ?/, "")).join("\n"));
  process.exit(o.help ? 0 : 64);
}

function find(dir, out = []) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    let st;
    try {
      st = statSync(p);
    } catch {
      continue;
    }
    if (st.isDirectory()) find(p, out);
    else if (name === "acsample-stalls.txt") out.push(p);
  }
  return out;
}

const isExecutable = (file) => !!file && /\.app\/Contents\/MacOS\/[^/]+$/.test(file);
function byName(name) {
  if (/hermes::|facebook::hermes|\bhermes_|HermesRuntime/.test(name)) return "hermes";
  if (/RCT|facebook::(react|yoga|jsi)|\bYG[A-Z]|folly::|\[EX[A-Z]|\bEX[A-Z]|Expo|\bReact\b|ReactNative/.test(name)) return "react";
  return "app";
}
function category(file, name) {
  if (!file) return "system";
  if (isExecutable(file)) return byName(name ?? "");
  if (file.endsWith("/Chromium Framework") || file.includes("Chromium Framework.framework")) return "chrome";
  if (/hermes/i.test(file)) return "hermes";
  if (/\/(React|RCT|RN|Yoga|yoga|Expo|ExpoModulesCore)[^/]*$/.test(file) || /React[^/]*\.framework/.test(file)) return "react";
  if (file.includes(".app/Contents/")) return "app";
  return "system";
}

function parse(text) {
  const sym = new Map();
  const iterations = [];
  let current = null;
  for (const line of text.split("\n")) {
    if (line.startsWith("sym ")) {
      const [head, name] = line.split("\t");
      const [, pc, base, ...file] = head.split(" ");
      sym.set(pc, { base: parseInt(base, 16), file: file.join(" "), name: name ?? "?" });
    } else if (line.startsWith("it ")) {
      const [scenario, rest] = line.slice(3).split("\t");
      const [start, dur, n, dropped, open] = rest.split(" ").map(Number);
      current = { scenario, startMs: start / 1000, durMs: dur / 1000, dropped, open: !!open, samples: [] };
      iterations.push(current);
    } else if (line.startsWith("s ") && current) {
      const [, t, state, ...pcs] = line.split(" ");
      current.samples.push({ t: +t / 1000, state: +state, pcs });
    }
  }
  return { sym, iterations };
}

const files = dirs.flatMap((d) => (existsSync(d) ? find(d) : []));
if (!files.length) {
  console.error(`stall-samples: no acsample-stalls.txt under ${dirs.join(", ")}`);
  process.exit(1);
}
const kept = o.windows ? JSON.parse(readFileSync(o.windows, "utf8")) : null;
const inKept = (it) => !kept || kept.some(([scenario, from, to]) => scenario === it.scenario && it.startMs >= from - 1 && it.startMs <= to);
const parsed = files.map((f) => parse(readFileSync(f, "utf8"))).map((p) => ({ ...p, iterations: p.iterations.filter(inKept) }));

const exeNames = new Map();
if (o["app-dsym"]) {
  for (const p of parsed) {
    const byBase = new Map();
    for (const [pc, sy] of p.sym) if (isExecutable(sy.file)) (byBase.get(sy.base) ?? byBase.set(sy.base, []).get(sy.base)).push(pc);
    for (const [base, pcs] of byBase)
      for (let i = 0; i < pcs.length; i += 4000) {
        const chunk = pcs.slice(i, i + 4000);
        const lines = execFileSync("atos", ["-o", o["app-dsym"], "-l", "0x" + base.toString(16), ...chunk.map((pc) => "0x" + (parseInt(pc, 16) - 1).toString(16))], { encoding: "utf8", maxBuffer: 256 << 20 }).split("\n");
        chunk.forEach((pc, k) => exeNames.set(`${base}:${pc}`, (lines[k] ?? "?").replace(/ \(in [^)]*\).*$/, "").slice(0, 120)));
      }
  }
}
const exeName = (sy, pc) => exeNames.get(`${sy.base}:${pc}`) ?? sy.name;

const chromeNames = new Map();
if (o.symbols) {
  const offsets = new Set();
  for (const p of parsed) for (const [pc, s] of p.sym) if (category(s.file) === "chrome") offsets.add(parseInt(pc, 16) - s.base - 1);
  const list = [...offsets];
  for (let i = 0; i < list.length; i += 4000) {
    const chunk = list.slice(i, i + 4000);
    const lines = execFileSync("atos", ["-o", o.symbols, "-l", "0x0", ...chunk.map((x) => "0x" + x.toString(16))], { encoding: "utf8", maxBuffer: 256 << 20 }).split("\n");
    chunk.forEach((x, k) => chromeNames.set(x, (lines[k] ?? "?").replace(/ \(in [^)]*\).*$/, "").slice(0, 120)));
  }
}

const CATEGORIES = ["chrome", "hermes", "react", "app", "system"];
const byScenario = new Map();
for (const p of parsed) {
  const nameOf = (pc) => {
    const s = p.sym.get(pc);
    if (!s) return "?";
    if (category(s.file) === "chrome") return chromeNames.get(parseInt(pc, 16) - s.base - 1) ?? `Chromium Framework+0x${(parseInt(pc, 16) - s.base).toString(16)}`;
    return `${isExecutable(s.file) ? exeName(s, pc) : s.name} [${s.file.split("/").pop()}]`;
  };
  for (const it of p.iterations) {
    let row = byScenario.get(it.scenario);
    if (!row) byScenario.set(it.scenario, (row = { scenario: it.scenario, iterations: 0, ms: 0, samples: 0, open: 0, dropped: 0, by: Object.fromEntries(CATEGORIES.map((c) => [c, 0])), top: Object.fromEntries(CATEGORIES.map((c) => [c, new Map()])) }));
    row.iterations++;
    row.ms += it.durMs;
    row.open += it.open ? 1 : 0;
    row.dropped += it.dropped;
    for (const s of it.samples) {
      row.samples++;
      let cat = "system", at = s.pcs[0];
      for (const pc of s.pcs) {
        const sy = p.sym.get(pc);
        const c = category(sy?.file, sy && isExecutable(sy.file) ? exeName(sy, pc) : sy?.name);
        if (c !== "system") {
          cat = c;
          at = pc;
          break;
        }
      }
      row.by[cat]++;
      const name = nameOf(at);
      row.top[cat].set(name, (row.top[cat].get(name) ?? 0) + 1);
    }
  }
}

const report = [...byScenario.values()].map((r) => ({
  scenario: r.scenario,
  iterations: r.iterations,
  stalledMs: Math.round(r.ms),
  samples: r.samples,
  stillOpenAtEnd: r.open,
  samplesDropped: r.dropped,
  share: Object.fromEntries(CATEGORIES.map((c) => [c, r.samples ? r.by[c] / r.samples : 0])),
  top: Object.fromEntries(CATEGORIES.map((c) => [c, [...r.top[c]].sort((a, b) => b[1] - a[1]).slice(0, +o.top)])),
}));
console.log(`${files.length} file(s), ${report.reduce((n, r) => n + r.iterations, 0)} iterations of 50 ms or more\n`);
console.log(`| Scenario | Iterations ≥ 50 ms | Stalled ms | Samples | ${CATEGORIES.map((c) => c[0].toUpperCase() + c.slice(1)).join(" | ")} |`);
console.log(`|---|---|---|---|${CATEGORIES.map(() => "---").join("|")}|`);
for (const r of report) console.log(`| ${r.scenario} | ${r.iterations} | ${r.stalledMs} | ${r.samples} | ${CATEGORIES.map((c) => `${Math.round(r.share[c] * 100)}%`).join(" | ")} |`);
for (const r of report) {
  console.log(`\n${r.scenario}:`);
  for (const c of CATEGORIES) if (r.top[c].length) console.log(`  ${c}: ${r.top[c].map(([n, k]) => `${n} (${k})`).join("; ")}`);
}
if (o.json) writeFileSync(o.json, JSON.stringify(report, null, 1));

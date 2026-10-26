#!/usr/bin/env node
// Phase 0 of the native move (docs/native/baseline.md): the measurement baseline of a shipped build, run phase by phase
// under the perflab lock, then rendered as docs/native/baseline-<version>.md.
//
//   node apps/browser/scripts/perf/native-baseline.mjs --app <dist/<v>/export/X.app> --out <dir> [options]
//     --port <n>              CDP port of every instance (default 9481); tab-actions uses <n>+1, its pages <n>+2
//     --label <name>          the app's name in the results (default: native-bench's, the folder two levels up)
//     --control <app>         a previous stable, interleaved run by run with --app in every phase that supports it
//     --control-label <name>  the control's name (default as --label)
//     --js-commit <sha>       the commit the build's JS came from (required unless --bundle). native-bench drives an app
//                             through its own bundle, bench-entry.js: the app's index.js plus the command channel, which
//                             the embedded main.jsbundle doesn't have. The js phase exports <sha> with `git archive` into
//                             <out>/js/<sha> (never the working tree), installs its packages offline under the pod lock,
//                             builds the app's production bundle there and compares it with the build's embedded
//                             main.jsbundle (bytes, else the sets of strings), then builds the bench bundle from the same
//                             export. tab-actions runs each build's embedded main.jsbundle itself
//     --control-js-commit <sha> the same for --control
//     --bundle <file>         a bench bundle built elsewhere from the build's JS (instead of --js-commit)
//     --control-bundle <file> the control's bench bundle, when its NATIVE_API_VERSION differs
//     --version <v>           the version in the report's name (default: the app's CFBundleShortVersionString)
//     --only <a,b>            phases (default: all but drag), in this order:
//                               js          the bench bundles from each build's commit (see --js-commit); not timed
//                               prepare     signed copies with the bench bundle (native-bench --only prepare)
//                               netcheck    one journeys run per build with telemetry sharing on, the instances' sockets
//                                           listed every 0.5 s: it fails if any connects to ardia.dev's addresses or if
//                                           the journeys guard wasn't answered by bench-offline.js; not timed
//                               launch      M7 warm: 8 launches, one tab then the seed
//                               coldlaunch  M7 cold: 6 launches from fresh APFS clones, one tab then the seed
//                               journeys    M2, M3, J4: ⌘T, keystroke → suggestions, Enter → page (seed, 10 × 3 runs)
//                               tabactions  M1, M2: tab-actions.mjs, 4 launches × 5 of click, ⌃Tab, ⌘number, ⌘T, ⌘W,
//                                           the row's ✕, pin and unpin, on the app's own JS bundle
//                               frames      M4, M6: the frame rig with the stall histogram (idle 60 s, then each interaction)
//                               framecounts M6 attribution, M9: the same interactions with counts, acsample.c armed per
//                                           window; stall-samples.mjs groups the long iterations' stacks by image
//                               session     idle CPU and wakeups at 1 and 20 tabs, memory at 1/10/20 tabs, new window
//                               memslope    M8: memory per window, k = 1..4 New Tab windows on the seed, slope
//                               suggest     M3 compute: suggest-hermes.mjs (Hermes), omnibox-bench.mts (node V8) and
//                                           SolaraOmnibox's OmniboxBench (release); run after the lock is given back,
//                                           under its own
//                               drag        M5: real HID drags of a visible window (acperf postdrag). Only with --drag:
//                                           it moves the pointer and needs the owner's go-ahead. Without it the M5 rows
//                                           say "needs owner run"
//     --drag                  allow the drag phase (adds it to the default list)
//     --locked-ok             start even with the screen locked or the display asleep: the phases that need display-link
//                             frames (journeys, tabactions, frames, framecounts, drag) are left out and listed in the report
//     --runs <n>              runs of journeys, frames, framecounts, session and memslope (default 3)
//     --symbols <file>        Chromium Framework's DWARF file, for stall-samples.mjs's names
//     --resume                skip phases whose results are already in <out>/baseline.json
//     --report                render the report from <out>/baseline.json without running anything
//     --md <file>             where the report goes (default docs/native/baseline-<version>.md)
//     --keep                  keep <out> (default: removed after the report, except baseline.json and the report)
//     --who <name>            the perflab lock's holder name (default native-baseline)
//
// Conditions it checks: the display awake and unlocked (macOS gives no display-link frames otherwise), caffeinate -d for
// the whole run, the load average and seconds of HID input recorded per phase. It notes other processes of the same
// executable name (the owner's app, never touched); native-bench refuses to launch while one of its own copies runs.
// Hidden instances only (ARDIA_BACKGROUND=1, scratch data folders), except --drag.
import { execFileSync, spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { loadavg, tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "../../../..");
const { values: opt } = parseArgs({
  options: {
    app: { type: "string" },
    out: { type: "string", default: join(tmpdir(), "ac-native-baseline") },
    port: { type: "string", default: "9481" },
    control: { type: "string" },
    label: { type: "string" },
    "control-label": { type: "string" },
    "locked-ok": { type: "boolean" },
    bundle: { type: "string" },
    "js-commit": { type: "string" },
    "control-js-commit": { type: "string" },
    "control-bundle": { type: "string" },
    version: { type: "string" },
    only: { type: "string" },
    drag: { type: "boolean" },
    runs: { type: "string", default: "3" },
    symbols: { type: "string" },
    resume: { type: "boolean" },
    report: { type: "boolean" },
    md: { type: "string" },
    keep: { type: "boolean" },
    who: { type: "string", default: "native-baseline" },
    help: { type: "boolean", short: "h" },
  },
});
if (opt.help) {
  const lines = readFileSync(fileURLToPath(import.meta.url), "utf8").split("\n").slice(1);
  console.log(lines.slice(0, lines.findIndex((l) => !l.startsWith("//"))).map((l) => l.replace(/^\/\/ ?/, "")).join("\n"));
  process.exit(0);
}

const PHASES = ["js", "prepare", "netcheck", "launch", "coldlaunch", "journeys", "tabactions", "frames", "framecounts", "session", "memslope", "suggest", "drag"];
const NEEDS_DISPLAY = new Set(["journeys", "tabactions", "frames", "framecounts", "drag"]);
const LOCKED = new Set(["prepare", "netcheck", "launch", "coldlaunch", "journeys", "tabactions", "frames", "framecounts", "session", "memslope", "drag"]);
const out = resolve(opt.out);
const stateFile = join(out, "baseline.json");
const log = (...a) => console.error(`[baseline ${new Date().toISOString().slice(11, 19)}]`, ...a);
const fail = (message) => {
  console.error(message);
  process.exit(64);
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const port = +opt.port;
const runs = String(+opt.runs);

const toolDir = join(out, ".tools");
function tool(name, src, build) {
  const bin = join(toolDir, name);
  const text = readFileSync(join(here, src), "utf8");
  if (!existsSync(bin) || !existsSync(bin + ".src") || readFileSync(bin + ".src", "utf8") !== text) {
    mkdirSync(toolDir, { recursive: true });
    execFileSync(build[0], [...build.slice(1), join(here, src), "-o", bin], { stdio: "inherit" });
    if (name.endsWith(".dylib")) execFileSync("codesign", ["--force", "--sign", "-", bin]);
    writeFileSync(bin + ".src", text);
  }
  return bin;
}
const acperfBin = () => tool("acperf", "acperf.swift", ["swiftc", "-O"]);
const acsampleLib = () => tool("acsample.dylib", "acsample.c", ["clang", "-dynamiclib", "-arch", "arm64", "-framework", "CoreFoundation"]);
const acperf = (...args) => {
  const r = spawnSync(acperfBin(), args, { encoding: "utf8", timeout: 600_000 });
  return { code: r.status, out: (r.stdout ?? "").trim() };
};

const plist = (app, key) => execFileSync("defaults", ["read", join(resolve(app), "Contents/Info.plist"), key], { encoding: "utf8" }).trim();

function loadState() {
  if (!existsSync(stateFile)) return { meta: {}, phases: {} };
  return JSON.parse(readFileSync(stateFile, "utf8"));
}
const state = loadState();
const save = () => writeFileSync(stateFile, JSON.stringify(state, null, 1));

function machine() {
  const disp = JSON.parse(acperf("display").out || "{}");
  return { load: loadavg().map((x) => Math.round(x * 10) / 10), display: disp, at: new Date().toISOString() };
}

class ConnectionWatch {
  constructor(every = 2000) {
    this.seen = new Map();
    this.samples = 0;
    this.ardia = new Set();
    for (const type of ["A", "AAAA"]) {
      const r = spawnSync("dig", ["+short", type, "ardia.dev"], { encoding: "utf8", timeout: 5000 });
      for (const ip of (r.stdout ?? "").split("\n").map((l) => l.trim()).filter((l) => /^[\d.:a-f]+$/i.test(l))) this.ardia.add(ip);
    }
    this.timer = setInterval(() => this.sample(), every);
  }
  sample() {
    const ps = spawnSync("ps", ["-ax", "-o", "pid=", "-o", "command="], { encoding: "utf8", maxBuffer: 64 << 20 });
    const pids = (ps.stdout ?? "").split("\n").map((l) => /^\s*(\d+)\s+(.*)$/.exec(l)).filter((m) => m && m[2].includes(out)).map((m) => m[1]);
    if (!pids.length) return;
    this.samples++;
    const r = spawnSync("lsof", ["-nP", "-a", "-i", "-p", pids.join(",")], { encoding: "utf8", maxBuffer: 64 << 20, timeout: 10_000 });
    for (const line of (r.stdout ?? "").split("\n").slice(1)) {
      const remote = /->(\S+)/.exec(line)?.[1];
      if (!remote || /^(127\.0\.0\.1|\[::1\]|localhost)[:\]]/.test(remote)) continue;
      const ip = remote.replace(/^\[/, "").replace(/\]?:\d+$/, "");
      this.seen.set(remote, { count: (this.seen.get(remote)?.count ?? 0) + 1, ardia: this.ardia.has(ip) });
    }
  }
  stop() {
    clearInterval(this.timer);
    const remotes = [...this.seen].map(([remote, v]) => ({ remote, ...v }));
    return { samples: this.samples, ardiaAddresses: [...this.ardia], toArdia: remotes.filter((r) => r.ardia).length, remotes };
  }
}

class InputWatch {
  constructor() {
    this.secs = 0;
    this.timer = setInterval(() => {
      const ns = +acperf("hididle").out;
      if (Number.isFinite(ns) && ns < 2.5e9) this.secs += 2;
    }, 2000);
  }
  stop() {
    clearInterval(this.timer);
    return this.secs;
  }
}

function run(cmd, args, { locked = false, cwd = repoRoot, env = {}, log: file } = {}) {
  const full = locked ? [join(repoRoot, "scripts/agent/locked"), "perflab", "--as", opt.who, "--wait", "500", "--", cmd, ...args] : [cmd, ...args];
  log(`$ ${full.slice(locked ? 7 : 0).join(" ")}`);
  return new Promise((done, failed) => {
    const child = spawn(full[0], full.slice(1), { cwd, env: { ...process.env, ...env }, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "", stderr = "";
    child.stdout.on("data", (d) => ((stdout += d), process.stdout.write(d)));
    child.stderr.on("data", (d) => ((stderr += d), process.stderr.write(d)));
    child.on("error", failed);
    child.on("close", (code) => {
      if (file) writeFileSync(file, stdout + (stderr ? `\n--- stderr\n${stderr}` : ""));
      code === 0 ? done(stdout) : failed(new Error(`${basename(cmd)} ${args[0] ?? ""} exited ${code}`));
    });
  });
}

let dragPid = 0;
const journeyCopies = () => {
  if (!state.meta.preparedJourneys?.app) throw new Error("no journeys copies (prepare makes them, with --telemetry-sink): rerun --only prepare");
  return state.meta.preparedJourneys;
};
const nb = join(here, "native-bench.mjs");
const labelOfPrepared = (path) => basename(dirname(dirname(path)));
function dsymOf(app) {
  const name = plist(app, "CFBundleExecutable");
  for (const bundle of [`${app}.dSYM`, join(dirname(dirname(app)), `${basename(app, ".app")}.xcarchive`, "dSYMs", `${basename(app)}.dSYM`)]) {
    const file = join(bundle, "Contents/Resources/DWARF", name);
    if (existsSync(file)) return file;
  }
  return null;
}
function originalOf(label) {
  const p = state.meta.prepared ?? {};
  if (p.app && labelOfPrepared(p.app) === label) return state.meta.app;
  if (p.control && labelOfPrepared(p.control) === label) return state.meta.control;
  return null;
}
const node = process.execPath;
const TELEMETRY_SINK = "https://bench-telemetry.invalid/v1/logs";
const preparedArgs = (copies = state.meta.prepared) => [
  "--app", copies.app, "--prepared", "--port", String(port),
  ...(copies.control ? ["--control", copies.control] : []),
];
const benchResults = (dir) => {
  const found = {};
  for (const label of readdirSync(dir)) {
    const f = join(dir, label, "results.json");
    if (existsSync(f)) found[label] = JSON.parse(readFileSync(f, "utf8"));
  }
  return found;
};
async function bench(phase, args, { copies, ...extra } = {}) {
  const dir = join(out, phase);
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  let failure = null;
  try {
    await run(node, [nb, "--out", dir, ...preparedArgs(copies), ...args], { locked: true, log: join(dir, "stdout.txt"), ...extra });
  } catch (error) {
    failure = error;
  }
  const results = benchResults(dir);
  const errors = Object.entries(results).flatMap(([label, r]) => (r.errors ?? []).map((e) => `${label} run ${e.run}: ${e.error}`));
  if (failure && !Object.keys(results).length) throw failure;
  const kept = Object.values(results).reduce((n, r) => n + ["launch", "session", "windows", "memslope", "journeys", "frames"].reduce((k, key) => k + (r[key]?.length ?? 0), 0), 0);
  if (!kept) throw new Error(`${phase}: every run failed (${errors.join("; ").slice(0, 400) || failure?.message})`);
  if (failure || errors.length) partial.push(`${phase}: ${errors.length ? errors.join("; ") : failure.message}`.slice(0, 600));
  return results;
}
let partial = [];

const phases = {
  async js() {
    const sides = [[opt.app, opt["js-commit"], opt.bundle, "app"], ...(opt.control ? [[opt.control, opt["control-js-commit"], opt["control-bundle"], "control"]] : [])];
    const made = {};
    for (const [app, sha, given, role] of sides) {
      if (given) {
        made[role] = { bundle: resolve(given), commit: null, check: "given with --bundle; not checked" };
        continue;
      }
      if (!sha) throw new Error(`the ${role} needs --${role === "app" ? "" : "control-"}js-commit <the commit its JS came from> (or a bundle)`);
      const commit = execFileSync("git", ["rev-parse", "--verify", `${sha}^{commit}`], { cwd: repoRoot, encoding: "utf8" }).trim();
      const dir = join(out, "js", commit.slice(0, 12));
      if (!existsSync(join(dir, "node_modules"))) {
        rmSync(dir, { recursive: true, force: true });
        mkdirSync(dir, { recursive: true });
        execFileSync("sh", ["-c", `git -C '${repoRoot}' archive --format=tar ${commit} | tar -x -C '${dir}'`]);
        await run(join(repoRoot, "scripts/agent/locked"), ["pod", "--wait", "500", "--", "pnpm", "install", "--offline", "--frozen-lockfile", "--ignore-scripts"], { cwd: dir });
      }
      const appDir = join(dir, "apps/browser");
      const hermesc = join(repoRoot, "apps/browser/macos/Pods/hermes-engine/destroot/bin/hermesc");
      const bundle = async (entry, name) => {
        const js = join(dir, `${name}.js`), hbc = join(dir, `${name}.jsbundle`);
        await run(node, [join(dir, "node_modules/react-native-macos/scripts/bundle.js"), "bundle", "--entry-file", entry, "--platform", "macos", "--dev", "false",
          "--reset-cache", "--minify", "false", "--bundle-output", js, "--assets-dest", join(dir, `${name}-assets`),
          "--config-cmd", `'${node}' '${join(dir, "node_modules/react-native-macos/cli.js")}' config`], { cwd: appDir });
        execFileSync(hermesc, ["-emit-binary", "-max-diagnostic-width=80", "-O", "-out", hbc, js], { stdio: "inherit" });
        return hbc;
      };
      const appBundle = await bundle("index.js", "app");
      const embedded = join(resolve(app), "Contents/Resources/main.jsbundle");
      const same = readFileSync(appBundle).equals(readFileSync(embedded));
      const stringsOf = (f) => new Set(execFileSync("strings", ["-n", "10", f], { encoding: "utf8", maxBuffer: 256 << 20 }).split("\n"));
      const a = stringsOf(appBundle), b = stringsOf(embedded);
      const onlyExport = [...a].filter((x) => !b.has(x)), onlyBuild = [...b].filter((x) => !a.has(x));
      const check = { bytesEqual: same, strings: a.size, onlyInExport: onlyExport.length, onlyInBuild: onlyBuild.length, sampleOnlyInExport: onlyExport.slice(0, 5), sampleOnlyInBuild: onlyBuild.slice(0, 5) };
      log(`js ${role} ${commit.slice(0, 8)}: ${same ? "byte-identical to the build's main.jsbundle" : `${onlyExport.length} strings only in the export, ${onlyBuild.length} only in the build`}`);
      if (!same && (onlyExport.length > 20 || onlyBuild.length > 20))
        throw new Error(`the ${role}'s JS at ${commit.slice(0, 8)} isn't what ${app} embeds (${onlyExport.length} strings only in the export, ${onlyBuild.length} only in the build, e.g. ${JSON.stringify(onlyBuild.slice(0, 3))})`);
      made[role] = { bundle: await bundle("scripts/perf/bench-entry.js", "bench"), commit, check };
    }
    state.meta.bundles = made;
    return made;
  },
  async prepare() {
    const bundles = state.meta.bundles ?? {};
    if (!bundles.app) throw new Error("no bench bundle: run the js phase first");
    if (opt.control && !bundles.control) throw new Error("no bench bundle for the control: run the js phase first");
    const dir = join(out, "prepare");
    const said = await run(node, [nb, "--out", dir, "--app", resolve(opt.app), "--only", "prepare", "--port", String(port),
      ...(opt.label ? ["--label", opt.label] : []), ...(opt["control-label"] ? ["--control-label", opt["control-label"]] : []),
      "--bundle", bundles.app.bundle,
      ...(opt.control ? ["--control", resolve(opt.control), "--control-bundle", bundles.control.bundle] : [])]);
    const apps = [...said.matchAll(/^prepared (.+?) \(rerun/gm)].map((m) => m[1]);
    if (!apps.length) throw new Error("native-bench prepare named no copies");
    state.meta.prepared = { app: apps[0], control: apps[1] ?? null };
    const jdir = join(out, "prepare-journeys");
    const jsaid = await run(node, [nb, "--out", jdir, "--app", resolve(opt.app), "--only", "prepare", "--port", String(port), "--telemetry-sink", TELEMETRY_SINK,
      ...(opt.label ? ["--label", opt.label] : []), ...(opt["control-label"] ? ["--control-label", opt["control-label"]] : []),
      "--bundle", bundles.app.bundle, ...(opt.control ? ["--control", resolve(opt.control), "--control-bundle", bundles.control.bundle] : [])]);
    const japps = [...jsaid.matchAll(/^prepared (.+?) \(rerun/gm)].map((m) => m[1]);
    state.meta.preparedJourneys = { app: japps[0], control: japps[1] ?? null };
    const pre = await bench("preflight", ["--only", "launch", "--launch-runs", "1"]);
    for (const [label, r] of Object.entries(pre)) {
      const ok = (r.launch ?? []).some((x) => Number.isFinite(x.js));
      if (!ok || r.errors?.length) throw new Error(`preflight on ${label} failed (a native API skew answers every command with an error): ${JSON.stringify(r.errors ?? r.launch).slice(0, 400)}`);
    }
    return { copies: apps, bundles };
  },
  async netcheck() {
    const watch = new ConnectionWatch(500);
    let results, net;
    try {
      results = await bench("netcheck", ["--only", "newtabkey", "--runs", "1", "--journey-n", "2", "--seed", "big"], { copies: journeyCopies() });
    } finally {
      net = watch.stop();
    }
    const guards = Object.fromEntries(Object.entries(results).map(([label, r]) => [label, (r.journeys ?? []).map((j) => j.guard)]));
    for (const [label, g] of Object.entries(guards))
      if (!g.length || g.some((x) => x?.blocked !== "1")) throw new Error(`netcheck ${label}: the journeys guard wasn't answered by bench-offline.js: ${JSON.stringify(g)}`);
    if (net.toArdia) throw new Error(`netcheck: ${net.toArdia} socket(s) to ardia.dev's addresses: ${JSON.stringify(net.remotes.filter((r) => r.ardia))}`);
    if (!net.samples) throw new Error("netcheck: the socket sampler never saw an instance");
    return { net, guards };
  },
  async launch() {
    return {
      oneTab: await bench("launch-onetab", ["--only", "launch", "--launch-runs", "8"]),
      seed: await bench("launch-seed", ["--only", "launch", "--launch-runs", "8", "--seed", "big"]),
    };
  },
  async coldlaunch() {
    return {
      oneTab: await bench("coldlaunch-onetab", ["--only", "launch", "--launch-runs", "6", "--fresh-copy"]),
      seed: await bench("coldlaunch-seed", ["--only", "launch", "--launch-runs", "6", "--fresh-copy", "--seed", "big"]),
    };
  },
  async journeys() {
    return bench("journeys", ["--only", "newtabkey,navigate", "--journey-n", "10", "--runs", runs, "--seed", "big"], { copies: journeyCopies() });
  },
  async tabactions() {
    const dir = join(out, "tabactions");
    rmSync(dir, { recursive: true, force: true });
    const app = resolve(opt.app);
    const label = labelOfPrepared(state.meta.prepared.app);
    const sides = ["--side", `${label}=${join(app, "Contents/Resources/main.jsbundle")}`];
    if (opt.control) sides.push("--side", `${labelOfPrepared(state.meta.prepared.control)}=${join(resolve(opt.control), "Contents/Resources/main.jsbundle")}`, "--side-app", `${labelOfPrepared(state.meta.prepared.control)}=${resolve(opt.control)}`);
    await run(node, [join(here, "tab-actions.mjs"), "run", "--app", app, ...sides, "--launches", "4", "--n", "5",
      "--actions", "click,ctrlTab,cmdNumber,cmdT,cmdW,hoverClose,pin,unpin", "--out", dir, "--port", String(port + 1), "--page-port", String(port + 2)], { locked: true });
    return { samples: readFileSync(join(dir, "samples.jsonl"), "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) };
  },
  async frames() {
    return bench("frames", ["--only", "frames", "--runs", runs, "--frames-stalls"]);
  },
  async framecounts() {
    const results = await bench("framecounts", ["--only", "framecounts", "--runs", runs, "--frames-stalls",
      "--env", "AC_SAMPLE_SCENARIO=1", "--env", `DYLD_INSERT_LIBRARIES=${acsampleLib()}`]);
    const attribution = {};
    for (const label of Object.keys(results)) {
      const json = join(out, "framecounts", label, "stall-samples.json");
      const windows = join(out, "framecounts", label, "kept-windows.json");
      writeFileSync(windows, JSON.stringify((results[label].frames ?? []).flatMap((r) => Object.entries(r.stalls ?? {}).flatMap(([scenario, ws]) => ws.map((w) => [scenario, w.from, w.to])))));
      const original = originalOf(label);
      const dsym = original && dsymOf(original);
      if (!dsym) {
        log(`stall-samples ${label}: NO dSYM for ${original ?? label}; React Native frames inside the executable will count as the app's`);
        partial.push(`framecounts: no dSYM for ${label}, so its attribution can't tell React Native from the app`);
      }
      await run(node, [join(here, "stall-samples.mjs"), ...(opt.symbols ? ["--symbols", opt.symbols] : []), ...(dsym ? ["--app-dsym", dsym] : []),
        "--windows", windows, "--json", json, join(out, "framecounts", label)]).catch((e) => log(`stall-samples ${label}: ${e.message}`));
      if (existsSync(json)) attribution[label] = { symbolized: !!dsym, rows: JSON.parse(readFileSync(json, "utf8")) };
    }
    return { results, attribution };
  },
  async session() {
    return bench("session", ["--only", "idle,memory,newwindow", "--runs", runs]);
  },
  async memslope() {
    return bench("memslope", ["--only", "memslope", "--seed", "big", "--runs", runs, "--mem-windows", "4"]);
  },
  async suggest() {
    const dir = join(out, "suggest");
    mkdirSync(dir, { recursive: true });
    const seed = join(dir, "bench-seed.json");
    const hermes = await run(join(repoRoot, "scripts/agent/locked"), ["perflab", "--wait", "500", "--", node, join(here, "suggest-hermes.mjs"), "--rounds", "300"],
      { env: { SUGGEST_HERMES_DIR: join(dir, "hermes") } });
    const v8 = await run(join(repoRoot, "scripts/agent/locked"), ["perflab", "--wait", "500", "--", node, join(repoRoot, "native/SolaraKit/Scripts/omnibox-bench.mts"), "--seed-out", seed]);
    let swift = "";
    try {
      const kit = join(dir, "kit");
      const native = join(repoRoot, "native/SolaraKit");
      for (const sub of ["Sources/SolaraModel", "Sources/SolaraOmnibox", "Tests/OmniboxBench"]) mkdirSync(join(kit, dirname(sub)), { recursive: true });
      for (const target of ["SolaraModel", "SolaraOmnibox"]) if (!existsSync(join(kit, "Sources", target))) execFileSync("ln", ["-s", join(native, "Sources", target), join(kit, "Sources", target)]);
      mkdirSync(join(kit, "Tests/OmniboxBench"), { recursive: true });
      for (const file of ["OmniboxBench.swift", "FixtureSupport.swift"])
        if (!existsSync(join(kit, "Tests/OmniboxBench", file))) execFileSync("ln", ["-s", join(native, "Tests/SolaraOmniboxTests", file), join(kit, "Tests/OmniboxBench", file)]);
      writeFileSync(join(kit, "Package.swift"), [
        "// swift-tools-version:6.2",
        "import PackageDescription",
        "let package = Package(name: \"OmniboxBenchKit\", platforms: [.macOS(\"26.0\")], targets: [",
        "  .target(name: \"SolaraModel\"), .target(name: \"SolaraOmnibox\", dependencies: [\"SolaraModel\"]),",
        "  .testTarget(name: \"OmniboxBench\", dependencies: [\"SolaraOmnibox\", \"SolaraModel\"]),",
        "], swiftLanguageModes: [.v6])",
        "",
      ].join("\n"));
      await run("swift", ["build", "-c", "release", "-Xswiftc", "-enable-testing", "--build-tests"], { cwd: kit });
      swift = await run(join(repoRoot, "scripts/agent/locked"), ["perflab", "--wait", "500", "--", "swift", "test", "-c", "release", "-Xswiftc", "-enable-testing",
        "--skip-build", "--filter", "OmniboxBench"], { cwd: kit, env: { SOLARA_OMNIBOX_BENCH: seed } });
    } catch (e) {
      log(`OmniboxBench: ${e.message}`);
    }
    return { hermes, v8, swift };
  },
  async drag() {
    if (!opt.drag) throw new Error("the drag phase needs --drag (it moves the real pointer over a visible window)");
    const app = state.meta.prepared.app;
    const data = join(out, "drag", "data");
    rmSync(join(out, "drag"), { recursive: true, force: true });
    mkdirSync(data, { recursive: true });
    writeFileSync(join(data, "onboarding.json"), JSON.stringify({ version: 1, completedAt: 1 }));
    const exe = join(app, "Contents/MacOS", plist(app, "CFBundleExecutable"));
    const pattern = `^${exe.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}( |$)`;
    if (spawnSync("pgrep", ["-f", pattern]).status === 0) throw new Error(`a copy of ${exe} is already running; no drag was posted`);
    const ownerAway = (secs) => {
      const ns = +acperf("hididle").out;
      return Number.isFinite(ns) && ns >= secs * 1e9;
    };
    if (!ownerAway(60)) throw new Error("someone used the mouse or keyboard in the last minute; the drag phase waits for the owner to be away");
    execFileSync("open", ["-g", "-n", "--env", `ARDIA_DATA_DIR=${data}`, "--env", `ARDIA_REMOTE_DEBUGGING_PORT=${port}`, app, "--args", "--mute-audio"]);
    let pid = 0;
    for (let i = 0; i < 400 && !pid; i++) {
      const r = spawnSync("pgrep", ["-f", pattern], { encoding: "utf8" });
      if (r.status === 0) pid = +r.stdout.trim().split("\n")[0];
      else await sleep(25);
    }
    if (!pid) throw new Error("the app didn't start");
    dragPid = pid;
    const drags = [];
    let stopped = null;
    const postdrag = (...a) => {
      const steps = +a[4], gap = +a[5];
      const r = spawnSync(acperfBin(), ["postdrag", ...a], { encoding: "utf8", timeout: steps * gap * 3 + 15_000 });
      let body = null;
      try {
        body = JSON.parse((r.stdout ?? "").trim());
      } catch {}
      if (r.signal || !body) acperf("mouseup");
      return { code: r.status, signal: r.signal, body: body ?? {} };
    };
    try {
      if (acperf("waitwindow", String(pid), "60").code !== 0) throw new Error("no window");
      await sleep(4000);
      if (!ownerAway(60)) throw new Error("someone used the Mac while the instance started; no drag was posted");
      if (acperf("activate", String(pid)).code !== 0) throw new Error("macOS refused to bring the instance to the front; no drag was posted");
      await sleep(800);
      const win = () => JSON.parse(acperf("windows", String(pid)).out || "[]").filter((w) => w.w >= 300 && w.h >= 200 && w.alpha > 0 && w.layer === 0)[0];
      const starts = { toolbar: (w) => [w.x + w.w * 0.6, w.y + 20], "sidebar top": (w) => [w.x + 90, w.y + 44], "top strip": (w) => [w.x + w.w / 2, w.y + 9] };
      outer: for (const [where, at] of Object.entries(starts))
        for (const gap of [4, 8])
          for (const shape of ["line", "wiggle"]) {
            await sleep(5500);
            if (!ownerAway(5)) {
              stopped = "someone used the Mac; the remaining drags weren't posted";
              break outer;
            }
            const w = win();
            if (!w) throw new Error("the window went away");
            const [x, y] = at(w);
            const r = postdrag(String(pid), String(w.id), `${x},${y}`, "80,40", "120", String(gap), shape);
            if (r.body.rows && r.code === 0 && !r.body.aborted) drags.push({ where, gap, shape, ...r.body });
            if (r.code !== 0 || r.body.error || r.body.aborted) {
              stopped = `postdrag ${r.signal ? `was killed (${r.signal})` : r.body.error ?? r.body.aborted ?? `exited ${r.code}`}; the remaining drags weren't posted`;
              break outer;
            }
            if (shape === "line") {
              const back = win();
              if (!back) throw new Error("the window went away");
              if (Math.abs(r.body.movedX - 80) > 4 || Math.abs(r.body.movedY - 40) > 4) {
                stopped = `the window moved (${r.body.movedX}, ${r.body.movedY}), not (80, 40); not moving it back, the remaining drags weren't posted`;
                break outer;
              }
              const undo = postdrag(String(pid), String(back.id), at(back).join(","), "-80,-40", "40", "8", "line");
              if (undo.code !== 0 || undo.body.error || undo.body.aborted) {
                stopped = `moving the window back stopped: ${undo.body.error ?? undo.body.aborted ?? `exit ${undo.code}`}`;
                break outer;
              }
              if (Math.abs(undo.body.movedX + 80) > 4 || Math.abs(undo.body.movedY + 40) > 4) {
                stopped = `moving the window back moved it (${undo.body.movedX}, ${undo.body.movedY}), not (-80, -40); the remaining drags weren't posted`;
                break outer;
              }
            }
            await sleep(600);
          }
    } finally {
      acperf("quit", String(pid));
      dragPid = 0;
      await sleep(3000);
    }
    if (stopped) partial.push(`drag: ${stopped}`);
    return { drags, stopped, settingsTitle: "not measured: the run opens no Settings window" };
  },
};

const median = (v) => {
  const s = v.filter(Number.isFinite).sort((a, b) => a - b);
  if (!s.length) return NaN;
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
};
const quantile = (v, q) => {
  const s = v.filter(Number.isFinite).sort((a, b) => a - b);
  if (!s.length) return NaN;
  const i = (s.length - 1) * q;
  return s[Math.floor(i)] + (s[Math.ceil(i)] - s[Math.floor(i)]) * (i - Math.floor(i));
};
function stats(values) {
  const v = values.filter(Number.isFinite);
  return { median: median(v), p75: quantile(v, 0.75), p95: quantile(v, 0.95), min: v.length ? Math.min(...v) : NaN, max: v.length ? Math.max(...v) : NaN, n: v.length };
}
const fmt = (x, digits = 0) => (Number.isFinite(x) ? x.toFixed(digits) : "–");
function table(rows, digits = 0) {
  const out = ["| Row | Side | Median | p75 | p95 | Min–max | n |", "|---|---|---|---|---|---|---|"];
  for (const r of rows) {
    const s = stats(r.values);
    if (!s.n) continue;
    out.push(`| ${r.name} | ${r.side} | ${fmt(s.median, r.digits ?? digits)} ${r.unit ?? "ms"} | ${fmt(s.p75, r.digits ?? digits)} | ${fmt(s.p95, r.digits ?? digits)} | ${fmt(s.min, r.digits ?? digits)}–${fmt(s.max, r.digits ?? digits)} | ${s.n} |`);
  }
  return out.join("\n");
}

const sidesOf = (results) => Object.entries(results ?? {});
const sideName = (label) => (state.meta.prepared?.control && label.includes("control") ? `${label} (control)` : label);

function render() {
  const P = state.phases;
  const md = [];
  const v = state.meta.version ?? "?";
  md.push(`# Native move: baseline ${v}`, "");
  md.push(`Measured by \`apps/browser/scripts/perf/native-baseline.mjs\` (plan: [baseline.md](baseline.md)) on \`${state.meta.app ?? "?"}\`${state.meta.control ? `, interleaved with \`${state.meta.control}\`` : ""}.`, "");
  const dark = PHASES.filter((n) => P[n]?.before?.display?.locked || P[n]?.before?.display?.asleep);
  const skipped = PHASES.filter((n) => P[n]?.skipped && !P[n]?.result);
  if (dark.length) md.push(`**Run with the screen locked or the display asleep:** ${dark.join(", ")}. macOS gives windows no display-link frames then and pages paint about once a second, so in those phases only rows that don't wait on a frame or a paint stand (launch → window shown and → JS running, memory, idle CPU and wakeups, compute); the paint and frame rows are left for the unlocked rerun.`, "");
  if (skipped.length) md.push(`**Left for a run with the display awake and unlocked:** ${skipped.join(", ")}.`, "");
  const lost = PHASES.filter((n) => P[n]?.partial || P[n]?.error);
  if (lost.length) md.push(`**Phases that failed or lost runs (their rows hold fewer samples):** ${lost.map((n) => `${n} (${(P[n].partial ?? [P[n].error]).join("; ").slice(0, 300)})`).join("; ")}.`, "");
  md.push(`The journeys (M2, M3, J4) and netcheck phases run on copies whose empty telemetry URL is filled with \`${TELEMETRY_SINK}\`: a build without one keeps sharing off, and the field timing those rows read only runs while it's on. Uploads go to bench-offline.js's answered fetch, and the host can't resolve. Every other phase runs the copies as built.`, "");
  md.push("Where this run departs from [baseline.md](baseline.md): the one-tab and seed launches run as two interleaved series (app and control interleaved within each), not interleaved with each other; acsample.c samples only in the framecounts runs, so the frames runs' timing carries no sampling cost.", "");
  md.push("Medians with p75, p95, min–max and n. A later phase regresses a row only when the ranges separate or the regression reproduces in a second interleaved round.", "");
  const nc = P.netcheck?.result;
  if (nc) md.push(`**No upstream traffic:** the netcheck phase ran a journeys pass per build with telemetry sharing on and listed the instances' sockets every 0.5 s (${nc.net.samples} samples): none to ardia.dev (${nc.net.ardiaAddresses.join(", ")}); the guard's post to bench-guard.invalid was answered by bench-offline.js on every run (${Object.keys(nc.guards).join(", ")}). Remote endpoints seen: ${nc.net.remotes.map((r) => `${r.remote} ×${r.count}`).join(", ") || "none"}.`, "");
  const c = state.meta.connections;
  if (c) md.push(`**Network:** the instances' sockets were listed every 2 s (${c.samples} samples, \`lsof\`): ${c.toArdia ? `**${c.toArdia} remote endpoint(s) at ardia.dev's addresses**` : "none to ardia.dev's addresses"} (${c.ardiaAddresses.join(", ") || "ardia.dev didn't resolve"}); every remote endpoint seen: ${c.remotes.length ? c.remotes.map((r) => `${r.remote} ×${r.count}`).join(", ") : "none"}.`, "");
  md.push("## Machine", "", "| Phase | Started | Load (1/5/15 min) before → after | Display | HID input during the phase (s) | Took (min) |", "|---|---|---|---|---|---|");
  for (const name of PHASES) {
    const p = P[name];
    if (!p) continue;
    md.push(`| ${name} | ${p.before?.at?.slice(0, 16).replace("T", " ") ?? "–"} | ${p.before?.load.join("/") ?? "–"} → ${p.after?.load.join("/") ?? "–"} | ${p.before?.display?.locked ? "locked" : p.before?.display?.asleep ? "asleep" : "awake"} | ${p.inputSecs ?? "–"} | ${p.minutes ? p.minutes.toFixed(0) : "–"} |`);
  }
  md.push("");

  const section = (title, body) => md.push(`## ${title}`, "", body, "");

  const tabSamples = P.tabactions?.result?.samples ?? [];
  const tabRows = [];
  for (const side of [...new Set(tabSamples.map((s) => s.side))])
    for (const action of ["click", "ctrlTab", "cmdNumber", "cmdT", "cmdW", "hoverClose", "pin", "unpin"]) {
      const ok = tabSamples.filter((s) => s.side === side && s.action === action && !s.error && s.worked !== false);
      if (!ok.length) continue;
      tabRows.push({ name: `${action}: event → selection committed (ui)`, side, values: ok.map((s) => s.ui), unit: "ms", digits: 1 });
      if (["click", "ctrlTab", "cmdNumber"].includes(action)) tabRows.push({ name: `${action}: event → page's second rAF (page)`, side, values: ok.map((s) => s.page), unit: "ms", digits: 1 });
      tabRows.push({ name: `${action}: main wait`, side, values: ok.map((s) => s.mainWait), unit: "ms", digits: 1 });
      if (action === "click") tabRows.push({ name: "click: mouse-down → mouse-up (press)", side, values: ok.map((s) => s.press), unit: "ms", digits: 1 });
    }
  section("M1 Tab switch (and the close and pin rows)", tabRows.length ? table(tabRows) : "Not run.");

  const J = (res) => sidesOf(res).map(([label, r]) => [label, r.journeys ?? []]);
  const pooled = (list, kind, field) => list.flatMap((r) => r[kind].map((x) => x[field]));
  const jr = [];
  for (const [label, list] of J(P.journeys?.result)) {
    jr.push({ name: "⌘T key → command bar committed", side: sideName(label), values: pooled(list, "j2", "commit") });
    jr.push({ name: "⌘T key → bar on screen and typeable", side: sideName(label), values: pooled(list, "j2", "typeable") });
    jr.push({ name: "keystroke → suggestions on screen (M3)", side: sideName(label), values: pooled(list, "j2", "suggest") });
    jr.push({ name: "J4 Enter in a new tab's bar → first contentful paint", side: sideName(label), values: pooled(list, "j4new", "fcp") });
    jr.push({ name: "J4 Enter in a page's panel → first contentful paint", side: sideName(label), values: pooled(list, "j4page", "fcp") });
  }
  for (const side of [...new Set(tabSamples.map((s) => s.side))]) {
    const ok = tabSamples.filter((s) => s.side === side && s.action === "cmdT" && !s.error && s.worked !== false);
    if (ok.length) jr.push({ name: "⌘T (tab-actions): event → new tab's last paint", side, values: ok.map((s) => s.total), digits: 1 });
  }
  section("M2, M3 New tab, keystroke → suggestions, J4", jr.length ? table(jr) : "Not run.");

  const sg = P.suggest?.result;
  if (sg) {
    const lines = [];
    for (const [who, text] of [["Hermes (suggest-hermes.mjs)", sg.hermes], ["node V8 (omnibox-bench.mts)", sg.v8], ["SolaraOmnibox, release (OmniboxBench)", sg.swift]])
      for (const l of (text ?? "").split("\n").filter((l) => /per key|prepare/.test(l))) lines.push(`| ${who} | ${l.replace(/\|/g, "/").trim()} |`);
    section("M3 compute per keystroke", ["| Engine | Result |", "|---|---|", ...lines].join("\n"));
  }

  const fr = [];
  for (const [label, res] of sidesOf(P.frames?.result)) {
    const runsOk = (res.frames ?? []).filter((r) => !r.skipped);
    const hover = runsOk.flatMap((r) => r.interactions?.["sidebar hover (20 rows, 60 ms apart)"] ?? []);
    fr.push({ name: "hover sweep: frames delivered", side: sideName(label), values: hover.map((x) => x.frames), unit: "" });
    fr.push({ name: "hover sweep: frames expected", side: sideName(label), values: hover.map((x) => x.expected), unit: "" });
    fr.push({ name: "hover sweep: ticks over 8.33 ms", side: sideName(label), values: hover.map((x) => x.over8), unit: "" });
    fr.push({ name: "hover sweep: worst frame", side: sideName(label), values: hover.map((x) => x.worst), digits: 1 });
    fr.push({ name: "hover sweep: main thread longest stall", side: sideName(label), values: hover.map((x) => x.mainWorst), digits: 1 });
    const skipped = (res.frames ?? []).length - runsOk.length;
    if (skipped) fr.push({ name: "frames runs skipped (display asleep or locked)", side: sideName(label), values: [skipped], unit: "" });
  }
  section("M4 Sidebar hover", fr.length ? `${table(fr)}\n\nPointer enters a row → its background in a Core Animation commit isn't timed by the rig yet; the rows above are the sweep's frame pacing.` : "Not run.");

  const drags = P.drag?.result?.drags;
  if (drags?.length) {
    const dr = [];
    for (const where of [...new Set(drags.map((d) => d.where))])
      for (const gap of [4, 8])
        for (const shape of ["line", "wiggle"]) {
          const d = drags.filter((x) => x.where === where && x.gap === gap && x.shape === shape);
          if (!d.length) continue;
          const k = `${where}, ${shape}, ${gap} ms`;
          dr.push({ name: `${k}: mouse-down → first window move`, side: "", values: d.map((x) => x.firstMove?.ms), digits: 1 });
          dr.push({ name: `${k}: pointer travel before it moved`, side: "", values: d.map((x) => x.firstMove?.travelPt), unit: "pt", digits: 1 });
          dr.push({ name: `${k}: trail (median per drag)`, side: "", values: d.map((x) => x.trailMedianPt), unit: "pt", digits: 1 });
          dr.push({ name: `${k}: trail (worst per drag)`, side: "", values: d.map((x) => x.trailMaxPt), unit: "pt", digits: 1 });
          dr.push({ name: `${k}: error after mouse-up`, side: "", values: d.map((x) => x.endErrorPt), unit: "pt", digits: 1 });
        }
    section("M5 Window drag frame pacing", `${table(dr)}\n\n${P.drag.result.stopped ? `The phase stopped early: ${P.drag.result.stopped}.\n\n` : ""}The Settings title drag: ${P.drag.result.settingsTitle}. Mouse-down → first move is read once per step, so it's accurate to the step's gap.`);
  } else {
    section("M5 Window drag frame pacing", "**Needs owner run.** It posts real HID drags to a visible window (`native-baseline.mjs --only drag --drag`), so it waits for the owner's go-ahead.");
  }

  const stallBlocks = [];
  for (const [label, res] of sidesOf(P.frames?.result)) {
    const names = [...new Set((res.frames ?? []).flatMap((r) => Object.keys(r.stalls ?? {})))];
    const lines = ["| Scenario | Thread | Iterations | Busy ms | Worst ms | 8–16 | 16–33 | 33–50 | 50–100 | 100–250 | ≥250 |", "|---|---|---|---|---|---|---|---|---|---|---|"];
    for (const name of names)
      for (const th of ["main", "js"]) {
        const ws = (res.frames ?? []).flatMap((r) => r.stalls?.[name] ?? []).map((w) => w[th]).filter(Boolean);
        if (!ws.length) continue;
        const sum = (f) => ws.reduce((n, w) => n + f(w), 0);
        lines.push(`| ${name} | ${th === "main" ? "main" : "JS"} | ${sum((w) => w.iterations)} | ${Math.round(sum((w) => w.busyMs))} | ${fmt(Math.max(...ws.map((w) => w.worstMs)), 0)} | ${[0, 1, 2, 3, 4, 5].map((i) => sum((w) => w.buckets[i])).join(" | ")} |`);
      }
    stallBlocks.push(`${sideName(label)}, summed over ${(res.frames ?? []).filter((r) => r.stalls).length} runs:\n\n${lines.join("\n")}`);
  }
  for (const [label, entry] of Object.entries(P.framecounts?.result?.attribution ?? {})) {
    const attribution = entry?.rows;
    if (!attribution?.length) continue;
    if (!entry.symbolized) stallBlocks.push(`${sideName(label)}: **no dSYM was found**, so React Native's frames inside the executable count as the app's below.`);
    const lines = ["| Scenario | Iterations ≥ 50 ms | Stalled ms | Samples | Chrome | Hermes | React Native | App | System |", "|---|---|---|---|---|---|---|---|---|"];
    for (const r of attribution) lines.push(`| ${r.scenario} | ${r.iterations} | ${r.stalledMs} | ${r.samples} | ${["chrome", "hermes", "react", "app", "system"].map((c) => `${Math.round(r.share[c] * 100)}%`).join(" | ")} |`);
    stallBlocks.push(`${sideName(label)}: where the main thread's iterations of 50 ms or more went. Stack samples from the framecounts runs (acsample.c, only once an iteration passes 16 ms, so the first 16 ms of a long one aren't sampled), grouped by stall-samples.mjs; "React Native" is RN, Yoga, Folly and Expo's native code, told apart from the app's by symbol name through the build's dSYM. The counts runs have the JS perf probe and the sampler on, so their iteration lengths read longer than the frames runs' histogram above.\n\n${lines.join("\n")}`);
  }
  if (stallBlocks.length) stallBlocks.push("Busy time is an iteration's after-waiting → before-waiting span. A nested run loop that fires no observers (Chrome's private modes) counts as busy for its whole length, idle time included.");
  section("M6 Main-thread stall histogram", stallBlocks.length ? stallBlocks.join("\n\n") : "Not run.");

  const lr = [];
  for (const [phase, title] of [["launch", "warm"], ["coldlaunch", "cold"]])
    for (const [profile, res] of Object.entries(P[phase]?.result ?? {}))
      for (const [label, r] of sidesOf(res)) {
        const L = r.launch ?? [];
        const k = `${title}, ${profile === "seed" ? "seed" : "one tab"}`;
        lr.push({ name: `${k}: window shown`, side: sideName(label), values: L.map((x) => x.window) });
        lr.push({ name: `${k}: JS running`, side: sideName(label), values: L.map((x) => x.js) });
        lr.push({ name: `${k}: window with content`, side: sideName(label), values: L.map((x) => x.withContent) });
        if (dark.includes(phase)) continue;
        lr.push({ name: `${k}: page's first frame`, side: sideName(label), values: L.map((x) => x.firstFrame) });
        lr.push({ name: `${k}: first contentful paint`, side: sideName(label), values: L.map((x) => x.firstPaint) });
      }
  section("M7 Launch → first window", lr.length ? table(lr) : "Not run.");

  const mr = [];
  for (const [label, r] of sidesOf(P.memslope?.result)) {
    const M = r.memslope ?? [];
    mr.push({ name: "slope, all processes (MB per window)", side: sideName(label), values: M.map((x) => x.slopeTotalMB), unit: "MB", digits: 1 });
    mr.push({ name: "slope, browser process (MB per window)", side: sideName(label), values: M.map((x) => x.slopeBrowserMB), unit: "MB", digits: 1 });
    for (let k = 1; k <= 4; k++) {
      mr.push({ name: `window ${k}: Δ all processes`, side: sideName(label), values: M.map((x) => x.points[k] && x.points[k].totalMB - x.points[k - 1].totalMB), unit: "MB", digits: 1 });
      mr.push({ name: `window ${k}: Δ browser process`, side: sideName(label), values: M.map((x) => x.points[k] && x.points[k].browserMB - x.points[k - 1].browserMB), unit: "MB", digits: 1 });
    }
  }
  for (const [label, r] of sidesOf(P.session?.result)) {
    const S = r.session ?? [];
    for (const m of ["tabs1", "tabs10", "tabs20", "closed"]) mr.push({ name: `phys_footprint, ${m === "closed" ? "closed back to 1 tab" : m.slice(4) + " tab(s)"} (one-tab session)`, side: sideName(label), values: S.map((x) => x.memory?.[m]?.totalMB), unit: "MB" });
    mr.push({ name: "new window → on screen", side: sideName(label), values: S.flatMap((x) => x.newWindow.map((w) => w.window)) });
    mr.push({ name: "new window → on screen with its content", side: sideName(label), values: S.flatMap((x) => x.newWindow.map((w) => w.withContent)) });
  }
  section("M8 Memory per window", mr.length ? table(mr) : "Not run.");

  const cr = [];
  for (const [label, res] of sidesOf(P.framecounts?.result?.results)) {
    const runsOk = (res.frames ?? []).filter((r) => !r.skipped);
    for (const name of [...new Set(runsOk.flatMap((r) => Object.keys(r.interactions ?? {})))]) {
      const reps = runsOk.flatMap((r) => r.interactions[name] ?? []);
      for (const [key, label2] of [["commits", "React commits"], ["storeUpdates", "store updates"], ["layoutPasses", "layout passes"], ["viewUpdates", "view updates"], ["mountBatches", "mount batches"]])
        cr.push({ name: `${name}: ${label2}`, side: sideName(label), values: reps.map((x) => x[key]), unit: "" });
    }
  }
  section("M9 Counts per action", cr.length ? `${table(cr)}\n\nCore Animation commits and SolaraSignposts counters join these rows once the app emits them (\`SolaraSignposts.count\`).` : "Not run.");

  const ir = [];
  for (const [label, r] of sidesOf(P.session?.result)) {
    const S = r.session ?? [];
    for (const t of ["tabs1", "tabs20"]) {
      ir.push({ name: `idle CPU, ${t.slice(4)} tab(s), all processes`, side: sideName(label), values: S.map((x) => x.idle?.[t]?.total.cpu), unit: "%", digits: 2 });
      ir.push({ name: `idle wakeups/s, ${t.slice(4)} tab(s), all processes`, side: sideName(label), values: S.map((x) => x.idle?.[t]?.total.wakeups), unit: "/s", digits: 1 });
      ir.push({ name: `idle input seconds, ${t.slice(4)} tab(s) (nonzero: someone used the Mac)`, side: sideName(label), values: S.map((x) => x.idle?.[t]?.input?.inputSecs), unit: "s", digits: 1 });
    }
  }
  section("Idle", ir.length ? table(ir) : "Not run.");
  return md.join("\n");
}

if (opt.report) {
  const file = opt.md ? resolve(opt.md) : join(repoRoot, "docs/native", `baseline-${state.meta.version ?? "unknown"}.md`);
  writeFileSync(file, render() + "\n");
  console.log(`wrote ${file}`);
  process.exit(0);
}

if (!opt.app) fail("usage: native-baseline.mjs --app <dist/<v>/export/X.app> --out <dir> [options] (--help)");
const wanted = opt.only ? opt.only.split(",").map((p) => p.trim()) : PHASES.filter((p) => p !== "drag" || opt.drag);
for (const p of wanted) if (!PHASES.includes(p)) fail(`--only: no phase "${p}"; phases: ${PHASES.join(", ")}`);
if (wanted.includes("drag") && !opt.drag) fail("the drag phase needs --drag: it moves the real pointer over a visible window, so only with the owner's go-ahead");
mkdirSync(out, { recursive: true });
Object.assign(state.meta, { app: resolve(opt.app), control: opt.control ? resolve(opt.control) : null, version: opt.version ?? state.meta.version ?? plist(opt.app, "CFBundleShortVersionString") });

const exe = join(resolve(opt.app), "Contents/MacOS", plist(opt.app, "CFBundleExecutable"));
if (spawnSync("pgrep", ["-f", `/${basename(exe)}( |$)`]).status === 0) log(`note: another ${basename(exe)} process is running (yours to check: never quit the owner's)`);
const disp = machine().display;
const dark = disp.asleep || disp.locked;
if (dark && !opt["locked-ok"]) fail(`the display is ${disp.asleep ? "asleep" : "locked"}: macOS gives no display-link frames then; wake and unlock it first, or pass --locked-ok to run only what doesn't need them`);

const caffeinate = spawn("caffeinate", ["-d", "-w", String(process.pid)], { stdio: "ignore" });
const connections = new ConnectionWatch();
let held = false;
const release = () => {
  if (held) spawnSync(join(repoRoot, "scripts/agent/locked"), ["perflab", "--release", opt.who]);
  held = false;
};
for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"])
  process.on(sig, () => {
    if (dragPid) acperf("quit", String(dragPid));
    release();
    caffeinate.kill();
    process.exit(128 + ({ SIGINT: 2, SIGTERM: 15, SIGHUP: 1 })[sig]);
  });
try {
  if (!wanted.includes("prepare") && !state.meta.prepared && wanted.some((n) => LOCKED.has(n))) fail("no prepared copies in this --out: run the prepare phase first");
  for (const name of wanted) {
    if (NEEDS_DISPLAY.has(name)) {
      const d = machine().display;
      if (d.asleep || d.locked) {
        log(`${name}: left out, the display is ${d.asleep ? "asleep" : "locked"}`);
        state.phases[name] = { ...(state.phases[name]?.result ? state.phases[name] : {}), skipped: `the display was ${d.asleep ? "asleep" : "locked"}` };
        save();
        continue;
      }
    }
    if (opt.resume && state.phases[name]?.result && !state.phases[name].partial) {
      log(`${name}: done already (--resume)`);
      continue;
    }
    if (LOCKED.has(name) && !held) {
      const r = spawnSync(join(repoRoot, "scripts/agent/locked"), ["perflab", "--take", opt.who, "--ttl", "240", "--wait", "500"], { stdio: "inherit" });
      if (r.status !== 0) fail("couldn't take the perflab lock");
      held = true;
    }
    if (!LOCKED.has(name)) release();
    const watch = name === "drag" ? { stop: () => null } : new InputWatch();
    const before = machine();
    const t0 = Date.now();
    partial = [];
    log(`${name}: start (load ${before.load.join("/")})`);
    try {
      const result = await phases[name]();
      state.phases[name] = { before, after: machine(), inputSecs: watch.stop(), minutes: (Date.now() - t0) / 60000, result, ...(partial.length ? { partial } : {}) };
      if (partial.length) log(`${name}: PARTIAL ${partial.join(" | ")}`);
    } catch (error) {
      state.phases[name] = { before, after: machine(), inputSecs: watch.stop(), minutes: (Date.now() - t0) / 60000, error: String(error.message ?? error) };
      log(`${name}: FAILED ${error.message ?? error}`);
    }
    save();
  }
} finally {
  state.meta.connections = connections.stop();
  save();
  release();
  caffeinate.kill();
  spawnSync(join(repoRoot, "scripts/agent/unregister-builds"), { stdio: "inherit" });
}
const report = opt.md ? resolve(opt.md) : join(repoRoot, "docs/native", `baseline-${state.meta.version}.md`);
writeFileSync(report, render() + "\n");
log(`wrote ${report} and ${stateFile}`);
const failed = Object.entries(state.phases).filter(([, p]) => p.error || p.partial).map(([n]) => n);
if (failed.length) log(`kept ${out}: ${failed.join(", ")} failed or lost runs (rerun them with --resume)`);
else if (!opt.keep)
  for (const name of readdirSync(out)) if (name !== "baseline.json" && statSync(join(out, name)).isDirectory()) rmSync(join(out, name), { recursive: true, force: true });

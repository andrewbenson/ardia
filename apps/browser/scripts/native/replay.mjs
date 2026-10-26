#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, writeFileSync } from "node:fs";
import { registerHooks } from "node:module";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HELP = `usage: node scripts/native/replay.mjs [--phase 1a|1b] [--out <dir>] [test files...]

Runs the store's *.test.mjs files through the real JS store, recording every call of a command
the Swift core owns in that phase as a case: the state before, the command, the state after,
the clock and the id counter. SolaraStoreTests replays each case through the Swift core and
diffs canonical JSON. Each test file runs in its own process, as node --test runs them.`;

const here = dirname(fileURLToPath(import.meta.url));
const app = resolve(here, "../..");
const defaultOut = resolve(app, "../../native/SolaraKit/Tests/SolaraStoreTests/Cases");

const args = process.argv.slice(2);
if (args.includes("--help")) {
  console.log(HELP);
  process.exit(0);
}
const option = (name, fallback) => {
  const at = args.indexOf(name);
  if (at < 0) return fallback;
  const value = args[at + 1];
  args.splice(at, 2);
  return value;
};
const phase = option("--phase", "1a");
const out = resolve(option("--out", defaultOut));
const child = option("--child", null);

if (child) await record(child);
else orchestrate();

function orchestrate() {
  const files = args.length
    ? args.map((f) => resolve(f))
    : ["src/store", "src/lib", "src/sync"].flatMap((dir) =>
        readdirSync(join(app, dir)).filter((f) => f.endsWith(".test.mjs")).map((f) => join(app, dir, f)),
      );
  mkdirSync(out, { recursive: true });
  let cases = 0;
  let failed = 0;
  for (const file of files.sort()) {
    const run = spawnSync(process.execPath, ["--no-warnings", fileURLToPath(import.meta.url), "--child", file, "--phase", phase, "--out", out], {
      cwd: app,
      encoding: "utf8",
      maxBuffer: 1 << 28,
    });
    const summary = run.stdout.trim().split("\n").at(-1) ?? "";
    const match = /^recorded (\d+)/.exec(summary);
    if (run.status !== 0 || !match) {
      failed++;
      console.error(`${relative(app, file)}: failed\n${run.stderr.split("\n").slice(-15).join("\n")}`);
      continue;
    }
    cases += Number(match[1]);
    if (Number(match[1]) || run.stderr.trim()) console.log(`${relative(app, file)}: ${summary.replace(/^recorded /, "")}`);
    if (run.stderr.trim()) console.log(run.stderr.trim().split("\n").map((l) => `  ${l}`).join("\n"));
  }
  console.log(`${cases} cases from ${files.length - failed} files${failed ? `, ${failed} files failed` : ""}`);
  process.exit(failed ? 1 : 0);
}

function mulberry32(seed) {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function hasUndefinedKey(value, seen = new Set()) {
  if (!value || typeof value !== "object" || seen.has(value)) return false;
  seen.add(value);
  return Object.entries(value).some(([, v]) => v === undefined || hasUndefinedKey(v, seen));
}

function plain(value) {
  return value === undefined ? null : JSON.parse(JSON.stringify(value));
}

async function record(file) {
  let clock = Date.UTC(2026, 9, 26, 12);
  let frozen = null;
  const stubNow = () => frozen ?? (clock += 1);
  Date.now = stubNow;
  Math.random = mulberry32(0x5eed);
  globalThis.__DEV__ = false;

  const tests = [];
  const hooks = { beforeEach: [], afterEach: [] };
  const realTest = await import("node:test");
  globalThis.__replayNodeTest = {
    test: Object.assign((name, options, fn) => tests.push({ name, fn: fn ?? options, skip: typeof options === "object" && options?.skip }), {
      skip: (name) => tests.push({ name, skip: true }),
      only: (name, options, fn) => tests.push({ name, fn: fn ?? options }),
      todo: (name) => tests.push({ name, skip: true }),
    }),
    beforeEach: (fn) => hooks.beforeEach.push(fn),
    afterEach: (fn) => hooks.afterEach.push(fn),
    mock: realTest.mock,
  };
  const fakeUrl = `data:text/javascript,const t = globalThis.__replayNodeTest; export const test = t.test, it = t.test, beforeEach = t.beforeEach, afterEach = t.afterEach, mock = t.mock; export default t.test;`;
  registerHooks({
    resolve(specifier, context, next) {
      if (specifier === "node:test" && !context.parentURL?.startsWith("data:")) return { url: fakeUrl, shortCircuit: true };
      return next(specifier, context);
    },
  });
  await import(pathToFileURL(join(app, "src/test-loader.mjs")).href);
  await import(pathToFileURL(file).href);

  const spec = await phases(phase);
  const { useBrowser } = await import(pathToFileURL(join(app, "src/store/browser.ts")).href);
  const model = await import(pathToFileURL(join(app, "src/store/model.ts")).href);
  const probe = () => {
    const [, launch, counter] = /^probe-([0-9a-z]+)-([0-9a-z]+)$/.exec(model.newId("probe"));
    return { launch, counter: parseInt(counter, 36) };
  };

  let cases = [];
  let current = null;
  let depth = 0;
  const memory = { endedPrivateDownloads: new Set() };
  const WRAPPED = Symbol("replay");

  const wrap = (state) => {
    const patch = {};
    for (const name of spec.commands) {
      const original = state[name];
      if (typeof original !== "function" || original[WRAPPED]) continue;
      const wrapped = function (...callArgs) {
        if (depth > 0 || !current) {
          depth++;
          try {
            return original.apply(this, callArgs);
          } finally {
            depth--;
          }
        }
        const before = useBrowser.getState();
        const testNow = Date.now === stubNow ? null : Date.now;
        const now = testNow ? testNow() : stubNow();
        frozen = now;
        if (testNow) Date.now = () => now;
        const ids = probe();
        const command = spec.command(name, callArgs, before, model);
        const memoryBefore = { endedPrivateDownloads: [...memory.endedPrivateDownloads].sort() };
        depth++;
        let result;
        let threw = null;
        try {
          result = original.apply(this, callArgs);
        } catch (error) {
          threw = error;
        } finally {
          depth--;
          frozen = null;
          if (testNow) Date.now = testNow;
        }
        const after = useBrowser.getState();
        spec.noteMemory?.(name, callArgs, before, after, memory, model);
        if (command && !threw) {
          cases.push({
            test: current,
            now,
            ids,
            memory: memoryBefore,
            before: spec.project(before, model),
            command,
            after: spec.project(after, model),
            ...(hasUndefinedKey(callArgs) ? { lossy: "an argument has a key set to undefined, which JSON cannot carry" } : {}),
            ...(result !== undefined && spec.recordsResult ? { result: plain(result) } : {}),
            ...(spec.extra ? spec.extra(name, callArgs, before, after, model) : {}),
          });
        }
        if (threw) throw threw;
        return result;
      };
      wrapped[WRAPPED] = true;
      patch[name] = wrapped;
    }
    return patch;
  };
  const rawSetState = useBrowser.setState;
  useBrowser.setState = (partial, replace) => {
    rawSetState(partial, replace);
    const rewrap = wrap(useBrowser.getState());
    if (Object.keys(rewrap).length) rawSetState(rewrap);
  };
  rawSetState(wrap(useBrowser.getState()));

  let failures = 0;
  for (const t of tests) {
    if (t.skip || !t.fn) continue;
    current = t.name;
    try {
      for (const fn of hooks.beforeEach) await fn();
      await t.fn({ name: t.name, mock: realTest.mock, test: () => {}, after: () => {}, skip: () => {}, diagnostic: () => {} });
      for (const fn of hooks.afterEach) await fn();
    } catch (error) {
      failures++;
      console.error(`test failed under replay, its cases dropped: ${t.name}: ${error?.message ?? error}`);
      cases = cases.filter((c) => c.test !== t.name);
    }
    current = null;
  }
  const seen = new Set();
  cases = cases.filter((c) => {
    const { test: _t, now: _n, ids: _i, ...rest } = c;
    const key = JSON.stringify(spec.timeless ? rest : { ...rest, now: c.now, ids: c.ids });
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
  mkdirSync(out, { recursive: true });
  const name = relative(join(app, "src"), file).replace(/\.test\.mjs$/, "").replaceAll("/", "__");
  const target = join(out, `${phase}__${name}.json`);
  if (cases.length) writeFileSync(target, JSON.stringify({ phase, file: relative(app, file), cases }) + "\n");
  else if (existsSync(target)) writeFileSync(target, JSON.stringify({ phase, file: relative(app, file), cases: [] }) + "\n");
  console.log(`recorded ${cases.length} cases${failures ? `, ${failures} tests failed under replay` : ""}`);
  process.exit(0);
}

async function phases(name) {
  const ui = await import(pathToFileURL(join(app, "src/store/ui.ts")).href);
  const privateSessionOpen = (s, session, model) =>
    Object.values(s.windows).some((w) => w.incognito && model.privateSession(w.profileId) === session);
  const specs = {
    "1a": {
      timeless: true,
      commands: ["updateSettings", "upsertDownload", "removeDownload", "clearDownloads", "forgetDownloads", "hydrate"],
      project: (s) => ({ settings: plain(s.settings), downloads: plain(s.downloads) }),
      command(name, callArgs, s, model) {
        switch (name) {
          case "updateSettings":
            return { name, args: [plain(callArgs[0]), { fromSync: !!callArgs[1]?.fromSync }] };
          case "upsertDownload": {
            const d = callArgs[0];
            const session = ui.downloadSession(d);
            const focused = s.ui.focusedWindowId;
            const context = {};
            if (session !== null) context.privateSession = { open: privateSessionOpen(s, session, model) };
            if (focused && ui.downloadVisibleIn(d, s.windows[focused])) context.focusedWindowShowing = focused;
            return { name, args: [plain(d), context] };
          }
          case "removeDownload":
            return { name, args: [callArgs[0]] };
          case "clearDownloads": {
            const windowId = callArgs[0];
            const visibleIds = windowId === undefined ? null : s.downloads.filter((d) => ui.downloadVisibleIn(d, s.windows[windowId])).map((d) => d.id);
            return { name, args: [{ visibleIds }] };
          }
          case "forgetDownloads": {
            const session = model.privateSession(callArgs[0]);
            const gone = (d) => (session !== null ? ui.downloadSession(d) === session : d.profile === callArgs[0]);
            return { name, args: [{ ids: s.downloads.filter(gone).map((d) => d.id), privateSession: session !== null }] };
          }
          case "hydrate":
            return { name, args: [{ settings: plain(callArgs[0]?.settings) }] };
        }
        return null;
      },
      extra: (name, callArgs, before, after) => (name === "hydrate" ? { profileOrder: plain(after.profileOrder), downloadsGiven: callArgs[0]?.downloads !== undefined } : {}),
      noteMemory(name, callArgs, before, after, memory, model) {
        if (name === "upsertDownload") {
          const d = callArgs[0];
          const exists = before.downloads.some((x) => x.id === d.id);
          const session = ui.downloadSession(d);
          if (!exists && session !== null && (!privateSessionOpen(before, session, model) || memory.endedPrivateDownloads.has(d.id))) {
            memory.endedPrivateDownloads.add(d.id);
          }
        }
        if (name === "forgetDownloads") {
          const session = model.privateSession(callArgs[0]);
          if (session !== null) for (const d of before.downloads) if (ui.downloadSession(d) === session) memory.endedPrivateDownloads.add(d.id);
        }
      },
    },
  };
  if (!specs[name]) throw new Error(`unknown phase ${name}`);
  return specs[name];
}

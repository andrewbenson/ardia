#!/usr/bin/env node
import { spawn, spawnSync } from "node:child_process";
import { closeSync, mkdirSync, mkdtempSync, openSync, readSync, rmSync, writeFileSync, writeSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { deflateRawSync } from "node:zlib";
import { canonical } from "../src/canon.ts";
import { Clock } from "../src/hlc.ts";
import { compact, emptyScope, restoreJournal, syncScope } from "../src/scope.ts";

const HELP = `usage: node packages/sync/scripts/scenario.mjs [--out <dir>] [--runs <n>] [--steps <n>] [--seed <n>] [--mixed <solara-store>]

Runs sync scenarios through the TypeScript merge (scope.ts) and writes each one with its trace: every
payload written, every removal, each sync's result or error, and after each step every device's scope
state, store, settings and clock. SolaraSyncTests replays the scripts through the Swift merge and must
produce the same trace byte for byte. Scenarios are the named cases below plus seeded random runs of
three devices with flaky delivery, clock skew, compaction, relaunches and crashes.
Default out: native/SolaraKit/Tests/SolaraSyncTests/Scenarios.
--mixed runs every scenario a second time with device "b" (or the second device) as the Swift merge in
solara-store sync-device, sharing the folder with the TypeScript devices, and fails unless both runs trace
the same.`;

const args = process.argv.slice(2);
if (args.includes("--help")) {
  console.log(HELP);
  process.exit(0);
}
const option = (name, fallback) => {
  const at = args.indexOf(name);
  return at < 0 ? fallback : args[at + 1];
};
const here = dirname(fileURLToPath(import.meta.url));
const out = resolve(option("--out", join(here, "../../../native/SolaraKit/Tests/SolaraSyncTests/Scenarios")));
const runs = Number(option("--runs", "60"));
const stepsPerRun = Number(option("--steps", "60"));
const firstSeed = Number(option("--seed", "1"));

class Folder {
  scopes = new Map();
  counter = 0;
  now = 0;
  scope(name) {
    let s = this.scopes.get(name);
    if (!s) this.scopes.set(name, (s = new Map()));
    return s;
  }
}

class Device {
  store = new Map();
  settings = new Map();
  state = emptyScope();
  offset = 0;
  saved = JSON.stringify(emptyScope());
  savedClock = null;
  journal = new Map();
  onRead = null;
  failWrite = null;
  constructor(id, folder, options, trace) {
    this.id = id;
    this.folder = folder;
    this.options = options;
    this.trace = trace;
    this.clock = new Clock(id, null, () => this.time());
  }
  time() {
    return this.folder.now + this.offset;
  }
  adapters() {
    return [
      {
        prefix: "x:",
        extract: () => ({ values: new Map(this.store) }),
        apply: (visible, changed) => {
          this.trace.push({ apply: this.id, prefix: "x:", changed: [...changed], visible: Object.fromEntries(visible) });
          for (const k of changed) visible.has(k) ? this.store.set(k, visible.get(k)) : this.store.delete(k);
        },
      },
      {
        prefix: "set:",
        adoptRemoteOnJoin: true,
        extract: () => ({ values: new Map(this.settings) }),
        apply: (visible, changed) => {
          this.trace.push({ apply: this.id, prefix: "set:", changed: [...changed], visible: Object.fromEntries(visible) });
          for (const k of changed) if (visible.has(k)) this.settings.set(k, visible.get(k));
        },
      },
    ];
  }
  transport(run) {
    const folder = this.folder;
    return {
      write: async (scope, payload) => {
        const fail = this.failWrite;
        this.failWrite = null;
        if (fail === "before") throw new Error("offline");
        const id = `f${++folder.counter}`;
        folder.scope(scope).set(id, { payload, hiddenFrom: new Set(), partialFor: new Set(), at: folder.now });
        this.trace.push({ write: this.id, id, payload });
        if (fail === "after") throw new Error("timed out");
        return id;
      },
      read: async (scope, known) => {
        const listing = { files: [], pending: [], damaged: [], present: [] };
        for (const [id, e] of folder.scope(scope)) {
          listing.present.push(id);
          if (known.includes(id)) continue;
          if (e.hiddenFrom.has(this.id)) listing.pending.push(id);
          else if (e.partialFor.has(this.id)) listing.damaged.push({ id, age: 0 });
          else listing.files.push({ id, payload: e.payload });
        }
        const hook = this.onRead;
        this.onRead = null;
        if (hook) for (const step of hook) await run(step);
        return listing;
      },
      remove: async (scope, ids) => {
        this.trace.push({ remove: this.id, ids: [...ids] });
        for (const id of ids) folder.scope(scope).delete(id);
      },
    };
  }
  persist(batches) {
    for (const f of batches) this.journal.set(f.seq, JSON.parse(JSON.stringify(f)));
  }
  options_() {
    return { pruneGrace: 0, persist: async (batches) => this.persist(batches), ...this.options };
  }
  record() {
    const sorted = (m) => Object.fromEntries([...m].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)));
    return { device: this.id, state: canonical(this.state), store: sorted(this.store), settings: sorted(this.settings), clock: this.clock.last };
  }
}

class SwiftDevice {
  constructor(id, folder, options, trace, binary) {
    this.id = id;
    this.folder = folder;
    this.trace = trace;
    this.onRead = null;
    this.failWrite = null;
    this.dir = mkdtempSync(join(process.env.TMPDIR ?? tmpdir(), "sync-device-"));
    const requests = join(this.dir, "requests");
    const responses = join(this.dir, "responses");
    spawnSync("mkfifo", [requests, responses]);
    this.child = spawn("sh", ["-c", 'b="$1"; q="$2"; r="$3"; shift 3; exec "$b" "$@" < "$q" > "$r"', "sh", binary, requests, responses, "sync-device", "--id", id, "--options", JSON.stringify(options)], { stdio: ["ignore", "ignore", "inherit"] });
    this.child.unref();
    this.writer = openSync(requests, "w");
    this.reader = openSync(responses, "r");
    this.pending = "";
  }
  send(message) {
    writeSync(this.writer, JSON.stringify({ ...message, now: this.folder.now }) + "\n");
  }
  receive() {
    const chunk = Buffer.alloc(1 << 16);
    while (!this.pending.includes("\n")) {
      const read = readSync(this.reader, chunk, 0, chunk.length, null);
      if (read === 0) throw new Error("sync-device exited");
      this.pending += chunk.toString("utf8", 0, read);
    }
    const at = this.pending.indexOf("\n");
    const line = this.pending.slice(0, at);
    this.pending = this.pending.slice(at + 1);
    return JSON.parse(line);
  }
  local(step) {
    this.send(step);
    this.last = this.receive().record;
  }
  record() {
    this.send({ op: "record" });
    return this.receive().record;
  }
  async converse(request, run, scope) {
    this.send(request);
    for (;;) {
      const message = this.receive();
      if ("done" in message || "failed" in message) return message;
      if (message.call === "write") {
        const fail = this.failWrite;
        this.failWrite = null;
        if (fail === "before") {
          this.send({ error: "offline" });
          continue;
        }
        const id = `f${++this.folder.counter}`;
        this.folder.scope(message.scope).set(id, { payload: message.payload, hiddenFrom: new Set(), partialFor: new Set(), at: this.folder.now });
        this.trace.push({ write: this.id, id, payload: message.payload });
        this.send(fail === "after" ? { error: "timed out" } : { id });
      } else if (message.call === "read") {
        const listing = { files: [], pending: [], damaged: [], present: [] };
        for (const [id, e] of this.folder.scope(message.scope)) {
          listing.present.push(id);
          if (message.known.includes(id)) continue;
          if (e.hiddenFrom.has(this.id)) listing.pending.push(id);
          else if (e.partialFor.has(this.id)) listing.damaged.push({ id, age: 0 });
          else listing.files.push({ id, payload: e.payload });
        }
        const hook = this.onRead ?? [];
        this.onRead = null;
        const mine = [];
        for (const step of hook) {
          if (step.device === this.id && (step.op === "set" || step.op === "delete")) mine.push(step);
          else await run(step);
        }
        this.send({ listing, then: mine });
      } else if (message.call === "apply") {
        this.trace.push({ apply: this.id, prefix: message.prefix, changed: message.changed, visible: message.visible });
        this.send({});
      } else if (message.call === "remove") {
        this.trace.push({ remove: this.id, ids: message.ids });
        for (const id of message.ids) this.folder.scope(message.scope).delete(id);
        this.send({});
      }
    }
  }
  close() {
    try {
      closeSync(this.writer);
      closeSync(this.reader);
    } catch {}
    this.child.kill();
    rmSync(this.dir, { recursive: true, force: true });
  }
}

export async function runScenario(script, { swift = null } = {}) {
  const trace = [];
  const folder = new Folder();
  const devices = new Map();
  const ids = Object.keys(script.devices);
  const swiftId = swift ? (ids.includes("b") ? "b" : ids[1]) : null;
  for (const [id, options] of Object.entries(script.devices))
    devices.set(id, id === swiftId ? new SwiftDevice(id, folder, options ?? {}, trace, swift) : new Device(id, folder, options ?? {}, trace));
  const scope = script.scope ?? "s";
  const entry = (file) => folder.scope(scope).get(file);
  const latest = () => [...folder.scope(scope).keys()].at(-1);
  async function run(step) {
    const d = devices.get(step.device);
    if (d instanceof SwiftDevice) return runSwift(d, step);
    switch (step.op) {
      case "time":
        folder.now = step.now;
        break;
      case "advance":
        folder.now += step.ms;
        break;
      case "offset":
        d.offset = step.ms;
        break;
      case "set":
        (step.key.startsWith("set:") ? d.settings : d.store).set(step.key, step.value);
        break;
      case "delete":
        (step.key.startsWith("set:") ? d.settings : d.store).delete(step.key);
        break;
      case "awaitRemote":
        d.state.awaitRemote = true;
        break;
      case "onRead":
        d.onRead = step.steps;
        break;
      case "failWrite":
        d.failWrite = step.when;
        break;
      case "hide":
      case "unhide":
      case "partial":
      case "whole": {
        const e = entry(step.file === "latest" ? latest() : step.file);
        if (!e) break;
        const set = step.op === "hide" || step.op === "unhide" ? e.hiddenFrom : e.partialFor;
        if (step.op === "hide" || step.op === "partial") set.add(step.device);
        else set.delete(step.device);
        break;
      }
      case "drop":
        folder.scope(scope).delete(step.file === "latest" ? latest() : step.file);
        break;
      case "sync":
        try {
          const result = await syncScope({ scope, state: d.state, transport: d.transport(run), adapters: d.adapters(), clock: d.clock, device: d.id, now: () => d.time(), options: d.options_() });
          trace.push({ sync: d.id, result });
        } catch (error) {
          trace.push({ sync: d.id, error: String(error.message ?? error) });
        }
        break;
      case "compact":
        try {
          const result = await compact(d.state, d.transport(run), scope, d.id, d.time(), d.options_(), !!step.force);
          trace.push({ compact: d.id, result });
        } catch (error) {
          trace.push({ compact: d.id, error: String(error.message ?? error) });
        }
        break;
      case "relaunch":
        d.state = JSON.parse(JSON.stringify(d.state));
        d.clock = new Clock(d.id, d.clock.last, () => d.time());
        break;
      case "save":
        d.saved = JSON.stringify(d.state);
        d.savedClock = d.clock.last;
        for (const seq of d.journal.keys()) if (seq <= d.state.seq) d.journal.delete(seq);
        break;
      case "crash":
        d.state = JSON.parse(d.saved);
        d.clock = new Clock(d.id, d.savedClock, () => d.time());
        restoreJournal(d.state, [...d.journal.values()], d.clock);
        break;
      default:
        throw new Error(`unknown step ${step.op}`);
    }
  }
  async function runSwift(d, step) {
    switch (step.op) {
      case "onRead":
        d.onRead = step.steps;
        return;
      case "failWrite":
        d.failWrite = step.when;
        return;
      case "hide":
      case "unhide":
      case "partial":
      case "whole": {
        const e = entry(step.file === "latest" ? latest() : step.file);
        if (!e) return;
        const set = step.op === "hide" || step.op === "unhide" ? e.hiddenFrom : e.partialFor;
        if (step.op === "hide" || step.op === "partial") set.add(step.device);
        else set.delete(step.device);
        return;
      }
      case "sync": {
        const reply = await d.converse({ op: "sync", scope }, run, scope);
        trace.push("done" in reply ? { sync: d.id, result: reply.done } : { sync: d.id, error: reply.failed });
        return;
      }
      case "compact": {
        const reply = await d.converse({ op: "compact", scope, force: !!step.force }, run, scope);
        trace.push("done" in reply ? { compact: d.id, result: reply.done } : { compact: d.id, error: reply.failed });
        return;
      }
      default:
        d.local(step);
    }
  }
  try {
    for (const step of script.steps) {
      await run(step);
      trace.push({ step: step.op, devices: [...devices.values()].map((x) => x.record()) });
    }
  } finally {
    for (const d of devices.values()) if (d instanceof SwiftDevice) d.close();
  }
  return trace;
}

function mulberry32(seed) {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function randomScript(seed, steps) {
  const rand = mulberry32(seed);
  const pick = (list) => list[Math.floor(rand() * list.length)];
  const ids = ["a", "b", "c"];
  const keys = ["x:1", "x:2", "x:3", "x:4", "x:é", "set:theme", "set:engine"];
  const value = () => pick([1, "v", { n: Math.floor(rand() * 5) }, [1, 2], { b: 1, a: { z: 2, y: 3 } }, "ünïcode", 0.30000000000000004, true]);
  const options = { compactAfterFiles: 6, compactInterval: 60_000, tombstoneTTL: 5 * 60_000, damagedGiveUp: 10 * 60_000 };
  const script = { name: `random ${seed}`, devices: Object.fromEntries(ids.map((id) => [id, options])), steps: [{ op: "time", now: 1_790_000_000_000 }] };
  if (rand() < 0.5) script.steps.push({ op: "offset", device: pick(ids), ms: Math.floor((rand() - 0.5) * 120_000) });
  for (let i = 0; i < steps; i++) {
    const device = pick(ids);
    const r = rand();
    if (r < 0.3) script.steps.push({ op: "set", device, key: pick(keys), value: value() });
    else if (r < 0.38) script.steps.push({ op: "delete", device, key: pick(keys) });
    else if (r < 0.65) script.steps.push({ op: "sync", device });
    else if (r < 0.75) script.steps.push({ op: "advance", ms: Math.floor(rand() * 90_000) });
    else if (r < 0.79) script.steps.push({ op: pick(["hide", "partial"]), device, file: "latest" });
    else if (r < 0.83) script.steps.push({ op: pick(["unhide", "whole"]), device, file: "latest" });
    else if (r < 0.86) script.steps.push({ op: "save", device });
    else if (r < 0.88) script.steps.push({ op: "crash", device });
    else if (r < 0.9) script.steps.push({ op: "relaunch", device });
    else if (r < 0.92) script.steps.push({ op: "failWrite", device, when: pick(["before", "after"]) });
    else if (r < 0.94) script.steps.push({ op: "compact", device, force: rand() < 0.5 });
    else if (r < 0.96) script.steps.push({ op: "onRead", device, steps: [{ op: "set", device, key: pick(keys), value: value() }] });
    else if (r < 0.97) script.steps.push({ op: "drop", file: "latest" });
    else script.steps.push({ op: "advance", ms: 3 * 3_600_000 });
  }
  for (let round = 0; round < 3; round++) for (const device of ids) script.steps.push({ op: "sync", device });
  return script;
}

export const namedScripts = () => {
  const T = 1_790_000_000_000;
  return [
    {
      name: "concurrent edits converge on the newest",
      devices: { devA: {}, devB: {} },
      steps: [
        { op: "time", now: T },
        { op: "set", device: "devA", key: "x:1", value: "a" },
        { op: "advance", ms: 1 },
        { op: "set", device: "devB", key: "x:1", value: "b" },
        { op: "sync", device: "devB" },
        { op: "sync", device: "devA" },
        { op: "sync", device: "devB" },
        { op: "sync", device: "devA" },
      ],
    },
    {
      name: "deletes, re-adds and edits after deletes",
      devices: { a: {}, b: {} },
      steps: [
        { op: "time", now: T },
        { op: "set", device: "a", key: "x:1", value: 1 },
        { op: "sync", device: "a" },
        { op: "sync", device: "b" },
        { op: "advance", ms: 10 },
        { op: "delete", device: "b", key: "x:1" },
        { op: "sync", device: "b" },
        { op: "advance", ms: 10 },
        { op: "set", device: "a", key: "x:1", value: 2 },
        { op: "sync", device: "a" },
        { op: "sync", device: "b" },
        { op: "sync", device: "a" },
      ],
    },
    {
      name: "clock skew",
      devices: { a: {}, b: {} },
      steps: [
        { op: "time", now: T },
        { op: "offset", device: "a", ms: 3_600_000 },
        { op: "set", device: "a", key: "x:1", value: "ahead" },
        { op: "sync", device: "a" },
        { op: "sync", device: "b" },
        { op: "set", device: "b", key: "x:1", value: "after seeing" },
        { op: "sync", device: "b" },
        { op: "sync", device: "a" },
      ],
    },
    {
      name: "late, partial and pending files",
      devices: { a: {}, b: {} },
      steps: [
        { op: "time", now: T },
        { op: "set", device: "a", key: "x:1", value: 1 },
        { op: "sync", device: "a" },
        { op: "hide", device: "b", file: "latest" },
        { op: "set", device: "a", key: "x:2", value: 2 },
        { op: "sync", device: "a" },
        { op: "partial", device: "b", file: "latest" },
        { op: "sync", device: "b" },
        { op: "unhide", device: "b", file: "f1" },
        { op: "whole", device: "b", file: "f2" },
        { op: "sync", device: "b" },
      ],
    },
    {
      name: "an edit while files are read wins",
      devices: { a: {}, b: {} },
      steps: [
        { op: "time", now: T },
        { op: "set", device: "a", key: "x:1", value: "remote" },
        { op: "sync", device: "a" },
        { op: "onRead", device: "b", steps: [{ op: "set", device: "b", key: "x:1", value: "local" }] },
        { op: "sync", device: "b" },
        { op: "sync", device: "a" },
        { op: "sync", device: "b" },
      ],
    },
    {
      name: "joining adopts remote settings",
      devices: { a: {}, b: {} },
      steps: [
        { op: "time", now: T },
        { op: "set", device: "a", key: "set:theme", value: "dark" },
        { op: "sync", device: "a" },
        { op: "set", device: "b", key: "set:theme", value: "light" },
        { op: "awaitRemote", device: "b" },
        { op: "sync", device: "b" },
        { op: "sync", device: "a" },
      ],
    },
    {
      name: "a failed write is retried as the same batch",
      devices: { a: {}, b: {} },
      steps: [
        { op: "time", now: T },
        { op: "set", device: "a", key: "x:1", value: 1 },
        { op: "failWrite", device: "a", when: "after" },
        { op: "sync", device: "a" },
        { op: "save", device: "a" },
        { op: "crash", device: "a" },
        { op: "sync", device: "a" },
        { op: "sync", device: "b" },
      ],
    },
    {
      name: "compaction and old snapshots",
      devices: { a: { compactAfterFiles: 2, compactInterval: 0, tombstoneTTL: 1000 }, b: { compactAfterFiles: 2, compactInterval: 0, tombstoneTTL: 1000 } },
      steps: [
        { op: "time", now: T },
        { op: "set", device: "a", key: "x:1", value: 1 },
        { op: "sync", device: "a" },
        { op: "set", device: "a", key: "x:2", value: 2 },
        { op: "sync", device: "a" },
        { op: "sync", device: "b" },
        { op: "delete", device: "a", key: "x:1" },
        { op: "sync", device: "a" },
        { op: "advance", ms: 5000 },
        { op: "compact", device: "a", force: true },
        { op: "sync", device: "b" },
        { op: "sync", device: "a" },
      ],
    },
  ];
};

if (process.argv[1] === fileURLToPath(import.meta.url) && option("--mixed", null)) {
  const binary = resolve(option("--mixed", null));
  const scripts = [...namedScripts(), ...Array.from({ length: runs }, (_, i) => randomScript(firstSeed + i, stepsPerRun))];
  let bad = 0;
  let entries = 0;
  for (const script of scripts) {
    const expected = (await runScenario(script)).map((e) => JSON.stringify(e));
    const got = (await runScenario(script, { swift: binary })).map((e) => JSON.stringify(e));
    entries += got.length;
    const at = expected.findIndex((e, i) => e !== got[i]);
    if (at >= 0 || expected.length !== got.length) {
      bad++;
      const i = at >= 0 ? at : Math.min(expected.length, got.length);
      if (bad <= 5) console.log(`${script.name}: entry ${i} differs\n  ts only: ${String(expected[i]).slice(0, 600)}\n  mixed:   ${String(got[i]).slice(0, 600)}`);
    }
  }
  console.log(`${scripts.length - bad} of ${scripts.length} mixed runs trace as the TypeScript-only run (${entries} entries)`);
  process.exit(bad ? 1 : 0);
} else if (process.argv[1] === fileURLToPath(import.meta.url)) {
  mkdirSync(out, { recursive: true });
  const scripts = [...namedScripts(), ...Array.from({ length: runs }, (_, i) => randomScript(firstSeed + i, stepsPerRun))];
  const cases = [];
  for (const script of scripts) cases.push({ script, trace: await runScenario(script) });
  const text = JSON.stringify({ cases });
  writeFileSync(join(out, "scope.json.deflate"), deflateRawSync(Buffer.from(text)));
  console.log(`${cases.length} scenarios, ${cases.reduce((n, c) => n + c.trace.length, 0)} trace entries, ${(text.length / 1e6).toFixed(1)} MB`);
}

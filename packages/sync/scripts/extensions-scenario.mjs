#!/usr/bin/env node
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { deflateRawSync } from "node:zlib";
import { canonical } from "../src/canon.ts";
import { extensionApprovalKey, extensionKey, extensionsAdapter } from "../src/extensions.ts";
import { Clock } from "../src/hlc.ts";
import { compact, emptyScope, syncScope, visible } from "../src/scope.ts";

const HELP = `usage: node packages/sync/scripts/extensions-scenario.mjs [--out <dir>] [--runs <n>] [--steps <n>] [--seed <n>]

Runs extension sync scenarios through the TypeScript adapter (extensions.ts) over the TypeScript merge, with
the fake Chrome of extensions.test.ts, and writes each one with its trace: every payload written, every
removal, every change asked of Chrome, each sync's result or error, and after each step every Mac's scope
state, installed extensions, pending installs, intents and clock. SolaraSyncTests replays the scripts
through the Swift adapter and must produce the same trace byte for byte. Scenarios are the cases of
extensions.test.ts plus seeded random runs of three Macs.
Default out: native/SolaraKit/Tests/SolaraSyncTests/Scenarios.`;

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
const runs = Number(option("--runs", "80"));
const stepsPerRun = Number(option("--steps", "70"));
const firstSeed = Number(option("--seed", "1"));

const E1 = "a".repeat(32);
const E2 = "b".repeat(32);
const E3 = "c".repeat(32);

class Folder {
  files = new Map();
  counter = 0;
  now = 1_000_000;
  store = new Map([
    [E1, { version: "1.0", fingerprint: "tabs" }],
    [E2, { version: "2.0", fingerprint: "storage" }],
    [E3, { version: "3.0", fingerprint: "all-hosts" }],
  ]);
  transport(trace, mac) {
    return {
      write: async (_scope, payload) => {
        const id = `f${++this.counter}`;
        this.files.set(id, payload);
        trace.push({ write: mac, id, payload });
        return id;
      },
      read: async (_scope, known) => ({
        files: [...this.files].filter(([id]) => !known.includes(id)).map(([id, payload]) => ({ id, payload })),
        pending: [],
        damaged: [],
        present: [...this.files.keys()],
      }),
      remove: async (_scope, ids) => {
        trace.push({ remove: mac, ids: [...ids] });
        for (const id of ids) this.files.delete(id);
      },
    };
  }
}

const changeJSON = (c) =>
  c.kind === "cancel"
    ? { kind: c.kind, id: c.id }
    : { kind: c.kind, id: c.id, record: { on: c.record.on, inc: c.record.inc, pin: c.record.pin }, approval: c.approval && { v: c.approval.v, fps: [...c.approval.fps] } };

class Chrome {
  installed = new Map();
  pending = new Map();
  intents = {};
  generation = 0;
  ready = true;
  settling = [];
  queued = [];
  failing = false;
  constructor(folder, mac, trace) {
    this.folder = folder;
    this.mac = mac;
    this.trace = trace;
  }
  userInstall(id, extra = {}) {
    const s = this.folder.store.get(id);
    this.installed.set(id, { id, syncable: true, version: s.version, fingerprint: s.fingerprint, approved: true, userDisabled: false, incognito: false, pinned: false, ...extra });
    this.intents[id] = { kind: "installed", g: ++this.generation };
  }
  userUninstall(id) {
    this.installed.delete(id);
    this.intents[id] = { kind: "uninstalled", g: ++this.generation };
  }
  finishInstalls() {
    for (const [id, change] of this.pending) {
      const s = this.folder.store.get(id);
      const matches = !!change.approval && change.approval.v === s.version && change.approval.fps.includes(s.fingerprint);
      this.installed.set(id, { id, syncable: true, version: s.version, fingerprint: s.fingerprint, approved: matches, userDisabled: !change.record.on, incognito: change.record.inc, pinned: change.record.pin });
    }
    this.pending.clear();
  }
  host(nullRead = false) {
    return {
      read: async () =>
        nullRead
          ? null
          : { ready: this.ready, extensions: [...this.installed.values()].map((e) => ({ ...e })), pending: [...this.pending.keys()], settling: [...this.settling], queued: [...this.queued] },
      change: async (change) => {
        this.trace.push({ change: this.mac, value: changeJSON(change) });
        if (this.failing) return false;
        if (change.kind === "cancel") {
          this.pending.delete(change.id);
          this.queued = this.queued.filter((id) => id !== change.id);
        } else if (change.kind === "install") {
          this.pending.set(change.id, change);
        } else {
          const e = this.installed.get(change.id);
          const grant = !!change.approval && change.approval.v === e.version && change.approval.fps.includes(e.fingerprint);
          this.installed.set(change.id, { ...e, userDisabled: !change.record.on, incognito: change.record.inc, pinned: change.record.pin, approved: e.approved || grant });
        }
        return true;
      },
      intents: () => ({ ...this.intents }),
      settleIntents: (published) => {
        for (const [id, g] of Object.entries(published)) if (this.intents[id]?.g === g) delete this.intents[id];
      },
      keepInstalled: (id) => {
        this.intents[id] = { kind: "installed", g: ++this.generation };
      },
    };
  }
}

class Mac {
  state = emptyScope();
  legacy = false;
  hold = false;
  constructor(id, folder, joining, trace) {
    this.id = id;
    this.folder = folder;
    this.trace = trace;
    this.clock = new Clock(id, null, () => folder.now);
    this.chrome = new Chrome(folder, id, trace);
    this.adapter = extensionsAdapter(this.chrome.host());
    if (joining) this.state.awaitRemote = true;
    else this.state.joined = true;
  }
  adapters() {
    const other = { prefix: "x:", extract: () => ({ values: new Map([[`x:${this.id}`, 1]]), ignore: (k) => k !== `x:${this.id}` }), apply: () => true };
    return this.legacy ? [other] : [this.adapter, other];
  }
  async sync() {
    this.folder.now += 10;
    try {
      const result = await syncScope({ scope: "p", state: this.state, transport: this.folder.transport(this.trace, this.id), adapters: this.adapters(), clock: this.clock, device: this.id, now: () => this.folder.now });
      if (!this.legacy) await this.adapter.reconcile(visible(this.state, "ext:"), this.folder.now);
      this.trace.push({ sync: this.id, result });
    } catch (error) {
      this.trace.push({ sync: this.id, error: String(error.message ?? error) });
    }
    if (!this.hold) this.chrome.finishInstalls();
  }
  record() {
    return {
      mac: this.id,
      state: canonical(this.state),
      installed: canonical([...this.chrome.installed.values()]),
      pending: [...this.chrome.pending.keys()],
      queued: [...this.chrome.queued],
      intents: JSON.parse(JSON.stringify(this.chrome.intents)),
      clock: this.clock.last,
    };
  }
}

export async function runScenario(script) {
  const trace = [];
  const folder = new Folder();
  const macs = new Map();
  for (const [id, joining] of Object.entries(script.macs)) macs.set(id, new Mac(id, folder, joining, trace));
  for (const step of script.steps) {
    const m = macs.get(step.mac);
    switch (step.op) {
      case "install":
        m.chrome.userInstall(step.id, step.extra ?? {});
        break;
      case "uninstall":
        m.chrome.userUninstall(step.id);
        break;
      case "edit": {
        const e = m.chrome.installed.get(step.id);
        if (e) Object.assign(e, step.fields);
        break;
      }
      case "put":
        m.chrome.installed.set(step.id, { ...step.entry });
        break;
      case "clearIntents":
        m.chrome.intents = {};
        break;
      case "store":
        folder.store.set(step.id, { version: step.version, fingerprint: step.fingerprint });
        break;
      case "chrome":
        m.chrome[step.field] = step.value;
        break;
      case "hold":
        m.hold = step.value;
        break;
      case "finish":
        m.chrome.finishInstalls();
        break;
      case "clearPending":
        m.chrome.pending.clear();
        break;
      case "adapter":
        m.adapter = extensionsAdapter(m.chrome.host(!!step.nullRead));
        break;
      case "legacy":
        m.legacy = step.value;
        break;
      case "nullRecord": {
        const key = extensionKey(step.id);
        const h = m.clock.tick();
        m.state.records[key] = { h, v: null, o: [m.id, m.state.seq + 1] };
        m.state.outbox.push({ k: key, h, v: null });
        break;
      }
      case "compact":
        try {
          const result = await compact(m.state, folder.transport(trace, m.id), "p", m.id, folder.now, { pruneGrace: 0 }, true);
          trace.push({ compact: m.id, result });
        } catch (error) {
          trace.push({ compact: m.id, error: String(error.message ?? error) });
        }
        break;
      case "advance":
        folder.now += step.ms;
        break;
      case "sync":
        await m.sync();
        break;
      default:
        throw new Error(`unknown step ${step.op}`);
    }
    trace.push({ step: step.op, macs: [...macs.values()].map((x) => x.record()) });
  }
  return trace;
}

const sync = (...ids) => ids.map((mac) => ({ op: "sync", mac }));
const rounds = (ids, n = 3) => Array.from({ length: n }, () => sync(...ids)).flat();
const install = (mac, id, extra) => ({ op: "install", mac, id, ...(extra ? { extra } : {}) });
const uninstall = (mac, id) => ({ op: "uninstall", mac, id });
const edit = (mac, id, fields) => ({ op: "edit", mac, id, fields });
const clearIntents = (mac) => ({ op: "clearIntents", mac });
const chrome = (mac, field, value) => ({ op: "chrome", mac, field, value });
const two = { devA: false, devB: true };

export const namedScripts = () => [
  { name: "an install carries its state and approval", macs: two, steps: [install("devA", E1, { userDisabled: true, pinned: true, incognito: true }), ...rounds(["devA", "devB"]), ...rounds(["devA", "devB"])] },
  {
    name: "state edits follow and the later edit wins",
    macs: two,
    steps: [
      install("devA", E1),
      ...rounds(["devA", "devB"]),
      edit("devA", E1, { userDisabled: true }),
      ...rounds(["devA", "devB"]),
      edit("devB", E1, { userDisabled: false, pinned: true }),
      ...rounds(["devB", "devA"]),
      edit("devA", E1, { incognito: true }),
      { op: "advance", ms: 100 },
      edit("devB", E1, { incognito: false, pinned: false }),
      ...rounds(["devA", "devB", "devA"]),
    ],
  },
  {
    name: "a removal is a live record and a reinstall wins",
    macs: { devA: false, devB: true, devC: true },
    steps: [
      install("devA", E1),
      install("devA", E2),
      ...rounds(["devA", "devB"]),
      uninstall("devB", E1),
      ...rounds(["devB", "devA"]),
      ...rounds(["devA", "devB", "devC"], 4),
      edit("devA", E1, { pinned: true }),
      ...rounds(["devA", "devB"]),
      uninstall("devA", E1),
      install("devA", E1),
      ...rounds(["devA", "devB", "devC"]),
    ],
  },
  { name: "an uninstall and reinstall before the first publish", macs: two, steps: [install("devA", E1), ...rounds(["devA", "devB"]), uninstall("devA", E1), install("devA", E1), ...rounds(["devA", "devB"])] },
  { name: "turning sync on is a union", macs: two, steps: [install("devA", E1), install("devB", E2, { pinned: true }), clearIntents("devB"), ...rounds(["devA", "devB", "devA"])] },
  {
    name: "a joining Mac takes the synced state",
    macs: two,
    steps: [install("devA", E1, { pinned: true, userDisabled: true }), ...sync("devA"), install("devB", E1), clearIntents("devB"), ...rounds(["devB", "devA"])],
  },
  {
    name: "a newer store version installs without the grant",
    macs: two,
    steps: [
      install("devA", E3),
      ...sync("devA"),
      { op: "store", id: E3, version: "3.1", fingerprint: "all-hosts,downloads" },
      ...rounds(["devB", "devA"]),
      edit("devB", E3, { approved: true }),
      ...rounds(["devB", "devA"]),
    ],
  },
  { name: "other permissions at the same version", macs: two, steps: [install("devA", E3), ...sync("devA"), { op: "store", id: E3, version: "3.0", fingerprint: "all-hosts,history" }, ...rounds(["devB", "devA"])] },
  { name: "a Mac disabled for permissions gets the grant", macs: two, steps: [install("devB", E3, { approved: false }), clearIntents("devB"), ...sync("devB"), install("devA", E3), ...rounds(["devA", "devB"])] },
  {
    name: "null records and ineligible extensions",
    macs: two,
    steps: [
      install("devA", E1),
      ...rounds(["devA", "devB"]),
      { op: "nullRecord", mac: "devA", id: E1 },
      ...rounds(["devA", "devB"]),
      { op: "put", mac: "devB", id: E2, entry: { id: E2, syncable: false, version: "2.0", fingerprint: "storage" } },
      ...rounds(["devB", "devA"]),
      edit("devB", E1, { syncable: false }),
      ...rounds(["devB", "devA"]),
    ],
  },
  { name: "nothing before Chrome is ready", macs: { devA: false }, steps: [install("devA", E1), chrome("devA", "ready", false), ...sync("devA"), chrome("devA", "ready", true), ...sync("devA")] },
  {
    name: "a lost pending install is retried hourly",
    macs: two,
    steps: [
      install("devA", E1),
      ...sync("devA"),
      { op: "hold", mac: "devB", value: true },
      ...sync("devB", "devB"),
      { op: "clearPending", mac: "devB" },
      { op: "adapter", mac: "devB" },
      ...sync("devB"),
      { op: "clearPending", mac: "devB" },
      ...sync("devB"),
      { op: "advance", ms: 3_600_000 },
      ...sync("devB"),
    ],
  },
  {
    name: "a change while an install is pending",
    macs: two,
    steps: [install("devA", E1), ...sync("devA"), { op: "hold", mac: "devB", value: true }, ...sync("devB"), edit("devA", E1, { pinned: true }), ...sync("devA", "devB"), { op: "finish", mac: "devB" }],
  },
  {
    name: "a removal cancels a pending install",
    macs: two,
    steps: [install("devA", E1), ...sync("devA"), { op: "hold", mac: "devB", value: true }, ...sync("devB"), uninstall("devA", E1), ...sync("devA", "devB"), { op: "finish", mac: "devB" }],
  },
  {
    name: "an older Mac keeps the records through its snapshots",
    macs: { devA: false, devOld: true, devC: true },
    steps: [
      { op: "legacy", mac: "devOld", value: true },
      install("devA", E1),
      install("devA", E2),
      ...rounds(["devA", "devOld"]),
      uninstall("devA", E2),
      ...rounds(["devA", "devOld"]),
      { op: "advance", ms: 100 * 86_400_000 },
      { op: "compact", mac: "devOld" },
      { op: "compact", mac: "devOld" },
      install("devC", E2),
      clearIntents("devC"),
      ...rounds(["devC"]),
    ],
  },
  {
    name: "an upgraded Mac holding an unapplied removal",
    macs: two,
    steps: [
      { op: "legacy", mac: "devB", value: true },
      install("devA", E1),
      ...rounds(["devA", "devB"]),
      { op: "put", mac: "devB", id: E1, entry: { id: E1, syncable: true, version: "1.0", fingerprint: "tabs", approved: true, userDisabled: false, incognito: false, pinned: false } },
      uninstall("devA", E1),
      ...rounds(["devA", "devB"]),
      { op: "legacy", mac: "devB", value: false },
      ...rounds(["devB", "devA"]),
    ],
  },
  {
    name: "Chrome's newer permission reading settles",
    macs: two,
    steps: [install("devA", E3), ...rounds(["devA", "devB"]), edit("devB", E3, { fingerprint: "all-hosts,newer-chrome" }), ...rounds(["devB", "devA"]), ...rounds(["devA", "devB"])],
  },
  {
    name: "a settling install isn't published",
    macs: two,
    steps: [install("devA", E1, { pinned: true }), ...rounds(["devA", "devB"]), edit("devB", E1, { pinned: false }), chrome("devB", "settling", [E1]), ...rounds(["devB", "devA"])],
  },
  {
    name: "a framework without the engine calls waits",
    macs: two,
    steps: [
      install("devA", E1),
      ...rounds(["devA"]),
      { op: "adapter", mac: "devB", nullRead: true },
      install("devB", E2),
      ...rounds(["devB", "devA"]),
      { op: "adapter", mac: "devB" },
      ...rounds(["devB", "devA"]),
    ],
  },
  {
    name: "a Mac not ready when it joined keeps its own",
    macs: { devA: false, devB: true, devC: true },
    steps: [
      install("devA", E1),
      ...rounds(["devA"]),
      uninstall("devA", E1),
      ...rounds(["devA"]),
      install("devC", E1),
      clearIntents("devC"),
      chrome("devC", "ready", false),
      ...rounds(["devC"], 2),
      chrome("devC", "ready", true),
      ...rounds(["devC", "devB"]),
    ],
  },
  {
    name: "a refused change stays to apply",
    macs: two,
    steps: [
      install("devA", E1),
      ...rounds(["devA", "devB"]),
      edit("devA", E1, { pinned: true }),
      ...sync("devA"),
      chrome("devB", "failing", true),
      ...rounds(["devB", "devB"]),
      ...rounds(["devA"]),
      chrome("devB", "failing", false),
      ...rounds(["devB", "devA"]),
    ],
  },
  {
    name: "a removal cancels a queued install",
    macs: two,
    steps: [
      install("devA", E1),
      ...sync("devA"),
      { op: "hold", mac: "devB", value: true },
      ...sync("devB"),
      { op: "clearPending", mac: "devB" },
      chrome("devB", "queued", [E1]),
      uninstall("devA", E1),
      ...sync("devA", "devB"),
    ],
  },
];

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
  const flag = () => rand() < 0.5;
  const ids = ["devA", "devB", "devC"];
  const exts = [E1, E2, E3];
  const versions = ["1.0", "1.1", "2.0", "3.0", "3.1", "10.0", "1.0.1", "2", "3.0.0", "0x1", ""];
  const fps = ["tabs", "storage", "all-hosts", "all-hosts,downloads", "all-hosts,history", "z", "é"];
  const script = { name: `random ${seed}`, macs: { devA: false, devB: rand() < 0.7, devC: rand() < 0.7 }, steps: [] };
  for (let i = 0; i < steps; i++) {
    const mac = pick(ids);
    const id = pick(exts);
    const r = rand();
    if (r < 0.12) {
      const extra = {};
      if (rand() < 0.3) extra.userDisabled = flag();
      if (rand() < 0.3) extra.pinned = flag();
      if (rand() < 0.3) extra.incognito = flag();
      if (rand() < 0.15) extra.approved = flag();
      script.steps.push(install(mac, id, Object.keys(extra).length ? extra : undefined));
    } else if (r < 0.18) script.steps.push(uninstall(mac, id));
    else if (r < 0.3) {
      const field = pick(["userDisabled", "pinned", "incognito", "approved", "fingerprint", "syncable", "version"]);
      const value = field === "fingerprint" ? pick(fps) : field === "version" ? pick(versions) : flag();
      script.steps.push(edit(mac, id, { [field]: value }));
    } else if (r < 0.33) script.steps.push({ op: "store", id, version: pick(versions.slice(0, 9)), fingerprint: pick(fps) });
    else if (r < 0.35) script.steps.push(clearIntents(mac));
    else if (r < 0.37) script.steps.push(chrome(mac, "ready", rand() < 0.6));
    else if (r < 0.39) script.steps.push(chrome(mac, "failing", rand() < 0.4));
    else if (r < 0.41) script.steps.push(chrome(mac, "settling", pick([[], [id]])));
    else if (r < 0.43) script.steps.push(chrome(mac, "queued", pick([[], [id]])));
    else if (r < 0.46) script.steps.push({ op: "hold", mac, value: flag() });
    else if (r < 0.48) script.steps.push({ op: "finish", mac });
    else if (r < 0.49) script.steps.push({ op: "clearPending", mac });
    else if (r < 0.51) script.steps.push({ op: "adapter", mac, nullRead: rand() < 0.3 });
    else if (r < 0.52) script.steps.push({ op: "legacy", mac, value: rand() < 0.4 });
    else if (r < 0.53) script.steps.push({ op: "compact", mac });
    else if (r < 0.54) script.steps.push({ op: "nullRecord", mac, id });
    else if (r < 0.6) script.steps.push({ op: "advance", ms: pick([1000, 60_000, 3_600_000, 50 * 86_400_000]) });
    else script.steps.push({ op: "sync", mac });
  }
  for (const mac of ids)
    script.steps.push(chrome(mac, "ready", true), chrome(mac, "failing", false), { op: "hold", mac, value: false }, { op: "legacy", mac, value: false }, { op: "adapter", mac });
  script.steps.push(...rounds(ids));
  return script;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  mkdirSync(out, { recursive: true });
  const scripts = [...namedScripts(), ...Array.from({ length: runs }, (_, i) => randomScript(firstSeed + i, stepsPerRun))];
  const cases = [];
  for (const script of scripts) cases.push({ script, trace: await runScenario(script) });
  const text = JSON.stringify({ cases });
  writeFileSync(join(out, "extensions.json.deflate"), deflateRawSync(Buffer.from(text)));
  const changes = cases.reduce((n, c) => n + c.trace.filter((e) => "change" in e).length, 0);
  const errors = cases.reduce((n, c) => n + c.trace.filter((e) => "error" in e).length, 0);
  console.log(`${cases.length} scenarios, ${cases.reduce((n, c) => n + c.trace.length, 0)} trace entries, ${changes} Chrome changes, ${errors} errors, ${(text.length / 1e6).toFixed(1)} MB`);
}

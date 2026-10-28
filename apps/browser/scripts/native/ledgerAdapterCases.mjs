#!/usr/bin/env node
import { readFileSync, writeFileSync } from "node:fs";
import { registerHooks } from "node:module";
import { deflateRawSync } from "node:zlib";
import { pinSources } from "../../../../packages/sync/scripts/pinSources.mjs";
import { RC_VALUES } from "./ledgerCases.mjs";

const HELP = `usage: node --import ./src/test-loader.mjs scripts/native/ledgerAdapterCases.mjs [--out <file>] [--runs <n>] [--seed <n>]

Records the password ledger adapter (ledgerPasswords.ts) over seeded random sessions: one adapter per
session takes a run of operations (extract, apply, published, resolveHeld, held) against a simulated
Login Data, ledger document and mark, with read failures, unopened values, refused saves, a mark that
throws, NFC and NFD usernames and mass deletions mixed in. Each operation keeps every host call in
order with its answer, the operation's result and the adapter's memory after it.
SolaraSyncTests replays each session through LedgerPasswordsAdapter with a host that answers from
the recording and must make the same calls and give the same results.
Default out: native/SolaraKit/Tests/SolaraSyncTests/Cases/ledgerAdapter.json.deflate.`;

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
const source = "apps/browser/src/sync/ledgerPasswords.ts";
const out = option("--out", new URL("native/SolaraKit/Tests/SolaraSyncTests/Cases/ledgerAdapter.json.deflate", root).pathname);
const runs = Number(option("--runs", "600"));
const firstSeed = Number(option("--seed", "1"));

const REWRITES = [
  ['import { deletePassword, engineCall } from "@ardia/ardiacore";', "const deletePassword = (...a) => globalThis.__ledgerHost.deletePassword(...a);\nconst engineCall = (...a) => globalThis.__ledgerHost.engineCall(...a);"],
  ['import { readDocument, readDocumentResult, writeDocument } from "@ardia/shell";', "const readDocument = (...a) => globalThis.__ledgerHost.readDocument(...a);\nconst readDocumentResult = (...a) => globalThis.__ledgerHost.readDocumentResult(...a);\nconst writeDocument = (...a) => globalThis.__ledgerHost.writeDocument(...a);"],
  ["await new Promise((r) => setTimeout(r, 250));", "await globalThis.__ledgerHost.sleep(250);"],
  [
    "  return {\n    held: () => held.size,",
    "  return {\n    __memory: () => ({ lastRead, quietUntil, unconfirmed: [...unconfirmed], claimed: [...claimed], held: [...held], heldDigests: [...heldDigests], confirmed: [...confirmed], restoring: [...restoring], judgedForFolder: [...judgedForFolder] }),\n    held: () => held.size,",
  ],
];
const original = readFileSync(new URL(source, root), "utf8");
for (const [from] of REWRITES) if (!original.includes(from)) throw new Error(`ledgerPasswords.ts no longer has: ${from.split("\n")[0]}`);
registerHooks({
  load(url, context, next) {
    const loaded = next(url, context);
    if (!url.endsWith("/src/sync/ledgerPasswords.ts") || loaded.source == null) return loaded;
    let text = typeof loaded.source === "string" ? loaded.source : new TextDecoder().decode(loaded.source);
    for (const [from, to] of REWRITES) text = text.replace(from, to);
    return { ...loaded, source: text };
  },
});
await import(new URL("apps/browser/src/store/browser.ts", root).href);
const { ledgerPasswordsAdapter } = await import(new URL(source, root).href);

function mulberry32(seed) {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const ORIGINS = ["https://a.example", "https://b.example"];
const USERS = ["bob", "josé", "josé", "al"];
const SECRETS = ["s1", "s2", "s3"];
const LEDGER = "sync-pw-ledger.json";
const hlc = (wall, counter, device) => `${wall.toString(36).padStart(9, "0")}.${counter.toString(36).padStart(4, "0")}.${device}`;

export async function randomSession(seed) {
  const rand = mulberry32(seed);
  const pick = (list) => list[Math.floor(rand() * list.length)];
  const chance = (p) => rand() < p;
  const pairs = ORIGINS.flatMap((o) => USERS.map((u) => [o, u]));
  const keyOf = (o, u) => `pw:${o}\n${u}`;
  const universe = pairs.map(([o, u]) => keyOf(o, u));
  const valueOf = (key, s) => {
    const nl = key.indexOf("\n");
    return { o: key.slice(3, nl), u: key.slice(nl + 1), s };
  };
  let now = 1_790_000_000_000 + Math.floor(rand() * 1e9);
  const forcedAlways = chance(0.8);
  const scope = pick(["s", "s", "s", "t"]);
  const store = new Map();
  const filled = chance(0.5) ? 0.9 : 0.6;
  for (const key of universe) if (chance(filled)) store.set(key, { s: pick(SECRETS), created: now - Math.floor(rand() * 1e8), modified: chance(0.7) ? now - Math.floor(rand() * 1e8) : null });
  let mark = chance(0.3) ? `${1 + Math.floor(rand() * 3)}@${now - Math.floor(rand() * 1e8)}` : null;
  const docs = new Map();
  if (chance(0.2)) docs.set(LEDGER, pick(['{"v":2,"profiles":{}}', '{"v":1,"profiles":{}}', "{", '{"v":2,"profiles":{"A":{"v":1,"L":1,"t":5,"keys":{},"scope":"t","held":[],"gated":{}}}}']));
  let readFailures = 0;
  let markThrows = 0;
  let missing = false;
  const unopened = new Set();
  const refused = new Set();
  const unsettled = new Set();
  let log = null;
  const call = (n, a, run) => {
    const entry = { n, a };
    log?.push(entry);
    try {
      const r = run();
      if (r !== undefined) entry.r = r;
      return r;
    } catch (error) {
      entry.throw = String(error.message ?? error);
      throw error;
    }
  };
  const loginsNow = () => [...store].map(([key, l]) => ({ origin: valueOf(key).o, username: valueOf(key).u, s: l.s, ...(l.created === null ? {} : { created: l.created }), ...(l.modified === null ? {} : { modified: l.modified }) }));
  globalThis.__ledgerHost = {
    deletePassword: async (profile, origin, username) =>
      call("deletePassword", [profile, origin, username], () => {
        const key = keyOf(origin, username);
        if (refused.has(key)) return false;
        if (!unsettled.has(key)) store.delete(key);
        return true;
      }),
    engineCall: async (name, profile, value) =>
      call("writeMark", [profile, value.value], () => {
        if (name !== "ac_passwords_mark" || value.key !== "solara_sync_ledger") throw new Error(`unexpected engine call ${name}`);
        if (markThrows > 0) {
          markThrows--;
          throw new Error("mark refused");
        }
        mark = value.value;
        return undefined;
      }),
    readDocument: (name) => call("readDocument", [name], () => docs.get(name) ?? null),
    readDocumentResult: (name) =>
      call("readLedgerDocument", [], () => {
        if (name !== LEDGER) throw new Error(`unexpected document ${name}`);
        if (readFailures > 0) {
          readFailures--;
          return { failure: "EIO" };
        }
        return docs.has(name) ? { contents: docs.get(name) } : {};
      }),
    writeDocument: (name, contents) =>
      call("writeLedgerDocument", [contents], () => {
        if (name !== LEDGER) throw new Error(`unexpected document ${name}`);
        docs.set(name, contents);
        return undefined;
      }),
    sleep: async (ms) => call("sleep", [ms], () => undefined),
  };
  const readMarked = async (profile) => call("readMarked", [profile], () => (missing ? null : { logins: loginsNow(), mark }));
  const sealed = {
    check: async (values) => call("checkSealed", [values], () => values.map((v) => !unopened.has(keyOf(v.o, v.u)))),
    save: async (profile, o, u, s, replacing) =>
      call("saveSealed", [profile, o, u, s, replacing], () => {
        const key = keyOf(o, u);
        if (refused.has(key)) return false;
        if (!unsettled.has(key)) store.set(key, { s, created: now, modified: now });
        return true;
      }),
  };
  const realNow = Date.now;
  Date.now = () => now;
  let forced = true;
  const adapter = ledgerPasswordsAdapter("A", () => forced, readMarked, () => scope, sealed);

  const remote = new Map();
  for (const key of universe) if (chance(0.5)) remote.set(key, { v: chance(0.8) ? valueOf(key, pick(SECRETS)) : null, h: hlc(Math.floor((now - Math.floor(rand() * 1e8)) / 1), Math.floor(rand() * 3), pick(["dA", "dB"])) });
  const base = new Map();
  for (const key of universe) if (chance(0.4)) base.set(key, chance(0.15) ? pick(RC_VALUES)(key) : valueOf(key, pick(SECRETS)));
  for (const [key, r] of remote) if (r.v && chance(0.15)) r.v = pick(RC_VALUES)(key);
  const unapplied = new Set(universe.filter(() => chance(0.1)));
  let lastExtraction = null;
  const ops = [];
  const count = 4 + Math.floor(rand() * 10);
  try {
    for (let i = 0; i < count; i++) {
      now += pick([0, 1000, 31_000, 120_000]);
      if (chance(0.3)) {
        const key = pick(universe);
        if (chance(0.3)) store.delete(key);
        else store.set(key, { s: pick(SECRETS), created: now, modified: chance(0.8) ? now : null });
      }
      if (chance(0.08)) for (const key of universe) if (chance(0.85)) store.delete(key);
      if (chance(0.1)) for (const key of universe) if (chance(0.9)) store.set(key, { s: `${pick(SECRETS)}m`, created: now, modified: now });
      if (chance(0.2)) {
        const key = pick(universe);
        remote.set(key, { v: chance(0.75) ? (chance(0.15) ? pick(RC_VALUES)(key) : valueOf(key, pick(SECRETS))) : null, h: hlc(now - Math.floor(rand() * 1e6), Math.floor(rand() * 3), pick(["dA", "dB"])) });
      }
      readFailures = chance(0.1) ? 1 + Math.floor(rand() * 3) : 0;
      markThrows = chance(0.08) ? 1 : 0;
      missing = chance(0.05);
      unopened.clear();
      if (chance(0.15)) unopened.add(pick(universe));
      refused.clear();
      if (chance(0.1)) refused.add(pick(universe));
      unsettled.clear();
      if (chance(0.1)) unsettled.add(pick(universe));
      if (chance(0.05)) mark = pick([null, "junk", `${1 + Math.floor(rand() * 4)}@${now}`]);
      forced = forcedAlways || chance(0.5);
      const setup = { now, store: loginsNow(), mark, doc: docs.get(LEDGER) ?? null };
      const roll = rand();
      let op;
      log = [];
      const memoryBefore = adapter.__memory();
      if (roll < 0.5 || !lastExtraction) {
        const context = {
          base: [...base],
          remote: [...remote].map(([k, r]) => [k, r.v]),
          stamp: [...remote].map(([k, r]) => [k, r.h]),
          downloading: chance(0.3),
          agreedKeys: [...base.keys()].filter((k) => !unapplied.has(k)),
          unapplied: [...unapplied],
        };
        let result;
        try {
          const extraction = await adapter.extract(
            (k) => base.get(k),
            () => false,
            now,
            (k) => remote.has(k),
            (k) => remote.get(k)?.v,
            (k) => remote.get(k)?.h,
            () => context.downloading,
            () => context.agreedKeys,
            (k) => unapplied.has(k),
          );
          if (extraction) lastExtraction = extraction;
          result = extraction
            ? {
                values: [...extraction.values],
                ignore: universe.filter((k) => extraction.ignore(k)),
                republish: universe.filter((k) => extraction.republish(k)),
                remove: [...extraction.remove],
                stamp: universe.flatMap((k) => {
                  const s = extraction.stamp(k);
                  return s ? [[k, { at: s.at, after: s.after ?? null }]] : [];
                }),
                reapply: [...extraction.reapply],
              }
            : null;
        } catch (error) {
          result = { throw: String(error.message ?? error) };
        }
        op = { op: "extract", context, result };
      } else if (roll < 0.75) {
        const changed = universe.filter(() => chance(0.4));
        const visible = changed.flatMap((k) => (chance(0.7) ? [[k, chance(0.15) ? pick(RC_VALUES)(k) : valueOf(k, pick(SECRETS))]] : []));
        let result;
        try {
          const written = await adapter.apply(new Map(visible), changed);
          result = written === false ? false : [...written];
        } catch (error) {
          result = { throw: String(error.message ?? error) };
        }
        op = { op: "apply", visible, changed, result };
      } else if (roll < 0.85) {
        const keys = universe.filter(() => chance(0.4));
        lastExtraction.published(keys);
        for (let t = 0; t < 20; t++) await new Promise((r) => setTimeout(r, 0));
        op = { op: "published", keys, result: null };
      } else {
        const choice = pick(["confirm", "restore"]);
        adapter.resolveHeld(choice);
        op = { op: "resolveHeld", choice, result: null };
      }
      for (let t = 0; t < 5; t++) await new Promise((r) => setTimeout(r, 0));
      ops.push({ ...op, setup, forced, memoryBefore, hostCalls: log, held: adapter.held(), memory: adapter.__memory() });
      log = null;
    }
  } finally {
    Date.now = realNow;
  }
  return { seed, scope, ops };
}

if (process.argv[1] === new URL(import.meta.url).pathname) {
  const sessions = [];
  for (let i = 0; i < runs; i++) sessions.push(await randomSession(firstSeed + i));
  const text = JSON.stringify({ sessions });
  writeFileSync(out, deflateRawSync(Buffer.from(text)));
  if (!option("--out", null)) pinSources("Cases/ledgerAdapter.json.deflate", [source, "apps/browser/src/sync/passwordLedger.ts"]);
  const ops = sessions.flatMap((s) => s.ops);
  const by = (f) => ops.reduce((m, o) => ((m[f(o)] = (m[f(o)] ?? 0) + 1), m), {});
  console.log(`${sessions.length} sessions, ${ops.length} operations, ${(text.length / 1e6).toFixed(1)} MB`);
  console.log(`operations ${JSON.stringify(by((o) => o.op))}`);
  console.log(`held at some point: ${ops.filter((o) => o.held > 0).length}; extracts that threw: ${ops.filter((o) => o.result?.throw).length}; nil extracts: ${ops.filter((o) => o.op === "extract" && o.result === null).length}`);
  console.log(`unreadable reads: ${ops.filter((o) => o.hostCalls.some((c) => c.r?.failure)).length}; mark throws: ${ops.filter((o) => o.hostCalls.some((c) => c.throw)).length}`);
}

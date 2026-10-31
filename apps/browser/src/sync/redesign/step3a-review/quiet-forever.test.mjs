import assert from "node:assert/strict";
import { test } from "node:test";
import { fixedBy } from "../switchOn.mjs";
await import("../../../store/browser.ts");
const { Clock, emptyScope, syncScope } = await import("@solara/sync");
const { ledgerPasswordsAdapter } = await import("../../../sync/ledgerPasswords.ts");
const stub = await import("../../../test-native/index.ts");
const { plainOf, sealMarked, sealedCalls } = await import("../fakeSeal.mjs");

let clockNow = 1_800_000_000_000;
const realNow = Date.now;
const realTimeout = globalThis.setTimeout;
const marks = new Map();
globalThis.acTestEngineCall = (name, profile, args) => {
  if (name !== "ac_passwords_mark") return {};
  marks.set(profile, args.value);
  return { ok: true };
};
function folder() {
  const files = new Map();
  let n = 0;
  return {
    write: async (scope, payload) => (files.set(`f${++n}`, { scope, payload }), `f${n}`),
    read: async (scope, known) => {
      const shown = [...files].filter(([, f]) => f.scope === scope);
      return { files: shown.filter(([id]) => !known.includes(id)).map(([id, f]) => ({ id, payload: f.payload })), pending: [], damaged: [], present: shown.map(([id]) => id) };
    },
    remove: async () => {},
  };
}
const LOGIN = "https://site.example\nme";
const KEY = `pw:${LOGIN}`;
const login = (password) => ({ origin: "https://site.example/", url: "https://site.example", username: "me", password, created: clockNow, modified: clockNow });
function device(id, transport, slowChrome) {
  stub.passwordStores.set(id, new Map());
  const state = emptyScope();
  state.joined = true;
  const clock = new Clock(id);
  let forced = true;
  let reads = 0;
  const readMarked = async (profile) => {
    stub.current.device = id;
    reads++;
    const logins = [...stub.passwordStores.get(id).values()].map((l) => ({ ...l }));
    return { logins, mark: marks.get(profile) ?? null };
  };
  const pw = ledgerPasswordsAdapter(id, () => forced, sealMarked(readMarked), () => "s", sealedCalls(() => stub.solaraCoreNativeModules.SolaraCEF));
  return {
    state,
    store: () => stub.passwordStores.get(id),
    setForced: (v) => (forced = v),
    sync: async () => {
      stub.current.device = id;
      return syncScope({ scope: "s", state, transport, adapters: [pw], clock, device: id, now: () => clockNow, options: { writtenKeysOnly: true } });
    },
  };
}


test("QUIET-forever: one login Chrome never confirms keeps the quiet window open for good, so an edit here is never published", fixedBy("step 3"), async () => {
  Date.now = () => clockNow;
  globalThis.setTimeout = (fn, ms, ...a) => (ms === 250 ? ((clockNow += 250), Promise.resolve().then(() => fn(...a)), 0) : realTimeout(fn, ms, ...a));
  try {
    const transport = folder();
    const a = device("A2", transport);
    const b = device("B2", transport);
    a.store().set(LOGIN, login("agreed"));
    await a.sync();
    clockNow += 1000;
    await b.sync();
    clockNow += 40_000;
    await a.sync();
    a.setForced(false);
    const store = a.store();
    const realSet = store.set;
    store.set = function (k, v) { return k.includes("stuck") ? this : realSet.call(this, k, v); };
    b.store().set("https://site.example\nstuck", { ...login("never lands"), username: "stuck" });
    clockNow += 1000;
    await b.sync();
    for (let cycle = 0; cycle < 4; cycle++) { clockNow += 15_000; await a.sync(); }
    a.store().set(LOGIN, login("edited on A"));
    for (let cycle = 0; cycle < 20; cycle++) { clockNow += 15_000; await a.sync(); }
    store.set = realSet;
    assert.equal(plainOf(a.state.records[KEY]?.v), "edited on A", `the edit here is published within 5 minutes (record has ${plainOf(a.state.records[KEY]?.v)})`);
  } finally {
    Date.now = realNow;
    globalThis.setTimeout = realTimeout;
  }
});

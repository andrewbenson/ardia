import assert from "node:assert/strict";
import { test } from "node:test";
await import("../../store/browser.ts");
const { Clock, emptyScope, syncScope } = await import("@solara/sync");
const adapters = await import("../adapters.ts");
const stub = await import("../../test-native/index.ts");
const { syncRedesign } = await import("../redesignSwitch.ts");

let clockNow = 1_800_000_000_000;
const realNow = Date.now;
const realTimeout = globalThis.setTimeout;
function fakeTime() {
  Date.now = () => clockNow;
  globalThis.setTimeout = (fn, ms, ...a) => (ms === 250 ? (clockNow += 250, Promise.resolve().then(() => fn(...a)), 0) : realTimeout(fn, ms, ...a));
}
function realTime() {
  Date.now = realNow;
  globalThis.setTimeout = realTimeout;
}

function folder() {
  const files = new Map();
  let n = 0;
  return {
    write: async (scope, payload) => {
      const id = `f${++n}`;
      files.set(id, { scope, payload });
      return id;
    },
    read: async (scope, known) => {
      const shown = [...files].filter(([, f]) => f.scope === scope);
      return { files: shown.filter(([id]) => !known.includes(id)).map(([id, f]) => ({ id, payload: f.payload })), pending: [], damaged: [], present: shown.map(([id]) => id) };
    },
    remove: async () => {},
  };
}

const LOGIN = "https://site.example\nme";
const KEY = `pw:${LOGIN}`;
const login = (password) => ({ origin: "https://site.example/", url: "https://site.example", username: "me", password, created: 1 });

function device(id, transport) {
  stub.passwordStores.set(id, new Map());
  const state = emptyScope();
  state.joined = true;
  const clock = new Clock(id);
  let forced = true;
  const pw = adapters.passwordsAdapter(`p-${id}`, () => forced, stub.readLogins);
  return {
    state,
    store: () => stub.passwordStores.get(id),
    setForced: (v) => (forced = v),
    sync: async (writtenKeysOnly) => {
      stub.current.device = id;
      syncRedesign.on = writtenKeysOnly;
      return syncScope({ scope: "s", state, transport, adapters: [pw], clock, device: id, now: () => clockNow, options: { writtenKeysOnly } });
    },
  };
}

async function scenario(writtenKeysOnly) {
  fakeTime();
  try {
    const transport = folder();
    const a = device("A", transport);
    const b = device("B", transport);
    a.store().set(LOGIN, login("agreed"));
    await a.sync(writtenKeysOnly);
    clockNow += 1000;
    await b.sync(writtenKeysOnly);
    assert.equal(b.store().get(LOGIN)?.password, "agreed", "setup: B has the agreed login");
    clockNow += 40_000;
    await a.sync(writtenKeysOnly);
    a.setForced(false);
    a.store().set(LOGIN, login("edited on A"));
    clockNow += 1000;
    b.store().set(LOGIN, login("edited on B"));
    await b.sync(writtenKeysOnly);
    clockNow += 1000;
    await a.sync(writtenKeysOnly);
    for (let cycle = 0; cycle < 20; cycle++) {
      clockNow += 15_000;
      await a.sync(writtenKeysOnly);
    }
    const published = (a.state.records[KEY]?.v ?? {}).p;
    return { onA: a.store().get(LOGIN)?.password, record: published, unapplied: a.state.unapplied.includes(KEY) };
  } finally {
    syncRedesign.on = false;
    realTime();
  }
}

test("control, switch off: A's kept edit is published within a few 15 s cycles", async () => {
  const r = await scenario(false);
  assert.equal(r.onA, "edited on A");
  assert.equal(r.record, "edited on A");
});

test("switch on: a password kept here is published, not re-applied every 15 s cycle with each run extending the 30 s quiet", async () => {
  const r = await scenario(true);
  assert.equal(r.onA, "edited on A");
  assert.equal(r.unapplied, false, `still unapplied after 5 minutes of cycles; record holds ${JSON.stringify(r.record)}`);
  assert.equal(r.record, "edited on A");
});

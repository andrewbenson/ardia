import assert from "node:assert/strict";
import { test } from "node:test";
const { useBrowser } = await import("../../store/browser.ts");
const { Clock, emptyScope, syncScope } = await import("@solara/sync");
const adapters = await import("../adapters.ts");
const pinnedArea = await import("../pinned.ts");
const stub = await import("../../test-native/index.ts");

const S = () => useBrowser.getState();

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

function mac(id, transport, apply) {
  const store = new Map();
  const state = emptyScope();
  state.joined = true;
  const clock = new Clock(id);
  const adapter = { prefix: "k:", extract: () => ({ values: new Map(store) }), apply: (visible, changed) => apply(store, visible, changed) };
  return { store, state, sync: (options = {}) => syncScope({ scope: "s", state, transport, adapters: [adapter], clock, device: id, options }) };
}

async function oneKeyKept(writtenKeysOnly) {
  const transport = folder();
  const b = mac("devB", transport, (store, visible, changed) => {
    for (const k of changed) visible.has(k) ? store.set(k, visible.get(k)) : store.delete(k);
  });
  let keep = true;
  const a = mac("devA", transport, (store, visible, changed) => {
    const written = new Set();
    for (const k of changed) {
      if (keep && k === "k:two") continue;
      visible.has(k) ? store.set(k, visible.get(k)) : store.delete(k);
      written.add(k);
    }
    return written;
  });
  b.store.set("k:one", 1);
  b.store.set("k:two", 2);
  await b.sync();
  await a.sync({ writtenKeysOnly });
  const after = { base: Object.keys(a.state.base).sort(), unapplied: [...a.state.unapplied].sort() };
  keep = false;
  await a.sync({ writtenKeysOnly });
  return { after, later: { base: Object.keys(a.state.base).sort(), unapplied: [...a.state.unapplied], two: a.store.get("k:two") } };
}

test("with written keys on, a key the adapter didn't write gets no base and stays unapplied, and is applied once written", async () => {
  const { after, later } = await oneKeyKept(true);
  assert.deepEqual(after, { base: ["k:one"], unapplied: ["k:two"] });
  assert.deepEqual(later, { base: ["k:one", "k:two"], unapplied: [], two: 2 });
});

test("with written keys off, a returned set means every key was applied, as before", async () => {
  const { after } = await oneKeyKept(false);
  assert.deepEqual(after, { base: ["k:one", "k:two"], unapplied: [] });
});

test("the passwords adapter reports a login it kept over the folder's as not written, and an already-equal one as written", async () => {
  stub.current.device = "pwStep1";
  const here = new Map([
    ["https://kept.example\nme", { origin: "https://kept.example/", url: "https://kept.example", username: "me", password: "changed here", created: 1 }],
    ["https://equal.example\nme", { origin: "https://equal.example/", url: "https://equal.example", username: "me", password: "same", created: 1 }],
  ]);
  stub.passwordStores.set("pwStep1", here);
  const pw = adapters.passwordsAdapter("default", () => true, stub.readLogins);
  const kept = "pw:https://kept.example\nme";
  const equal = "pw:https://equal.example\nme";
  const visible = new Map([
    [kept, { o: "https://kept.example", u: "me", p: "from the folder" }],
    [equal, { o: "https://equal.example", u: "me", p: "same" }],
  ]);
  const base = (k) => (k === kept ? { o: "https://kept.example", u: "me", p: "agreed earlier" } : undefined);
  const written = await pw.apply(visible, new Set([kept, equal]), base, { known: () => true, now: Date.now(), horizon: 0, joined: true });
  assert.ok(written instanceof Set);
  assert.deepEqual([...written], [equal]);
  assert.equal(here.get("https://kept.example\nme").password, "changed here", "control: the local change was kept");
});

test("the pinned homes adapter reports a home kept over the folder's as not written", () => {
  S().hydrate({});
  const w = S().createWindow({ url: "https://home.example/" });
  const m = S().newTab(w, { url: "https://start.example/", background: true });
  S().groupTabs([m], { pinned: true, name: "Reading" });
  const homes = pinnedArea.pinnedAreaAdapters("default").find((a) => a.prefix === "pgh:");
  const key = `pgh:${m}`;
  const absent = "pgh:not-here";
  const written = homes.apply(
    new Map([[key, "https://remote.example/"], [absent, "https://elsewhere.example/"]]),
    new Set([key, absent]),
    (k) => (k === key ? "https://older.example/" : undefined),
    { known: () => true, now: Date.now(), horizon: 0, joined: true },
  );
  assert.ok(written instanceof Set);
  assert.deepEqual([...written], [absent]);
  assert.equal(S().tabs[m].pinnedUrl, "https://start.example/", "control: the home chosen here stands");
});

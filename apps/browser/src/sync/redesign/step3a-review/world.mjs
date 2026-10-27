import "../switchOn.mjs";
import * as H from "../harness.mjs";
export * from "../harness.mjs";
const { shell, reset, native, realReadPasswords, realSetTimeout, loginDataMark, settle } = H;
export const SITE = "https://site.example";
export const loginKey = (user) => `${SITE}\n${user}`;
export const syncKey = (user) => `pw:${loginKey(user)}`;
export const login = (user, password, modified) => ({ origin: `${SITE}/`, url: `${SITE}/`, username: user, password, created: modified, modified });
export const LEDGER = "sync-pw-ledger.json";
export async function world(run) {
  reset();
  const here = new Map();
  const w = { here, offset: 0, readable: true };
  shell.passwordStores.set(null, here);
  const shown = () => [...here.values()].map((l) => ({ ...l, modified: l.modified ?? l.created }));
  const realReadMarked = native.readPasswordsWithMark;
  native.readPasswords = async () => (w.readable ? shown() : null);
  native.readPasswordsWithMark = async () => (w.readable ? { logins: shown(), mark: loginDataMark.value } : null);
  const realST = globalThis.setTimeout;
  const realNow = Date.now;
  const timers = new Map();
  let nextTimer = 1;
  const realCT = globalThis.clearTimeout;
  const engineRev = () => Number(/engine\.ts\?rev(\d+)/.exec(new Error().stack ?? "")?.[1] ?? 0);
  globalThis.setTimeout = (fn, ms) => {
    if (ms === 250) return realSetTimeout(fn, 0);
    if (ms !== 15_000 && ms !== 3_000 && ms !== 0) return 0;
    const rev = engineRev();
    if (!rev) return 0;
    const id = nextTimer++;
    timers.set(id, { fn, rev });
    return id;
  };
  globalThis.clearTimeout = (id) => (timers.has(id) ? timers.delete(id) : realCT(id));
  w.unforced = async (n = 1, seconds = 15) => {
    for (let i = 0; i < n; i++) {
      w.offset += seconds * 1000;
      const live = H.launchRev();
      const due = [...timers].filter(([, t]) => t.rev === live);
      for (const [id] of [...timers]) timers.delete(id);
      if (!due.length) throw new Error(`the last launched engine (rev ${live}) scheduled no sync cycle`);
      for (const [, t] of due) {
        t.fn();
        await settle(60);
      }
    }
  };
  Date.now = () => realNow() + w.offset;
  w.later = (minutes = 1) => (w.offset += minutes * 60_000);
  w.cycles = async (engine, n = 3) => {
    for (let i = 0; i < n; i++) {
      w.later();
      await engine.syncNow();
      await settle(60);
    }
  };
  w.ledger = () => JSON.parse(shell.docs.get(LEDGER) ?? "null")?.profiles?.[""] ?? null;
  try {
    await run(w);
  } finally {
    Date.now = realNow;
    globalThis.setTimeout = realST;
    globalThis.clearTimeout = realCT;
    native.readPasswords = realReadPasswords;
    native.readPasswordsWithMark = realReadMarked;
  }
}

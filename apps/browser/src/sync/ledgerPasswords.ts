import { deletePassword, engineCall, savePassword } from "@ardia/ardiacore";
import { readDocument, writeDocument } from "@ardia/shell";
import { DOWNLOAD_HOLD_MS, type Adapter, type MarkedLogins } from "@ardia/sync";
import { engineProfile } from "../store/model";
import { originOf } from "./adapters";
import { isObject } from "./readable";
import { digestOf, formatMark, judge, nextLedger, parseMark, type FolderRecord, type Ledger, type LedgerValue, type LocalLogin, type Mark } from "./passwordLedger";

const LEDGER_DOC = "sync-pw-ledger.json";
const MARK_KEY = "solara_sync_ledger";
const READ_INTERVAL = 30_000;
const MASS_CHANGE_AT_LEAST = 5;

type Stored = Ledger & { scope?: string; held?: string[]; gated?: Record<string, number> };
type LedgerDoc = { v: 1; profiles: Record<string, Stored> };

export function readLedgerDoc(text: string | null): LedgerDoc | "newer" {
  try {
    const doc = JSON.parse(text ?? "null") as LedgerDoc | null;
    if (isObject(doc) && "v" in doc && doc.v !== 1) return "newer";
    return doc?.v === 1 && doc.profiles ? doc : { v: 1, profiles: {} };
  } catch {
    return { v: 1, profiles: {} };
  }
}

export const ledgerFromNewerVersion = () => readLedgerDoc(readDocument(LEDGER_DOC)) === "newer";

function readLedgers(): LedgerDoc {
  const doc = readLedgerDoc(readDocument(LEDGER_DOC));
  return doc === "newer" ? { v: 1, profiles: {} } : doc;
}

type Read = { local: Map<string, LocalLogin>; mark: Mark | null };

export type HeldPasswords = { held: () => number; resolveHeld: (choice: "restore" | "confirm") => void };

export function ledgerPasswordsAdapter(
  profileId: string,
  forced: () => boolean,
  readMarked: (engineProfile: string) => Promise<MarkedLogins | null | undefined>,
  ledgerScope: () => string,
): Adapter & HeldPasswords {
  const profile = () => engineProfile(profileId);
  const keyOf = (origin: string, username: string) => `pw:${origin}\n${username}`;
  let lastRead = 0;
  let quietUntil = 0;
  let unconfirmed = new Set<string>();
  let claimed = new Set<string>();
  let held = new Set<string>();
  let heldDigests = new Map<string, string>();
  let confirmed = new Set<string>();
  let restoring = new Map<string, string>();
  let judgedForFolder = new Set<string>();
  let writing: Promise<void> = Promise.resolve();

  const read = async (): Promise<Read | null> => {
    const marked = await readMarked(profile());
    if (!marked) return null;
    const local = new Map<string, LocalLogin>();
    for (const l of marked.logins) {
      const origin = originOf(l);
      if (origin) local.set(keyOf(origin, l.username), { value: { o: origin, u: l.username, p: l.password }, modified: l.modified ?? l.created });
    }
    return { local, mark: parseMark(marked.mark) };
  };

  const storedOf = () => readLedgers().profiles[profile()] ?? null;
  const rejoined = () => {
    const stored = storedOf();
    return !!stored && stored.scope !== undefined && stored.scope !== ledgerScope();
  };
  const ledgerOf = (): Stored | null => (rejoined() ? null : storedOf());
  const saveGated = (gated: Record<string, number>) => {
    if (ledgerFromNewerVersion()) return;
    const doc = readLedgers();
    const stored = doc.profiles[profile()];
    if (!stored || rejoined()) return;
    if (JSON.stringify(stored.gated ?? {}) === JSON.stringify(gated)) return;
    doc.profiles[profile()] = { ...stored, gated };
    writeDocument(LEDGER_DOC, JSON.stringify(doc));
  };
  const saveHeld = (keys: Set<string>) => {
    if (ledgerFromNewerVersion()) return;
    const doc = readLedgers();
    const stored = doc.profiles[profile()];
    if (!stored || rejoined()) return;
    const next = [...keys].sort();
    if (JSON.stringify(stored.held ?? []) === JSON.stringify(next)) return;
    doc.profiles[profile()] = { ...stored, held: next };
    writeDocument(LEDGER_DOC, JSON.stringify(doc));
  };

  const record = (records: Map<string, FolderRecord>, keys: Iterable<string>, remote: (key: string) => unknown, stamp: (key: string) => string | undefined) => {
    for (const key of keys) {
      const h = stamp(key);
      if (h) records.set(key, { v: (remote(key) as LedgerValue | null | undefined) ?? null, h });
    }
  };

  const write = (now: Read, records: Map<string, FolderRecord>, keys: Iterable<string>, newest: number) => {
    const list = [...keys];
    writing = writing.then(async () => {
      if (ledgerFromNewerVersion()) return;
      const ledger = ledgerOf();
      const L = Math.max(ledger?.L ?? 0, now.mark?.L ?? 0) + 1;
      const mark = { L, t: Math.max(Date.now(), newest) };
      try {
        await engineCall("ac_passwords_mark", profile(), { key: MARK_KEY, value: formatMark(mark) });
      } catch (error) {
        console.warn("[sync] couldn't write Login Data's mark; the ledger waits", error);
        return;
      }
      const doc = readLedgers();
      doc.profiles[profile()] = { ...nextLedger(ledger, now.local, records, mark, list), scope: ledgerScope(), held: ledger?.held ?? [], gated: ledger?.gated ?? {} };
      writeDocument(LEDGER_DOC, JSON.stringify(doc));
    });
    return writing;
  };

  return {
    held: () => held.size,
    resolveHeld: (choice) => {
      if (choice === "confirm") confirmed = new Set([...confirmed, ...held]);
      else for (const key of held) restoring.set(key, heldDigests.get(key) ?? "");
      held = new Set();
      saveHeld(held);
      lastRead = 0;
    },
    prefix: "pw:",
    publishOnlyAfterPull: true,
    ownsItsChanges: true,
    extract: async (_base, _queued, _now, _known, remote, stamp, downloading) => {
      const now = Date.now();
      if (ledgerFromNewerVersion()) return null;
      if ((now < quietUntil || now - lastRead < READ_INTERVAL) && !forced()) return null;
      await writing;
      const here = await read();
      if (!here) return null;
      lastRead = now;
      const fresh = rejoined();
      const ledger = ledgerOf();
      const records = new Map<string, FolderRecord>();
      record(records, new Set([...here.local.keys(), ...Object.keys(ledger?.keys ?? {})]), remote, stamp);
      const j = judge(here.local, fresh ? null : here.mark, ledger, records, now);
      const keptHeld = new Set(ledger?.held ?? []);
      if (j.mode === "rebuild") {
        for (const key of keptHeld) {
          j.apply.delete(key);
          j.seed.delete(key);
        }
      }
      const lost = (c: (typeof j.claims)[number]) => {
        const r = records.get(c.key);
        return !!r && !c.afterRecord && Math.min(c.at, now) <= parseInt(r.h.slice(0, 9), 36);
      };
      const winning = j.claims.filter((c) => !lost(c));
      for (const c of j.claims) if (lost(c)) j.apply.add(c.key);
      const known = Object.keys(ledger?.keys ?? {}).length;
      for (const [key, digest] of restoring) if (digestOf(here.local.get(key)?.value) === digest) j.apply.add(key);
      restoring = new Map();
      const changes = winning.filter((c) => ledger?.keys[c.key] && !confirmed.has(c.key) && !j.apply.has(c.key));
      confirmed = new Set();
      const stillHeld = [...keptHeld].filter((key) => changes.some((c) => c.key === key) || (j.mode === "rebuild" && digestOf(here.local.get(key)?.value) !== digestOf(records.get(key)?.v)));
      const mass = changes.length > MASS_CHANGE_AT_LEAST && changes.length > known / 2;
      held = new Set([...stillHeld, ...(mass ? changes.map((c) => c.key) : [])]);
      heldDigests = new Map([...held].map((key) => [key, digestOf(here.local.get(key)?.value)]));
      saveHeld(held);
      const live = winning.filter((c) => !held.has(c.key) && !j.apply.has(c.key));
      claimed = new Set(live.map((c) => c.key));
      judgedForFolder = new Set(j.apply);
      const deletions = live.filter((c) => !c.v).map((c) => c.key);
      const firstGated: Record<string, number> = {};
      for (const key of deletions) firstGated[key] = ledger?.gated?.[key] ?? now;
      const busy = downloading();
      const gated = new Set(busy ? deletions.filter((key) => now - firstGated[key]! < DOWNLOAD_HOLD_MS) : []);
      saveGated(busy ? Object.fromEntries(Object.entries(firstGated).filter(([key]) => gated.has(key) || ledger?.gated?.[key] !== undefined)) : {});
      const byKey = new Map(live.filter((c) => !gated.has(c.key)).map((c) => [c.key, c]));
      const seeds = [...j.seed].filter((k) => j.mode !== "consistent" || ledger?.keys[k]?.d[0] !== digestOf(here.local.get(k)?.value));
      if (j.mode !== "consistent" || seeds.length) await write(here, records, seeds, 0);
      return {
        values: new Map(live.filter((c) => c.v).map((c) => [c.key, c.v!])),
        ignore: (key) => !byKey.has(key),
        republish: (key) => byKey.has(key),
        remove: new Set([...byKey.values()].filter((c) => !c.v).map((c) => c.key)),
        stamp: (key) => {
          const c = byKey.get(key);
          return c ? { at: c.at, after: c.afterRecord } : undefined;
        },
        reapply: j.apply,
        published: (keys) => {
          for (const key of keys) claimed.delete(key);
          void write(here, records, keys, 0);
        },
      };
    },
    editedAt: () => undefined,
    apply: async (visible, changed) => {
      if (ledgerFromNewerVersion()) return false;
      await writing;
      const before = await read();
      if (!before) return false;
      const ledger = ledgerOf();
      const changedHere = (key: string) => {
        const have = before.local.get(key);
        if (!have || judgedForFolder.has(key)) return false;
        const entry = ledger?.keys[key];
        return entry ? digestOf(have.value) !== entry.d[0] : digestOf(have.value) !== digestOf(visible.get(key) as LedgerValue | undefined);
      };
      const kept = new Set([...changed].filter((key) => claimed.has(key) || held.has(key) || changedHere(key)));
      const refused = new Set<string>();
      for (const key of changed) {
        if (kept.has(key)) continue;
        const v = visible.get(key) as LedgerValue | undefined;
        const have = before.local.get(key)?.value;
        const [origin, username] = [key.slice(3, key.indexOf("\n")), key.slice(key.indexOf("\n") + 1)];
        let ok = true;
        if (v) {
          if (have?.p === v.p) continue;
          if (have) ok = (await deletePassword(profile(), origin, username)) && ok;
          ok = (await savePassword(profile(), v.o, v.u, v.p)) && ok;
        } else if (have) {
          ok = (await deletePassword(profile(), origin, username)) && ok;
        }
        if (!ok) refused.add(key);
      }
      const wanted = [...changed].filter((k) => !kept.has(k) && !refused.has(k));
      const confirmed = (now: Read | null, k: string) => !!now && (visible.get(k) as LedgerValue | undefined)?.p === now.local.get(k)?.value.p;
      let latest: Read | null = null;
      let settled = false;
      for (let i = 0; i < 20 && !settled; i++) {
        latest = await read();
        settled = wanted.every((k) => confirmed(latest, k));
        if (!settled) await new Promise((r) => setTimeout(r, 250));
      }
      const failing = new Set(wanted.filter((k) => !confirmed(latest, k)));
      if ([...failing].some((k) => !unconfirmed.has(k))) quietUntil = Date.now() + 30_000;
      unconfirmed = failing;
      if (!latest) return false;
      const written = new Set(wanted.filter((k) => confirmed(latest, k)));
      if (written.size) {
        const records = new Map<string, FolderRecord>();
        for (const key of written) records.set(key, { v: (visible.get(key) as LedgerValue | undefined) ?? null, h: "" });
        const newest = Math.max(0, ...[...written].map((k) => latest!.local.get(k)?.modified ?? 0));
        await write(latest, records, written, newest);
      }
      return written;
    },
  };
}

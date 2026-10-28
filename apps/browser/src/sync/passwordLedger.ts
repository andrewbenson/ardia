import { hlcWall, type HLC } from "@ardia/sync";

export type LedgerValue = { o: string; u: string; s: string };
export type LedgerEntry = { d: string[]; h: HLC | null; m: number };
export type Ledger = { v: 1; L: number; t: number; keys: Record<string, LedgerEntry> };
export type LocalLogin = { value: LedgerValue; modified: number };
export type FolderRecord = { v: LedgerValue | null; h: HLC };
export type Mark = { L: number; t: number };

export type StoredLedger = Ledger & { scope?: string; held?: string[]; gated?: Record<string, number> };
export type LedgerDoc = { v: 2; profiles: Record<string, StoredLedger> };

const isPlainObject = (v: unknown): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v);

export function readLedgerDoc(text: string | null): LedgerDoc | "older" | "newer" | "unreadable" {
  if (text === null) return { v: 2, profiles: {} };
  try {
    const doc = JSON.parse(text) as unknown;
    if (!isPlainObject(doc)) return "unreadable";
    if (doc.v !== 2) return doc.v === 1 ? "older" : doc.v === undefined ? "unreadable" : "newer";
    return isPlainObject(doc.profiles) ? (doc as LedgerDoc) : "unreadable";
  } catch {
    return "unreadable";
  }
}

export type Claim = { key: string; v: LedgerValue | null; at: number; afterRecord: HLC | null };
export type Judgement = {
  mode: "consistent" | "rebuild" | "upgrade";
  claims: Claim[];
  apply: Set<string>;
  seed: Set<string>;
  deletedBeforeUpgrade: Set<string>;
};

const DIGESTS_KEPT = 4;

export const parseMark = (value: string | null | undefined): Mark | null => {
  const m = /^(\d+)@(\d+)$/.exec(value ?? "");
  return m ? { L: Number(m[1]), t: Number(m[2]) } : null;
};

export const formatMark = (mark: Mark) => `${mark.L}@${mark.t}`;

export function digestOf(value: LedgerValue | null | undefined): string {
  if (!value) return "";
  let h = 0x811c9dc5;
  const text = `${value.o}\u0000${value.u}\u0000${value.s}`;
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return `${text.length}.${h.toString(36)}`;
}

export function judge(
  local: Map<string, LocalLogin>,
  mark: Mark | null,
  ledger: Ledger | null,
  records: Map<string, FolderRecord>,
  now: number,
  agreedHere: (key: string) => LedgerValue | undefined = () => undefined,
  unapplied: (key: string) => boolean = () => false,
): Judgement {
  const claims: Claim[] = [];
  const apply = new Set<string>();
  const seed = new Set<string>();
  const deletedBeforeUpgrade = new Set<string>();
  const recordDigest = (key: string) => digestOf(records.get(key)?.v);
  const consistent = !!ledger && !!mark && mark.L === ledger.L && mark.t === ledger.t;
  const mode: Judgement["mode"] = consistent ? "consistent" : !ledger ? "upgrade" : "rebuild";
  const after = mode === "rebuild" ? Math.max(mark?.t ?? 0, ledger?.t ?? 0) : 0;
  const claim = (key: string, v: LedgerValue | null, modified: number) => {
    const entry = ledger?.keys[key];
    const record = records.get(key);
    const agreed = !!entry && recordDigest(key) === (entry.d[0] ?? "");
    claims.push({ key, v, at: agreed ? Math.min(modified, now) : modified, afterRecord: agreed && record ? record.h : null });
  };
  const keys = new Set([...local.keys(), ...records.keys(), ...Object.keys(ledger?.keys ?? {})]);
  for (const key of keys) {
    const here = local.get(key);
    const record = records.get(key);
    const entry = ledger?.keys[key];
    const mine = digestOf(here?.value);
    if (here && mine === recordDigest(key)) {
      seed.add(key);
      continue;
    }
    if (mode === "upgrade") {
      if (!here) {
        if (!record?.v) continue;
        if (unapplied(key)) apply.add(key);
        else if (digestOf(agreedHere(key)) !== recordDigest(key)) apply.add(key);
        else if (local.size === 0) apply.add(key);
        else deletedBeforeUpgrade.add(key);
        continue;
      }
      if (!record) claim(key, here.value, here.modified);
      else if (here.modified > hlcWall(record.h)) claims.push({ key, v: here.value, at: here.modified, afterRecord: null });
      else apply.add(key);
      continue;
    }
    if (mode === "rebuild") {
      if (here && here.modified > after) claim(key, here.value, here.modified);
      else {
        seed.add(key);
        if (record) apply.add(key);
      }
      continue;
    }
    if (!here) {
      if (!entry) {
        if (record?.v) apply.add(key);
        continue;
      }
      if (recordDigest(key) === entry.d[0]) claims.push({ key, v: null, at: now, afterRecord: record?.h ?? null });
      else if (record?.v) apply.add(key);
      continue;
    }
    if (!entry) {
      if (!record || record.v === null) claims.push({ key, v: here.value, at: Math.min(here.modified, now), afterRecord: record?.h ?? null });
      else claims.push({ key, v: here.value, at: here.modified, afterRecord: null });
      continue;
    }
    if (mine === entry.d[0]) {
      if (record) apply.add(key);
      else if (entry.h === null) claims.push({ key, v: here.value, at: Math.min(here.modified, now), afterRecord: null });
      continue;
    }
    const older = entry.d.slice(1).includes(mine);
    if (older && here.modified <= entry.m) {
      if (record) apply.add(key);
      continue;
    }
    claim(key, here.value, here.modified);
  }
  return { mode, claims, apply, seed, deletedBeforeUpgrade };
}

export function nextLedger(
  ledger: Ledger | null,
  local: Map<string, LocalLogin>,
  records: Map<string, FolderRecord>,
  mark: Mark,
  keys: Iterable<string>,
  deletedBeforeUpgrade: Iterable<string> = [],
): Ledger {
  const out: Ledger = { v: 1, L: mark.L, t: mark.t, keys: { ...(ledger?.keys ?? {}) } };
  for (const key of deletedBeforeUpgrade) {
    const record = records.get(key);
    if (!record?.v || local.has(key)) continue;
    out.keys[key] = { d: [digestOf(record.v)], h: record.h, m: 0 };
  }
  for (const key of keys) {
    const here = local.get(key);
    if (!here) {
      delete out.keys[key];
      continue;
    }
    const digest = digestOf(here.value);
    const was = out.keys[key]?.d ?? [];
    out.keys[key] = { d: [digest, ...was.filter((d) => d !== digest)].slice(0, DIGESTS_KEPT), h: records.get(key)?.h ?? null, m: Math.min(here.modified, mark.t) };
  }
  return out;
}

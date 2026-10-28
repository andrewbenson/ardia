import { readDocument, writeDocument } from "@ardia/shell";
import type { ScopeState } from "@ardia/sync";
import { openJournal, type EditJournal } from "./editJournal";
import { nativeStoreActive } from "../store/nativeStore";
import { syncRedesign } from "./redesignSwitch";

const SESSION_DOC = "session.json";

let journal: EditJournal | null = null;
let version = 0;
const listeners = new Set<() => void>();

export const journalVersion = () => version;

export function onJournalChange(listener: () => void) {
  listeners.add(listener);
  return () => void listeners.delete(listener);
}

function changed() {
  version++;
  for (const listener of listeners) listener();
}
let everSeen: Record<string, Record<string, [string, number]>> | null = null;

function savedSession(): { journalG?: unknown; everSeen?: unknown } | null {
  try {
    return JSON.parse(readDocument(SESSION_DOC) ?? "null");
  } catch {
    return null;
  }
}

function storeG(): number {
  const session = savedSession();
  return typeof session?.journalG === "number" ? session.journalG : 0;
}

function storeT(): number {
  const session = savedSession() as { journalT?: unknown } | null;
  return typeof session?.journalT === "number" ? session.journalT : 0;
}

type SavedSeen = { devices: string[]; scopes: Record<string, Record<string, [number, number]>> };

function seenKeys() {
  if (everSeen) return everSeen;
  everSeen = {};
  const saved = savedSession()?.everSeen as Partial<SavedSeen> | undefined;
  if (saved && Array.isArray(saved.devices) && saved.scopes && typeof saved.scopes === "object") {
    for (const [scope, keys] of Object.entries(saved.scopes)) {
      const out: Record<string, [string, number]> = {};
      for (const [key, [device, seq]] of Object.entries(keys)) if (saved.devices[device] !== undefined) out[key] = [saved.devices[device]!, seq];
      everSeen[scope] = out;
    }
  }
  return everSeen;
}

function compactSeen(): SavedSeen {
  const devices: string[] = [];
  const index = new Map<string, number>();
  const scopes: SavedSeen["scopes"] = {};
  for (const [scope, keys] of Object.entries(everSeen ?? {})) {
    const out: Record<string, [number, number]> = {};
    for (const [key, [device, seq]] of Object.entries(keys)) {
      let i = index.get(device);
      if (i === undefined) index.set(device, (i = devices.push(device) - 1));
      out[key] = [i, seq];
    }
    scopes[scope] = out;
  }
  return { devices, scopes };
}

export function noteSeen(scope: string, key: string, origin: [string, number]) {
  if (!syncRedesign.on || key.startsWith("bm:")) return;
  const keys = (seenKeys()[scope] ??= {});
  const was = keys[key];
  if (was && was[0] === origin[0] && was[1] === origin[1]) return;
  keys[key] = origin;
  changed();
}

export const seenOrigin = (scope: string, key: string): [string, number] | undefined => (syncRedesign.on ? seenKeys()[scope]?.[key] : undefined);

export const SEEN_TOMBSTONE_PRUNE_MS = 90 * 86_400_000;

export type SeenPruneInput = {
  extractedThisCycle: boolean;
  localHas: boolean;
  localIgnored: boolean;
  record: { v: unknown; wall: number } | undefined;
  now: number;
};

export const prunableSeen = ({ extractedThisCycle, localHas, localIgnored, record, now }: SeenPruneInput) =>
  extractedThisCycle && !localHas && !localIgnored && (!record || (record.v === null && now - record.wall > SEEN_TOMBSTONE_PRUNE_MS));

export function pruneSeen(scope: string, prune: (key: string) => boolean) {
  const keys = seenKeys()[scope];
  if (!keys) return;
  let dropped = false;
  for (const key of Object.keys(keys)) if (prune(key)) {
    delete keys[key];
    dropped = true;
  }
  if (dropped) changed();
}

export function forgetSeenScope(scope: string) {
  if (seenKeys()[scope]) delete seenKeys()[scope];
}

export function editJournal(): EditJournal | null {
  if (!syncRedesign.on) return null;
  if (!journal) {
    journal = openJournal({ read: readDocument, write: writeDocument }, { storeG: storeG(), storeT: storeT() });
    if (journal.lost && nativeStoreActive()) journal.fallback = "nothing";
  }
  return journal;
}

export function forgetEditJournal() {
  journal = null;
  everSeen = null;
}

export function journalAnchor(): { journalG?: number; journalT?: number; everSeen?: SavedSeen } {
  if (!syncRedesign.on) return {};
  const j = editJournal()!;
  const seen = seenKeys();
  return {
    ...(j.g ? { journalG: j.g } : {}),
    ...(j.lastInStepT ? { journalT: j.lastInStepT } : {}),
    ...(Object.keys(seen).length ? { everSeen: compactSeen() } : {}),
  };
}

export function noteInStep(scopes: Record<string, ScopeState>, now: number) {
  const j = editJournal();
  if (!j) return;
  const entries = Object.entries(scopes);
  if (entries.some(([, s]) => s.unapplied.length || s.pending || Object.keys(s.damaged).length || s.outbox.length || s.journal?.length)) return;
  j.inStepAt(now, Object.fromEntries(entries.map(([scope, s]) => [scope, { ...s.vv }])));
  changed();
}

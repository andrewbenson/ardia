import type { HLC } from "@solara/sync";

export const JOURNAL_DOC = "sync-edits.json";
export const GEN_DOC = "sync-edits.gen";

export type Entry = { v: unknown; h: HLC; seen: string | null };
type VV = Record<string, number>;
type JournalDoc = { v: 1; g: number; newest: HLC | null; entries: Record<string, Record<string, Entry>> };
type GenDoc = { v: 1; g: number; T: number | null; vv: Record<string, VV> | null };

export type Disk = { read: (name: string) => string | null; write: (name: string, text: string) => void };
export type InStep = { T: number; vv: Record<string, VV> };

export type EditJournal = {
  lost: boolean;
  fallback: "none" | "union" | "nothing";
  inStep: InStep | null;
  readonly g: number;
  readonly lastInStepT: number;
  entry(scope: string, key: string): Entry | undefined;
  entries(scope: string): [string, Entry][];
  record(scope: string, key: string, entry: Entry): void;
  clear(scope: string, key: string, h: HLC): void;
  inStepAt(T: number, vv: Record<string, VV>): void;
};

function parse<T>(text: string | null, valid: (v: unknown) => v is T): T | null | "unreadable" {
  if (text === null) return null;
  try {
    const value = JSON.parse(text) as unknown;
    return valid(value) ? value : "unreadable";
  } catch {
    return "unreadable";
  }
}

const isObject = (v: unknown): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v);
const isJournal = (v: unknown): v is JournalDoc => isObject(v) && v.v === 1 && typeof v.g === "number" && isObject(v.entries);
const isGen = (v: unknown): v is GenDoc => isObject(v) && v.v === 1 && typeof v.g === "number";

export function openJournal(disk: Disk, { storeG, storeT = 0 }: { storeG: number; storeT?: number }): EditJournal {
  const saved = parse(disk.read(JOURNAL_DOC), isJournal);
  const gen = parse(disk.read(GEN_DOC), isGen);
  const genDoc = gen === "unreadable" ? null : gen;
  const inStep = genDoc && genDoc.T !== null && genDoc.vv ? { T: genDoc.T, vv: genDoc.vv } : null;
  const readable = saved === null || saved === "unreadable" ? null : saved;
  const fresh = saved === null && genDoc === null && storeG === 0;
  const lostJournal = !fresh && (!readable || readable.g < (genDoc?.g ?? 0) || readable.g < storeG);
  const doc: JournalDoc = lostJournal || !readable ? { v: 1, g: Math.max(storeG, genDoc?.g ?? 0), newest: null, entries: {} } : readable;
  let T = genDoc?.T ?? null;
  let vv = genDoc?.vv ?? null;
  let floorT = Math.max(T ?? 0, storeT);
  let anchorT = storeT;
  const writeGen = () => disk.write(GEN_DOC, JSON.stringify({ v: 1, g: doc.g, T, vv } satisfies GenDoc));
  const writeJournal = () => {
    disk.write(JOURNAL_DOC, JSON.stringify(doc));
    writeGen();
  };
  if (!lostJournal && readable && (genDoc === null || genDoc.g !== doc.g)) writeGen();
  return {
    lost: lostJournal,
    fallback: !lostJournal ? "none" : inStep && storeT >= inStep.T ? "union" : "nothing",
    inStep,
    get g() {
      return doc.g;
    },
    get lastInStepT() {
      return anchorT;
    },
    entry: (scope, key) => doc.entries[scope]?.[key],
    entries: (scope) => Object.entries(doc.entries[scope] ?? {}),
    record(scope, key, entry) {
      doc.g++;
      (doc.entries[scope] ??= {})[key] = entry;
      if (!doc.newest || entry.h > doc.newest) doc.newest = entry.h;
      writeJournal();
    },
    clear(scope, key, h) {
      if (doc.entries[scope]?.[key]?.h !== h) return;
      delete doc.entries[scope]![key];
      if (!Object.keys(doc.entries[scope]!).length) delete doc.entries[scope];
      doc.g++;
      writeJournal();
    },
    inStepAt(at, vectors) {
      T = Math.max(at, floorT + 1);
      floorT = T;
      anchorT = T;
      vv = vectors;
      writeGen();
    },
  };
}

export type UnionInput = {
  scope: string;
  T: number;
  vvT: Record<string, VV>;
  local: Map<string, unknown>;
  records: Map<string, { v: unknown; o: [string, number] }>;
  everSeen: Set<string>;
  tombstoned: Set<string>;
};

const same = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);

export function unionFallback({ scope, T, vvT, local, records, everSeen, tombstoned }: UnionInput) {
  const publish = new Map<string, { v: unknown; at: number }>();
  const apply = new Set<string>();
  const covered = (o: [string, number]) => (vvT[scope]?.[o[0]] ?? 0) >= o[1];
  for (const [key, value] of local) {
    const record = records.get(key);
    if (record) {
      if (same(record.v, value)) continue;
      if (covered(record.o)) publish.set(key, { v: value, at: T });
      else apply.add(key);
    } else if (everSeen.has(key) || tombstoned.has(key)) apply.add(key);
    else publish.set(key, { v: value, at: T });
  }
  return { publish, apply, publishDeletions: false };
}

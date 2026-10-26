export type HistoryPatch<T> = { removed: string[]; inserts: [number, T][] };

export const MAX_PATCH_ROWS = 400;

export function historyPatch<T extends { url: string }>(prev: readonly T[], next: readonly T[]): HistoryPatch<T> | null {
  const kept = new Set<T>(next);
  const removed: string[] = [];
  const survivors: T[] = [];
  for (const row of prev) {
    if (kept.has(row)) survivors.push(row);
    else removed.push(row.url);
  }
  const before = new Set<T>(survivors);
  const inserts: [number, T][] = [];
  let walked = 0;
  for (let i = 0; i < next.length; i++) {
    const row = next[i]!;
    if (before.has(row)) {
      if (survivors[walked] !== row) return null;
      walked++;
    } else {
      inserts.push([i, row]);
    }
  }
  if (walked !== survivors.length || removed.length + inserts.length > MAX_PATCH_ROWS) return null;
  return { removed, inserts };
}

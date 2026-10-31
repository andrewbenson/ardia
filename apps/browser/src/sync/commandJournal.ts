import { canonical, type Adapter, type Clock } from "@solara/sync";
import { useBrowser, type BrowserState } from "../store/browser";
import { pinnedGroupMembers } from "../store/pinHomes";
import { nativeOriginsKnown } from "../store/nativeStore";
import { applyingFromSync } from "../store/syncOrigin";
import type { EditJournal } from "./editJournal";

export type JournaledAdapter = {
  scope: string;
  adapter: Adapter;
  sources: (s: BrowserState) => unknown[];
  observations?: (key: string) => readonly string[];
};

const digest = (value: unknown) => (value === undefined ? null : canonical(value));
const withoutFields = (value: unknown, fields: readonly string[]) =>
  value && typeof value === "object" && fields.length ? Object.fromEntries(Object.entries(value as Record<string, unknown>).filter(([k]) => !fields.includes(k))) : value;

export const pinSources = (s: BrowserState): unknown[] => {
  const members = pinnedGroupMembers(s);
  return [s.groups, s.windows, s.parkedPins, s.pinChoices, ...Object.values(s.tabs).filter((t) => t.pinned || members.has(t.id))];
};

export function journalCommands(journal: EditJournal, clock: Clock, adapters: () => JournaledAdapter[], record: (scope: string, key: string) => unknown) {
  if (!nativeOriginsKnown()) return () => {};
  const last = new Map<string, Map<string, unknown>>();
  const id = (a: JournaledAdapter) => `${a.scope} ${a.adapter.prefix}`;
  const extractNow = (a: JournaledAdapter): Map<string, unknown> | null => {
    const extraction = a.adapter.extract(() => undefined, () => false, Date.now(), () => false, () => undefined, () => undefined, () => false);
    if (!extraction || extraction instanceof Promise) return null;
    return extraction.values;
  };
  for (const a of adapters()) {
    const values = extractNow(a);
    if (values) last.set(id(a), new Map(values));
  }
  const stop = useBrowser.subscribe((s, prev) => {
    const fromSync = applyingFromSync();
    for (const a of adapters()) {
      const now = a.sources(s);
      const was = a.sources(prev);
      if (now.length === was.length && now.every((v, i) => v === was[i])) continue;
      const values = extractNow(a);
      if (!values) continue;
      const before = last.get(id(a)) ?? new Map();
      last.set(id(a), new Map(values));
      if (fromSync) continue;
      for (const key of new Set([...before.keys(), ...values.keys()])) {
        const then = before.get(key);
        const value = values.get(key);
        const fields = a.observations?.(key) ?? [];
        if (digest(withoutFields(then, fields)) === digest(withoutFields(value, fields))) continue;
        journal.record(a.scope, key, { v: value ?? null, h: clock.tick(), seen: digest(record(a.scope, key)) });
      }
    }
  });
  return stop;
}

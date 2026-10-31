import type { ScopeState } from "@solara/sync";
import { isObject } from "./readable";

export const DELTA_PREFIX = "sync-state-d-";
export const BATCH_PREFIX = "sync-journal-b-";
const KEYED = ["records", "base", "files"] as const;
type Keyed = (typeof KEYED)[number];
const keyed = (key: string) => (KEYED as readonly string[]).includes(key);
type Scopes = Record<string, ScopeState>;

type WrittenScope = { scope: ScopeState; maps: Record<Keyed, Record<string, unknown>>; rest: Map<string, string> };
export type Written = Map<string, WrittenScope>;
export type DeltaName = { device: string; n: number; epoch: string; g: number };
type Gone = Partial<Record<Keyed | "rest", string[]>>;
type ScopeDelta = Record<string, unknown>;

const LIST_EDIT = "~list";
const LIST_EDIT_FROM = 64;
const strings = (value: unknown): value is string[] => Array.isArray(value) && value.every((item) => typeof item === "string");
type ListEdit = { [LIST_EDIT]: { drop: string[]; add: string[] } };
const isListEdit = (value: unknown): value is ListEdit =>
  isObject(value) && isObject(value[LIST_EDIT]) && strings((value[LIST_EDIT] as Record<string, unknown>).drop) && strings((value[LIST_EDIT] as Record<string, unknown>).add);
const edited = (list: string[], { drop, add }: ListEdit[typeof LIST_EDIT]) => {
  const dropped = new Set(drop);
  return [...list.filter((item) => !dropped.has(item)), ...add];
};

function listEdit(before: string | undefined, now: unknown, json: string): ListEdit | null {
  if (!before || !strings(now) || now.length < LIST_EDIT_FROM) return null;
  const old: unknown = JSON.parse(before);
  if (!strings(old)) return null;
  const kept = new Set(now);
  const had = new Set(old);
  const edit = { drop: old.filter((item) => !kept.has(item)), add: now.filter((item) => !had.has(item)) };
  return JSON.stringify(edited(old, edit)) === json ? { [LIST_EDIT]: edit } : null;
}

const restOf = (scope: ScopeState) => new Map(Object.entries(scope).filter(([k, v]) => !keyed(k) && v !== undefined).map(([k, v]) => [k, JSON.stringify(v)]));

export function writtenOf(scopes: Scopes): Written {
  const written: Written = new Map();
  for (const [name, scope] of Object.entries(scopes)) {
    const maps = Object.fromEntries(KEYED.map((k) => [k, { ...(scope[k] as Record<string, unknown>) }])) as WrittenScope["maps"];
    written.set(name, { scope, maps, rest: restOf(scope) });
  }
  return written;
}

export type Delta = { whole: true } | { whole: false; delta: Record<string, ScopeDelta> | null };

export function deltaOf(scopes: Scopes, written: Written): Delta {
  const names = Object.keys(scopes);
  if (names.length !== written.size || names.some((name) => written.get(name)?.scope !== scopes[name])) return { whole: true };
  const delta: Record<string, ScopeDelta> = {};
  for (const name of names) {
    const scope = scopes[name]!;
    const was = written.get(name)!;
    const rest = restOf(scope);
    const changed: ScopeDelta = {};
    const gone: Gone = {};
    for (const [field, json] of rest) {
      if (was.rest.get(field) === json) continue;
      const value = (scope as unknown as Record<string, unknown>)[field];
      changed[field] = listEdit(was.rest.get(field), value, json) ?? value;
    }
    const restGone = [...was.rest.keys()].filter((field) => !rest.has(field));
    if (restGone.length) gone.rest = restGone;
    let any = Object.keys(changed).length > 0 || restGone.length > 0;
    for (const k of KEYED) {
      const now = scope[k] as Record<string, unknown>;
      const before = was.maps[k];
      const put: Record<string, unknown> = {};
      for (const key of Object.keys(now)) if (now[key] !== before[key] || !(key in before)) put[key] = now[key];
      const removed = Object.keys(before).filter((key) => !(key in now));
      if (Object.keys(put).length) any = true;
      if (removed.length) {
        any = true;
        gone[k] = removed;
      }
      changed[k] = put;
    }
    if (any) delta[name] = { ...changed, ...(Object.keys(gone).length ? { "~gone": gone } : {}) };
  }
  return { whole: false, delta: Object.keys(delta).length ? delta : null };
}

export function applyDelta(scopes: Scopes, delta: unknown): boolean {
  if (!isObject(delta)) return false;
  for (const [name, change] of Object.entries(delta)) {
    const scope = scopes[name] as unknown as Record<string, unknown> | undefined;
    if (!scope || !isObject(change) || KEYED.some((k) => !isObject(change[k]) || !isObject(scope[k]))) return false;
    const gone = (change["~gone"] ?? {}) as Gone;
    if (!isObject(gone) || [...KEYED, "rest" as const].some((k) => gone[k] !== undefined && !strings(gone[k]))) return false;
    for (const [key, value] of Object.entries(change)) if (isObject(value) && LIST_EDIT in value && !(isListEdit(value) && strings(scope[key]))) return false;
  }
  for (const [name, change] of Object.entries(delta) as [string, Record<string, unknown>][]) {
    const scope = scopes[name] as unknown as Record<string, unknown>;
    for (const [key, value] of Object.entries(change)) if (!keyed(key) && key !== "~gone") scope[key] = isListEdit(value) ? edited(scope[key] as string[], value[LIST_EDIT]) : value;
    const gone = (change["~gone"] ?? {}) as Gone;
    for (const key of gone.rest ?? []) if (!keyed(key)) delete scope[key];
    for (const k of KEYED) {
      const map = scope[k] as Record<string, unknown>;
      Object.assign(map, change[k]);
      for (const key of gone[k] ?? []) delete map[key];
    }
  }
  return true;
}

export const deltaName = ({ device, n, epoch, g }: DeltaName) => `${DELTA_PREFIX}${device}-${n}-${epoch}-${g}.nns`;
export const deltaPart = ({ device, n, epoch, g }: DeltaName) => `d.${device}.${n}.${epoch}.${g}`;

export function parseDeltaName(name: string): DeltaName | null {
  const m = name.match(/^sync-state-d-([A-Za-z0-9]+)-(\d+)-([0-9a-f]+)-(\d+)\.nns$/);
  return m ? { device: m[1]!, n: Number(m[2]), epoch: m[3]!, g: Number(m[4]) } : null;
}

const hex = (text: string) => Array.from({ length: text.length }, (_, i) => text.charCodeAt(i).toString(16).padStart(4, "0")).join("");
const unhex = (text: string) => String.fromCharCode(...(text.match(/.{4}/g) ?? []).map((unit) => parseInt(unit, 16)));

export const batchName = (scope: string, seq: number) => `${BATCH_PREFIX}${hex(scope)}-${seq}.nns`;
export const batchPart = (scope: string, seq: number) => `b.${scope}.${seq}`;

export function parseBatchName(name: string): { scope: string; seq: number } | null {
  const m = name.match(/^sync-journal-b-((?:[0-9a-f]{4})+)-(\d+)\.nns$/);
  return m ? { scope: unhex(m[1]!), seq: Number(m[2]) } : null;
}

export const newEpoch = () => Array.from({ length: 4 }, () => Math.floor(Math.random() * 0x1_0000_0000).toString(16).padStart(8, "0")).join("");

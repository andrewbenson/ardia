import type { LogFile, ScopeState } from "@ardia/sync";

export const isObject = (v: unknown): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v);

export const readableRecord = (r: unknown) => isObject(r) && typeof r.h === "string" && Array.isArray(r.o) && typeof r.o[0] === "string" && typeof r.o[1] === "number";
export const readableOp = (op: unknown) => isObject(op) && typeof op.k === "string" && typeof op.h === "string";

export function readableScope(v: unknown): v is ScopeState {
  if (!isObject(v)) return false;
  return (
    [v.records, v.base, v.vv, v.extra, v.files, v.damaged, v.seen].every(isObject) &&
    Object.values(v.records as Record<string, unknown>).every(readableRecord) &&
    Object.values(v.base as Record<string, unknown>).every((b) => typeof b === "string") &&
    [v.vv, v.seen, v.damaged].every((m) => Object.values(m as Record<string, unknown>).every((n) => typeof n === "number")) &&
    Object.values(v.extra as Record<string, unknown>).every((list) => Array.isArray(list) && list.every((n) => typeof n === "number")) &&
    Object.values(v.files as Record<string, unknown>).every(isObject) &&
    Array.isArray(v.unapplied) &&
    v.unapplied.every((k) => typeof k === "string") &&
    Array.isArray(v.outbox) &&
    v.outbox.every(readableOp) &&
    typeof v.seq === "number" &&
    (v.journal === undefined || (Array.isArray(v.journal) && v.journal.every(readableBatch))) &&
    (v.heldOutbox === undefined || (Array.isArray(v.heldOutbox) && v.heldOutbox.every(readableOp))) &&
    (v.rebuild === undefined || readableRebuild(v.rebuild))
  );
}

export const readableRebuild = (r: unknown) =>
  isObject(r) &&
  (r.settled === undefined || (Array.isArray(r.settled) && r.settled.every((p) => typeof p === "string"))) &&
  (r.noted === undefined || (isObject(r.noted) && Object.values(r.noted).every((n) => isObject(n) && Object.values(n).every((d) => typeof d === "string"))));

export const readableBatch = (f: unknown): f is LogFile => isObject(f) && typeof f.device === "string" && typeof f.seq === "number" && Array.isArray(f.ops) && f.ops.every(readableOp);

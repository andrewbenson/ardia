import { requireOptionalNativeModule, type EventSubscription } from "expo-modules-core";

export { encodeArgs, encodeCommand, PATCH_COMMANDS } from "./encode";

type StoreStatus = { active: true; scope?: "settingsAndDownloads" | "everything" } | { active: false; reason: string; handedOff?: boolean };

type NativeStoreModule = {
  status(): StoreStatus;
  snapshot(): string | null;
  dispatch(commandJSON: string, sinceRev: number): string | null;
  catchUp(sinceRev: number): string | null;
  flush(timeout: number): boolean;
  addListener(event: "onStoreCommit", listener: (payload: { event: string }) => void): EventSubscription;
};

export type StoreCommand = { name: string; args: unknown[] };

export type StorePatch = {
  rev: number;
  settings?: { set?: Record<string, unknown>; remove?: string[] };
  downloads?: unknown[];
  [slice: string]: unknown;
};

export type StoreEffect = { type: string; [key: string]: unknown };

export type DispatchResponse = {
  rev: number;
  patches?: StorePatch[];
  snapshot?: Record<string, unknown>;
  result?: unknown;
  effects?: StoreEffect[];
  error?: string;
};

export type ForeignCommit = { rev: number; patch: StorePatch; effects?: StoreEffect[] };

const native = requireOptionalNativeModule<NativeStoreModule>("ArdiaStore");

export function nativeStoreStatus(): StoreStatus {
  if (!native) return { active: false, reason: "the ArdiaStore module isn't in this build" };
  try {
    return native.status();
  } catch (error) {
    return { active: false, reason: String(error) };
  }
}

export function nativeSnapshot(): { rev: number; data: Record<string, unknown> } | null {
  const text = native?.snapshot();
  return text ? JSON.parse(text) : null;
}

export function nativeDispatch(commands: StoreCommand | StoreCommand[], sinceRev: number): DispatchResponse {
  const text = native?.dispatch(JSON.stringify(commands), sinceRev);
  if (!text) throw new Error("the native store isn't running");
  return JSON.parse(text);
}

export function nativeCatchUp(sinceRev: number): DispatchResponse | null {
  const text = native?.catchUp(sinceRev);
  return text ? JSON.parse(text) : null;
}

export function flushNativeStore(timeoutSeconds = 0.5): boolean {
  return native?.flush(timeoutSeconds) ?? false;
}

export function onForeignCommit(listener: (commit: ForeignCommit) => void): () => void {
  if (!native) return () => {};
  const subscription = native.addListener("onStoreCommit", ({ event }) => listener(JSON.parse(event)));
  return () => subscription.remove();
}

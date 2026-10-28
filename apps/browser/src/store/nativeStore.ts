import {
  encodeCommand,
  freezeNativeStore,
  nativeCatchUp,
  nativeDispatch,
  nativeSnapshot,
  nativeStoreStatus,
  onForeignCommit,
  useNativeSyncOrigins,
  type DispatchResponse,
  type StoreCommand,
  type StoreEffect,
  type StorePatch,
} from "@ardia/store";
import type { Download } from "@ardia/ardiacore";
import { syncRedesign } from "../sync/redesignSwitch";
import { applyingFromSync, asSyncOrigin, asUserChange } from "./syncOrigin";
import type { BrowserState } from "./browser";
import type { Settings } from "./settings";
import { LIVE_PATCH_COMMANDS, runEffects, WORKSPACE_COMMANDS, workspaceFromPatch, workspaceFromSnapshot } from "./nativeWorkspace";

type OwnedSlices = { settings: Settings; downloads: Download[] };
type Replica = {
  getState(): BrowserState;
  setState(partial: Partial<BrowserState>): void;
  subscribe(listener: (s: BrowserState, prev: BrowserState) => void): () => void;
};

const WORKSPACE_SLICES = [
  "profiles", "profileOrder", "orphanedProfileData", "windows", "windowOrder", "tabs", "groups", "splits", "peeks", "closedTabs", "closedWindows",
  "closedGroups", "deletedGroups", "cleanedTabs", "privateCleanedTabs", "privateSiteMutes", "parkedPins", "pinChoices", "pinSync",
] as const;
const UI_KEYS = ["focusedWindowId", "focusOrder", "lastProfileId"] as const;

let active = false;
let ownsWorkspace = false;
let handedOff = false;
let refusedSession: string | null = null;
let appliedRev = 0;
let syncOriginsAtStart = false;
let taggingSyncOrigins = false;
let busyWrites = 0;
export const nativeBusyWrites = () => busyWrites;
export const nativeOriginsKnown = () => !active || taggingSyncOrigins;
let applying = 0;
let replica: Replica | null = null;
let stopListening: (() => void) | null = null;

export const nativeStoreActive = () => active;
export const nativeOwnsWorkspace = () => active && ownsWorkspace;
export const dataFolderHandedOff = () => handedOff;
export const nativeRefusedSession = () => refusedSession;
export const nativeStoreRev = () => appliedRev;

export function startNativeStore(): { active: boolean; reason?: string } {
  const status = nativeStoreStatus();
  active = status.active;
  ownsWorkspace = status.active && status.scope === "everything";
  handedOff = !status.active && status.handedOff === true;
  refusedSession = !status.active ? (status.refusedSession ?? null) : null;
  if (status.syncRedesign !== undefined) syncRedesign.on = status.syncRedesign;
  syncOriginsAtStart = syncRedesign.on;
  taggingSyncOrigins = status.active && syncRedesign.on && useNativeSyncOrigins(true);
  return status.active ? { active: true } : { active: false, reason: status.reason };
}

export function nativeOwnedSnapshot(): Partial<OwnedSlices> | null {
  if (!active) return null;
  const snapshot = nativeSnapshot();
  if (!snapshot) return null;
  appliedRev = snapshot.rev;
  const data = snapshot.data as Partial<OwnedSlices>;
  return { settings: data.settings, downloads: data.downloads };
}

export function standDown() {
  freezeNativeStore();
  stopListening?.();
  stopListening = null;
  replica = null;
  active = false;
  ownsWorkspace = false;
}

export function hydrateFromNative(store: Replica): boolean {
  if (!nativeOwnsWorkspace()) return false;
  const snapshot = nativeSnapshot();
  if (!snapshot) return false;
  appliedRev = snapshot.rev;
  withApplier(() => store.setState(workspaceFromSnapshot(store.getState(), snapshot.data)));
  return true;
}

export function withApplier<T>(run: () => T): T {
  applying++;
  try {
    return run();
  } finally {
    applying--;
  }
}

function settingsAndDownloads(s: BrowserState, patch: StorePatch): Partial<BrowserState> {
  const next: Partial<BrowserState> = {};
  if (patch.settings) {
    const settings = { ...s.settings, ...(patch.settings.set ?? {}) } as Settings & Record<string, unknown>;
    for (const key of patch.settings.remove ?? []) delete settings[key];
    next.settings = settings;
  }
  if (patch.downloads) next.downloads = patch.downloads as Download[];
  return next;
}

function applyPatch(patch: StorePatch) {
  const s = replica!.getState();
  const next = ownsWorkspace ? workspaceFromPatch(s, patch) : settingsAndDownloads(s, patch);
  if (Object.keys(next).length) withApplier(() => replica!.setState(next));
}

function applySnapshot(data: Record<string, unknown>) {
  const s = replica!.getState();
  const next = ownsWorkspace ? workspaceFromSnapshot(s, data, { keepLocal: true }) : settingsAndDownloads(s, { rev: 0, settings: data.settings ? { set: data.settings as Record<string, unknown> } : undefined, downloads: data.downloads as unknown[] | undefined });
  withApplier(() => replica!.setState(next));
}

const BUSY_EFFECT_RETRY_MS = 50;

function afterApplied(effects: StoreEffect[] | undefined) {
  if (!effects?.length || !replica) return;
  const store = replica;
  const run = (effect: StoreEffect) => withApplier(() => runEffects([effect], () => store.getState(), (partial) => store.setState(partial)));
  for (const effect of effects) {
    try {
      run(effect);
    } catch (error) {
      if (!(error instanceof NativeStoreBusy)) throw error;
      setTimeout(() => asSyncOrigin(() => afterApplied([effect])), BUSY_EFFECT_RETRY_MS);
    }
  }
}

function inPatchOrigin<T>(patch: StorePatch, apply: () => T): T {
  if (patch.sync) return asSyncOrigin(apply);
  return patch.bridge ? apply() : asUserChange(apply);
}

function applyResponse(response: DispatchResponse | null) {
  if (!response || !replica) return;
  if (response.snapshot) {
    appliedRev = Math.max(appliedRev, response.rev);
    applySnapshot(response.snapshot);
    return;
  }
  for (const patch of response.patches ?? []) {
    if (patch.rev <= appliedRev) continue;
    appliedRev = patch.rev;
    inPatchOrigin(patch, () => applyPatch(patch));
  }
  appliedRev = Math.max(appliedRev, response.rev);
}

export class NativeStoreBusy extends Error {
  constructor() {
    super("a user transaction is open in the native store; sync retries from fresh state");
  }
}

export function nativeWrite(commands: StoreCommand | StoreCommand[]): DispatchResponse | null {
  if (!active) return null;
  if (syncRedesign.on !== syncOriginsAtStart) throw new Error("syncRedesign changed after startNativeStore; set it before the native store starts");
  const response = nativeDispatch(commands, appliedRev, { fromSync: taggingSyncOrigins && applyingFromSync() });
  applyResponse(response);
  if (response.busy) {
    busyWrites++;
    throw new NativeStoreBusy();
  }
  afterApplied(response.effects);
  if (response.error) console.warn("The native store refused", commands, response.error);
  return response;
}

export function nativeTransaction(run: () => void) {
  nativeWrite({ name: "beginTransaction", args: [] });
  try {
    run();
  } finally {
    nativeWrite({ name: "endTransaction", args: [] });
  }
}

function sameJSON(a: unknown, b: unknown) {
  return a === b || JSON.stringify(a) === JSON.stringify(b);
}

function wrapActions(store: Replica) {
  const s = store.getState() as unknown as Record<string, unknown>;
  const updateLive = s.updateLive as (id: string, patch: object) => void;
  const wrapped: Record<string, unknown> = {};
  for (const name of WORKSPACE_COMMANDS) {
    if (typeof s[name] !== "function") continue;
    wrapped[name] = (...args: unknown[]) => {
      const response = nativeWrite(encodeCommand(name, args));
      if (LIVE_PATCH_COMMANDS.has(name) && typeof args[0] === "string" && args[2] && typeof args[2] === "object") updateLive(args[0], args[2]);
      return response?.result ?? undefined;
    };
  }
  const hydrate = s.hydrate as (data: object) => void;
  wrapped.hydrate = (data: object) => {
    withApplier(() => hydrate(data));
    nativeWrite(encodeCommand("hydrate", [data]));
    resync(store, [...OWNED_KEYS, "ui"]);
  };
  withApplier(() => store.setState(wrapped as Partial<BrowserState>));
}

const PROFILE_SETTINGS_WRITERS = ["deleteProfile", "setDefaultProfile"] as const;

function wrapProfileSettingsWriters(store: Replica) {
  const s = store.getState() as unknown as Record<string, unknown>;
  const wrapped: Record<string, unknown> = {};
  for (const name of PROFILE_SETTINGS_WRITERS) {
    const original = s[name];
    if (typeof original !== "function") continue;
    wrapped[name] = (...args: unknown[]) => {
      const before = store.getState().settings;
      const result = withApplier(() => (original as (...a: unknown[]) => unknown)(...args));
      const after = store.getState().settings;
      if (after !== before && !sameJSON(after, before)) {
        nativeWrite({ name: "applyState", args: [{ settings: after }] });
        resync(store, ["settings"]);
      }
      return result;
    };
  }
  withApplier(() => store.setState(wrapped as Partial<BrowserState>));
}

function ownedChanges(s: BrowserState, prev: BrowserState): Record<string, unknown> {
  const changed: Record<string, unknown> = {};
  const state = s as unknown as Record<string, unknown>;
  const before = prev as unknown as Record<string, unknown>;
  const slices = ownsWorkspace ? [...WORKSPACE_SLICES, "settings", "downloads"] : ["settings", "downloads"];
  for (const key of slices) if (state[key] !== before[key] && !sameJSON(state[key], before[key])) changed[key] = state[key];
  if (ownsWorkspace && UI_KEYS.some((k) => s.ui[k] !== prev.ui[k] && !sameJSON(s.ui[k], prev.ui[k]))) {
    changed.ui = Object.fromEntries(UI_KEYS.map((k) => [k, s.ui[k]]));
  }
  return changed;
}

export function attachReplica(store: Replica, caches: (s: BrowserState) => StoreCommand[] = () => []) {
  if (!active) return;
  replica = store;
  stopListening?.();
  if (ownsWorkspace) {
    nativeWrite({ name: "closeTransactions", args: [] });
    wrapActions(store);
  } else wrapProfileSettingsWriters(store);
  const stopCommits = onForeignCommit((commit) => {
    if (commit.rev === appliedRev + 1) {
      appliedRev = commit.rev;
      inPatchOrigin(commit.patch, () => applyPatch(commit.patch));
    } else if (commit.rev > appliedRev) {
      applyResponse(nativeCatchUp(appliedRev));
    }
    inPatchOrigin(commit.patch, () => afterApplied(commit.effects));
  });
  const sendProfiles = (s: BrowserState) => nativeWrite({ name: "applyState", args: [{ profiles: s.profiles, profileOrder: s.profileOrder }] });
  if (!ownsWorkspace) sendProfiles(store.getState());
  let lastCaches = new Map<string, unknown>();
  const pushCaches = (s: BrowserState) => {
    const next = new Map<string, unknown>();
    const changed: StoreCommand[] = [];
    for (const command of caches(s)) {
      const key = command.name + (command.name === "setHistoryHints" ? `:${command.args[0]}` : "");
      next.set(key, command.args);
      if (!sameJSON(lastCaches.get(key), command.args)) changed.push(command);
    }
    lastCaches = next;
    if (changed.length) nativeWrite(changed);
  };
  if (ownsWorkspace) pushCaches(store.getState());
  const stopMirror = store.subscribe((s, prev) => {
    if (!ownsWorkspace && (s.profiles !== prev.profiles || s.profileOrder !== prev.profileOrder)) sendProfiles(s);
    if (ownsWorkspace) pushCaches(s);
  });
  const stopGuard = store.subscribe((s, prev) => {
    if (applying) return;
    const changed = ownedChanges(s, prev);
    if (!Object.keys(changed).length) return;
    const caught = new Error(`${Object.keys(changed).join(", ")} changed outside the native store's applier; route the write through nativeWrite`);
    nativeWrite({ name: "applyState", args: [changed] });
    resync(store, Object.keys(changed));
    const forwards = ((globalThis as { __nativeStoreForwards?: string[] }).__nativeStoreForwards ??= []);
    forwards.push(caught.stack ?? caught.message);
    if (forwards.length > 50) forwards.shift();
    if (__DEV__) queueMicrotask(() => {
      throw caught;
    });
    else console.warn(caught.message);
  });
  stopListening = () => {
    stopCommits();
    stopMirror();
    stopGuard();
  };
}

const OWNED_KEYS: ReadonlySet<string> = new Set([...WORKSPACE_SLICES, "settings", "downloads"]);

export function writeState(store: Replica, update: Partial<BrowserState> | ((s: BrowserState) => Partial<BrowserState>)) {
  const s = store.getState();
  const partial = typeof update === "function" ? update(s) : update;
  if (!nativeOwnsWorkspace()) return store.setState(partial);
  const before = s as unknown as Record<string, unknown>;
  const owned: Record<string, unknown> = {};
  const local: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(partial)) {
    if (value === before[key]) continue;
    if (OWNED_KEYS.has(key)) owned[key] = value;
    else if (key === "ui") {
      const ui = value as BrowserState["ui"];
      if (UI_KEYS.some((k) => ui[k] !== s.ui[k])) owned.ui = Object.fromEntries(UI_KEYS.map((k) => [k, ui[k]]));
      if (ui.appDark !== s.ui.appDark) local.ui = { ...s.ui, appDark: ui.appDark };
    } else local[key] = value;
  }
  const applyLocal = () => {
    if (!Object.keys(local).length) return;
    if (local.ui) local.ui = { ...store.getState().ui, appDark: (local.ui as BrowserState["ui"]).appDark };
    withApplier(() => store.setState(local as Partial<BrowserState>));
  };
  const nativeFirst = taggingSyncOrigins && applyingFromSync();
  if (!nativeFirst) applyLocal();
  if (Object.keys(owned).length) {
    nativeWrite({ name: "applyState", args: [owned] });
    resync(store, Object.keys(owned));
  }
  if (nativeFirst) applyLocal();
}

function resync(store: Replica, keys: string[]) {
  const snapshot = nativeSnapshot();
  if (!snapshot) return;
  const s = store.getState() as unknown as Record<string, unknown>;
  const data = snapshot.data;
  const next: Record<string, unknown> = {};
  for (const key of keys) {
    if (key === "ui") {
      const ui = { ...store.getState().ui, ...(data.ui as object) };
      if (!sameJSON(ui, store.getState().ui)) next.ui = ui;
    } else if (key in data && !sameJSON(s[key], data[key])) next[key] = data[key];
  }
  if (Object.keys(next).length) withApplier(() => store.setState(next as Partial<BrowserState>));
}

export function adoptRepairs(s: OwnedSlices, from: Partial<OwnedSlices>) {
  const changed: Partial<OwnedSlices> = {};
  if (from.settings && !sameJSON(s.settings, from.settings)) changed.settings = s.settings;
  if (from.downloads && !sameJSON(s.downloads, from.downloads)) changed.downloads = s.downloads;
  if (Object.keys(changed).length) nativeWrite({ name: "applyState", args: [changed] });
}

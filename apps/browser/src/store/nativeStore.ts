import {
  encodeCommand,
  freezeNativeStore,
  nativeCatchUp,
  nativeDispatch,
  nativeSnapshot,
  nativeStoreModulePresent,
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
import type { BrowserState, HydrateData } from "./browser";
import type { Settings } from "./settings";
import { LIVE_PATCH_COMMANDS, runEffects, WORKSPACE_COMMANDS, workspaceFromPatch, workspaceFromSnapshot, workspaceHydration } from "./nativeWorkspace";

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
let applyingUiVersions: Map<string, number> | null = null;
let replica: Replica | null = null;
let stopListening: (() => void) | null = null;
let uiVersion = 0;
const windowUiVersions = new Map<string, number>();
const revisionUiVersions = new Map<number, number>();

function observeRevision(rev: number) {
  if (!revisionUiVersions.has(rev) && rev >= appliedRev) revisionUiVersions.set(rev, uiVersion);
  while (revisionUiVersions.size > 1024) revisionUiVersions.delete(revisionUiVersions.keys().next().value!);
}

function noteLocalUi(s: BrowserState, next: Partial<BrowserState>, versions?: Map<string, number>) {
  for (const key of ["windowUi", "selection"] as const) {
    if (!next[key] || next[key] === s[key]) continue;
    for (const id of new Set([...Object.keys(s[key]), ...Object.keys(next[key])])) {
      if (s[key][id] !== next[key][id]) {
        windowUiVersions.set(id, ++uiVersion);
        versions?.set(id, uiVersion);
      }
    }
  }
}

export const nativeStoreActive = () => active;
export const nativeOwnsWorkspace = () => active && ownsWorkspace;
export const dataFolderHandedOff = () => handedOff;
export const nativeRefusedSession = () => refusedSession;
export const nativeStoreRev = () => appliedRev;

export function startNativeStore(): { active: boolean; reason?: string; modulePresent: boolean } {
  const status = nativeStoreStatus();
  active = status.active;
  ownsWorkspace = status.active && status.scope === "everything";
  handedOff = !status.active && status.handedOff === true;
  refusedSession = !status.active ? (status.refusedSession ?? null) : null;
  if (status.syncRedesign !== undefined) syncRedesign.on = status.syncRedesign;
  syncOriginsAtStart = syncRedesign.on;
  taggingSyncOrigins = status.active && syncRedesign.on && useNativeSyncOrigins(true);
  const modulePresent = nativeStoreModulePresent();
  return status.active ? { active: true, modulePresent } : { active: false, reason: status.reason, modulePresent };
}

export function nativeOwnedSnapshot(): Partial<OwnedSlices> | null {
  if (!active) return null;
  const snapshot = nativeSnapshot();
  if (!snapshot) return null;
  observeRevision(snapshot.rev);
  appliedRev = snapshot.rev;
  const data = snapshot.data as Partial<OwnedSlices>;
  return { settings: data.settings, downloads: data.downloads };
}

export function standDown() {
  freezeNativeStore();
  stopListening?.();
  stopListening = null;
  replica = null;
  windowUiVersions.clear();
  revisionUiVersions.clear();
  uiVersion = 0;
  active = false;
  ownsWorkspace = false;
}

export function hydrateFromNative(store: Replica): boolean {
  if (!nativeOwnsWorkspace()) return false;
  const snapshot = nativeSnapshot();
  if (!snapshot) return false;
  observeRevision(snapshot.rev);
  appliedRev = snapshot.rev;
  withApplier(() => store.setState(workspaceFromSnapshot(store.getState(), snapshot.data)));
  return true;
}

export function withApplier<T>(run: () => T, uiVersions: Map<string, number> | null = null): T {
  const heldUiVersions = applyingUiVersions;
  applyingUiVersions = uiVersions;
  applying++;
  try {
    return run();
  } finally {
    applying--;
    applyingUiVersions = heldUiVersions;
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

const UI_EFFECTS = new Set(["openDownloads", "closePanel", "clearSelection"]);
const changesState = (patch: StorePatch) => Object.keys(patch).some((key) => key !== "rev" && key !== "bridge" && key !== "sync");

function afterApplied(effects: StoreEffect[] | undefined, rev = appliedRev, mayBeStale = false, since: number | undefined = mayBeStale ? revisionUiVersions.get(rev) : uiVersion) {
  if (!effects?.length || !replica) return;
  const store = replica;
  const uiVersions = new Map<string, number>();
  const run = (effect: StoreEffect) => withApplier(() => runEffects([effect], () => store.getState(), (partial) => store.setState(partial)), uiVersions);
  for (const effect of effects) {
    const windowId = effect.windowId as string;
    if (UI_EFFECTS.has(effect.type) && (since === undefined || (windowUiVersions.get(windowId) ?? 0) > (uiVersions.get(windowId) ?? since))) continue;
    try {
      run({ ...effect, rev });
    } catch (error) {
      if (!(error instanceof NativeStoreBusy)) throw error;
      setTimeout(() => asSyncOrigin(() => afterApplied([effect], rev, mayBeStale, since)), BUSY_EFFECT_RETRY_MS);
    }
  }
}

function inPatchOrigin<T>(patch: StorePatch, apply: () => T): T {
  if (patch.sync) return asSyncOrigin(apply);
  return patch.bridge ? apply() : asUserChange(apply);
}

function applyResponse(response: DispatchResponse | null, fromSync = applyingFromSync()) {
  if (!response || !replica) return;
  if (response.snapshot) {
    observeRevision(response.rev);
    appliedRev = Math.max(appliedRev, response.rev);
    (fromSync ? asSyncOrigin : asUserChange)(() => applySnapshot(response.snapshot!));
    return;
  }
  for (const patch of response.patches ?? []) {
    if (patch.rev <= appliedRev) continue;
    observeRevision(patch.rev);
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

function dispatchCommands(commands: StoreCommand | StoreCommand[], acceptedOnly = false): DispatchResponse | null {
  if (!active) return null;
  if (syncRedesign.on !== syncOriginsAtStart) throw new Error("syncRedesign changed after startNativeStore; set it before the native store starts");
  const fromSync = applyingFromSync();
  const effectSince = uiVersion;
  const response = nativeDispatch(commands, appliedRev, { fromSync: taggingSyncOrigins && fromSync });
  if (!acceptedOnly || (!response.busy && !response.error)) applyResponse(response, fromSync);
  if (response.busy) {
    busyWrites++;
    throw new NativeStoreBusy();
  }
  if (!acceptedOnly || !response.error) afterApplied(response.effects, response.rev, false, effectSince);
  if (response.error) console.warn("The native store refused", commands, response.error);
  return response;
}

export function nativeWrite(commands: StoreCommand | StoreCommand[]): DispatchResponse | null {
  return dispatchCommands(commands);
}

export function nativeWriteWhenFree(command: StoreCommand) {
  try {
    nativeWrite(command);
  } catch (error) {
    if (!(error instanceof NativeStoreBusy)) throw error;
    setTimeout(() => asSyncOrigin(() => nativeWriteWhenFree(command)), BUSY_EFFECT_RETRY_MS);
  }
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
      if (!response?.error && LIVE_PATCH_COMMANDS.has(name) && typeof args[0] === "string" && args[2] && typeof args[2] === "object") updateLive(args[0], args[2]);
      return response?.result ?? undefined;
    };
  }
  wrapped.hydrate = (data: HydrateData) => {
    const response = dispatchCommands(encodeCommand("hydrate", [data]), true);
    if (!response || response.error) return;
    withApplier(() => store.setState(workspaceHydration(store.getState(), data)));
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
    const effectSince = uiVersion;
    if (commit.rev === appliedRev + 1) {
      observeRevision(commit.rev);
      appliedRev = commit.rev;
      inPatchOrigin(commit.patch, () => applyPatch(commit.patch));
    } else if (commit.rev > appliedRev) {
      applyResponse(nativeCatchUp(appliedRev));
    }
    inPatchOrigin(commit.patch, () => afterApplied(commit.effects, commit.rev, changesState(commit.patch), changesState(commit.patch) ? revisionUiVersions.get(commit.rev) : effectSince));
  });
  const sendProfiles = (s: BrowserState) => nativeWrite({ name: "applyState", args: [{ profiles: s.profiles, profileOrder: s.profileOrder }] });
  if (!ownsWorkspace) sendProfiles(store.getState());
  let lastCaches = new Map<string, unknown>();
  let pushingCaches = false;
  const pushCaches = (s: BrowserState) => {
    if (pushingCaches) return;
    const next = new Map<string, unknown>();
    const changed: StoreCommand[] = [];
    for (const command of caches(s)) {
      const key = command.name;
      next.set(key, command.args);
      if (!sameJSON(lastCaches.get(key), command.args)) changed.push(command);
    }
    if (!changed.length) {
      lastCaches = next;
      return;
    }
    pushingCaches = true;
    let succeeded = false;
    try {
      const response = nativeWrite(changed);
      if (response && !response.error) {
        lastCaches = next;
        succeeded = true;
      }
    } finally {
      pushingCaches = false;
    }
    if (succeeded) pushCaches(store.getState());
  };
  if (ownsWorkspace) pushCaches(store.getState());
  const stopMirror = store.subscribe((s, prev) => {
    if (!ownsWorkspace && (s.profiles !== prev.profiles || s.profileOrder !== prev.profileOrder)) sendProfiles(s);
    if (ownsWorkspace) pushCaches(s);
  });
  stopListening = () => {
    stopCommits();
    stopMirror();
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
    store.setState(local as Partial<BrowserState>);
  };
  const nativeFirst = taggingSyncOrigins && applyingFromSync();
  if (!nativeFirst) applyLocal();
  if (Object.keys(owned).length) {
    nativeWrite({ name: "applyState", args: [owned] });
    resync(store, Object.keys(owned));
  }
  if (nativeFirst) applyLocal();
}

function resync(_store: Replica, _keys: string[]) {
  applyResponse(nativeCatchUp(appliedRev));
}

function ownedWritePolicy(): "forward" | "refuse" {
  return "forward";
}

function forwardOwnedWrite(changed: Record<string, unknown>) {
  const caught = new Error(`${Object.keys(changed).join(", ")} changed outside the native store's applier; route the write through nativeWrite`);
  const forwards = ((globalThis as { __nativeStoreForwards?: string[] }).__nativeStoreForwards ??= []);
  forwards.push(caught.stack ?? caught.message);
  if (forwards.length > 50) forwards.shift();
  if (__DEV__) queueMicrotask(() => { throw caught; });
  else console.warn(caught.message);
  if (ownedWritePolicy() === "forward") {
    nativeWrite({ name: "applyState", args: [changed] });
    resync(replica!, Object.keys(changed));
  }
}

export function guardNativeSet(
  update: Partial<BrowserState> | ((s: BrowserState) => Partial<BrowserState>),
  replace: boolean | undefined,
  get: () => BrowserState,
  set: (update: Partial<BrowserState>, replace?: boolean) => void,
) {
  const s = get();
  const partial = typeof update === "function" ? update(s) : update;
  if (applying) {
    const heldUiVersions = applyingUiVersions;
    if (heldUiVersions) noteLocalUi(s, partial, heldUiVersions);
    const held = applying;
    applying = 0;
    applyingUiVersions = null;
    try {
      return set(partial, replace);
    } finally {
      applying = held;
      applyingUiVersions = heldUiVersions;
    }
  }
  if (!active || !replica) return set(partial, replace);
  const changed = ownedChanges({ ...s, ...partial }, s);
  const local: Record<string, unknown> = { ...partial };
  const owned = ownsWorkspace ? OWNED_KEYS : new Set(["settings", "downloads"]);
  for (const key of owned) delete local[key];
  if (ownsWorkspace && local.ui) {
    const ui = local.ui as BrowserState["ui"];
    local.ui = { ...s.ui, appDark: ui.appDark };
  }
  if (Object.keys(changed).length) forwardOwnedWrite(changed);
  if (!Object.keys(local).length) return;
  if (local.ui && ownsWorkspace) local.ui = { ...get().ui, appDark: (local.ui as BrowserState["ui"]).appDark };
  const next = local as Partial<BrowserState>;
  noteLocalUi(get(), next);
  if (!replace) return set(next, replace);
  const current = get() as unknown as Record<string, unknown>;
  const retained = Object.fromEntries([...owned].map((key) => [key, current[key]]));
  if (ownsWorkspace && !next.ui) retained.ui = { ...get().ui };
  set({ ...retained, ...next } as Partial<BrowserState>, true);
}

export function adoptRepairs(s: OwnedSlices, from: Partial<OwnedSlices>) {
  const changed: Partial<OwnedSlices> = {};
  if (from.settings && !sameJSON(s.settings, from.settings)) changed.settings = s.settings;
  if (from.downloads && !sameJSON(s.downloads, from.downloads)) changed.downloads = s.downloads;
  if (Object.keys(changed).length) nativeWrite({ name: "applyState", args: [changed] });
}

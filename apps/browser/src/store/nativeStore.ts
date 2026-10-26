import {
  nativeCatchUp,
  nativeDispatch,
  nativeSnapshot,
  nativeStoreStatus,
  onForeignCommit,
  type DispatchResponse,
  type StoreCommand,
  type StorePatch,
} from "@ardia/store";
import type { Download } from "@ardia/ardiacore";
import type { Settings } from "./settings";

type OwnedSlices = { settings: Settings; downloads: Download[] };
type ReplicaState = OwnedSlices & { profiles: Record<string, unknown>; profileOrder: string[] };
type Replica = {
  getState(): ReplicaState;
  setState(partial: Partial<OwnedSlices>): void;
  subscribe(listener: (s: ReplicaState, prev: ReplicaState) => void): () => void;
};

let active = false;
let handedOff = false;
let appliedRev = 0;
let applying = 0;
let replica: Replica | null = null;
let stopListening: (() => void) | null = null;

export const nativeStoreActive = () => active;
export const dataFolderHandedOff = () => handedOff;
export const nativeStoreRev = () => appliedRev;

export function startNativeStore(): { active: boolean; reason?: string } {
  const status = nativeStoreStatus();
  active = status.active;
  handedOff = !status.active && status.handedOff === true;
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

export function withApplier<T>(run: () => T): T {
  applying++;
  try {
    return run();
  } finally {
    applying--;
  }
}

function applyPatch(patch: StorePatch) {
  const s = replica!.getState();
  const next: Partial<OwnedSlices> = {};
  if (patch.settings) {
    const settings = { ...s.settings, ...(patch.settings.set ?? {}) } as Settings & Record<string, unknown>;
    for (const key of patch.settings.remove ?? []) delete settings[key];
    next.settings = settings;
  }
  if (patch.downloads) next.downloads = patch.downloads as Download[];
  if (Object.keys(next).length) withApplier(() => replica!.setState(next));
}

function applyResponse(response: DispatchResponse | null) {
  if (!response || !replica) return;
  if (response.snapshot) {
    const data = response.snapshot as Partial<OwnedSlices>;
    withApplier(() => replica!.setState({ ...(data.settings ? { settings: data.settings } : {}), ...(data.downloads ? { downloads: data.downloads } : {}) }));
    appliedRev = response.rev;
    return;
  }
  for (const patch of response.patches ?? []) {
    if (patch.rev <= appliedRev) continue;
    applyPatch(patch);
    appliedRev = patch.rev;
  }
  appliedRev = Math.max(appliedRev, response.rev);
}

export function nativeWrite(commands: StoreCommand | StoreCommand[]): DispatchResponse | null {
  if (!active) return null;
  const response = nativeDispatch(commands, appliedRev);
  applyResponse(response);
  if (response.error) console.warn("The native store refused", commands, response.error);
  return response;
}

function sameJSON(a: unknown, b: unknown) {
  return a === b || JSON.stringify(a) === JSON.stringify(b);
}

export function attachReplica(store: Replica) {
  if (!active) return;
  replica = store;
  stopListening?.();
  const stopCommits = onForeignCommit((commit) => {
    if (commit.rev <= appliedRev) return;
    if (commit.rev === appliedRev + 1) {
      applyPatch(commit.patch);
      appliedRev = commit.rev;
    } else {
      applyResponse(nativeCatchUp(appliedRev));
    }
  });
  const sendProfiles = (s: ReplicaState) => nativeWrite({ name: "applyState", args: [{ profiles: s.profiles, profileOrder: s.profileOrder }] });
  sendProfiles(store.getState());
  const stopProfiles = store.subscribe((s, prev) => {
    if (s.profiles !== prev.profiles || s.profileOrder !== prev.profileOrder) sendProfiles(s);
  });
  const stopGuard = store.subscribe((s, prev) => {
    if (applying) return;
    const changed: Partial<OwnedSlices> = {};
    if (s.settings !== prev.settings && !sameJSON(s.settings, prev.settings)) changed.settings = s.settings;
    if (s.downloads !== prev.downloads && !sameJSON(s.downloads, prev.downloads)) changed.downloads = s.downloads;
    if (!Object.keys(changed).length) return;
    const caught = new Error(`${Object.keys(changed).join(" and ")} changed outside the native store's applier; route the write through nativeWrite`);
    nativeWrite({ name: "applyState", args: [changed] });
    if (__DEV__) queueMicrotask(() => {
      throw caught;
    });
    else console.warn(caught.message);
  });
  stopListening = () => {
    stopCommits();
    stopProfiles();
    stopGuard();
  };
}

export function adoptRepairs(s: OwnedSlices, from: Partial<OwnedSlices>) {
  const changed: Partial<OwnedSlices> = {};
  if (from.settings && !sameJSON(s.settings, from.settings)) changed.settings = s.settings;
  if (from.downloads && !sameJSON(s.downloads, from.downloads)) changed.downloads = s.downloads;
  if (Object.keys(changed).length) nativeWrite({ name: "applyState", args: [changed] });
}

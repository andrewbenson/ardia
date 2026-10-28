import { readDocument, saveDocument, writeDocument } from "@ardia/shell";
import {
  canonical,
  Clock,
  emptyScope,
  folderTransport,
  restoreJournal,
  syncScope,
  SyncNative,
  visible,
  writtenSeq,
  type Adapter,
  type Extraction,
  type ExtensionsAdapter,
  type FolderInfo,
  type LogFile,
  type Op,
  type PhraseResult,
  type ScopeState,
  type Transport,
  hlcWall,
} from "@ardia/sync";
import { create } from "zustand";
import { useBrowser } from "../store/browser";
import { engineProfile, isIncognitoProfile } from "../store/model";
import { DEFAULT_PROFILE_ID } from "../store/settings";
import type { Profile } from "../store/types";
import {
  bookmarksAdapter,
  deviceAdapter,
  deviceTabsAdapter,
  historyAdapter,
  historyExpired,
  inTodaysNames,
  passwordsAdapter,
  profilesAdapter,
  settingsAdapter,
  settingsToReapply,
  sharedDataAdapter,
  type DeviceRecord,
  type DeviceTabs,
  type ProfileRecord,
  legacyThemeOf,
  profileThemesAdapter,
  developerModeAdapter,
  themeAngleKey,
  themeFromRecord,
  type ShareRecord,
} from "./adapters";
import { pinnedAreaAdapters } from "./pinned";
import { extensionsAdapterFor, extensionSyncAvailable, probeExtensionSync, watchExtensionIntents } from "./extensions";
import { syncRedesign } from "./redesignSwitch";
import { ledgerPasswordsAdapter, type HeldPasswords } from "./ledgerPasswords";
import { editJournal, noteInStep, noteSeen, prunableSeen, pruneSeen } from "./journalHost";

type DataType = "bookmarks" | "history" | "tabs" | "pinned" | "passwords" | "extensions" | "settings";

export const DATA_TYPES: { id: DataType; title: string; description: string }[] = [
  { id: "bookmarks", title: "Bookmarks", description: "Each synced profile’s bookmarks bar and other bookmarks." },
  { id: "history", title: "History", description: "The last 90 days." },
  { id: "tabs", title: "Open Tabs", description: "Your other devices’ tabs show in the tab overflow menu." },
  { id: "pinned", title: "Pinned Tabs and Groups", description: "Pinned tabs and pinned tab groups." },
  { id: "passwords", title: "Passwords", description: "Saved passwords. Turning sync off never removes them from this Mac." },
  { id: "extensions", title: "Extensions", description: "Extensions from the Chrome Web Store, whether they’re on, and whether they’re pinned." },
  { id: "settings", title: "Settings", description: "Search engine, appearance, tab and keyboard settings." },
];

type ProfileLink = {
  syncId: string;
  enabled: boolean;
  retire?: boolean;
  themeAdopting?: true;
};

type SyncDoc = {
  v: 1;
  enabled: boolean;
  folder: string | null;
  deviceId: string | null;
  clock: string | null;
  types: Record<DataType, boolean>;
  profiles: Record<string, ProfileLink>;
  scopes: Record<string, ScopeState>;
  lastSyncedAt: number | null;
  setupAt: number | null;
  joining: boolean;
  seqs?: Record<string, number>;
  retired?: Record<string, number>;
  rebuilding?: string[];
};

const DOC = "sync.json";
const STATE = "sync-state.nns";
const JOURNAL = "sync-journal.nns";
const APP_SCOPE = "app";
const CYCLE_MS = 15_000;
const AFTER_EDIT_MS = 3_000;

const defaultTypes = (): Record<DataType, boolean> => ({ bookmarks: true, history: true, tabs: true, pinned: true, passwords: true, extensions: true, settings: true });

const emptyDoc = (): SyncDoc => ({
  v: 1,
  enabled: false,
  folder: null,
  deviceId: null,
  clock: null,
  types: defaultTypes(),
  profiles: {},
  scopes: {},
  lastSyncedAt: null,
  setupAt: null,
  joining: false,
});

export type SyncStatus = "off" | "starting" | "updating" | "updated" | "stalled" | "offline" | "locked" | "reset" | "unavailable";

type SyncedDevice = { id: string; name: string; lastSeen: number | null; current: boolean };
export type RemoteTabs = { deviceId: string; name: string; tabs: { url: string; title: string }[] };
type RemoteProfile = { syncId: string; name: string; color: Profile["color"]; icon: string | null; sharesWith?: { name: string; added: boolean }; waiting?: true };

type SyncUi = {
  status: SyncStatus;
  enabled: boolean;
  folder: string | null;
  types: Record<DataType, boolean>;
  profiles: Record<string, ProfileLink>;
  lastSyncedAt: number | null;
  error: string | null;
  pending: number;
  devices: SyncedDevice[];
  remoteTabs: Record<string, RemoteTabs[]>;
  remoteProfiles: RemoteProfile[];
  heldPasswords: Record<string, number>;
};

export const useSync = create<SyncUi>(() => ({
  status: SyncNative ? "off" : "unavailable",
  enabled: false,
  folder: null,
  types: defaultTypes(),
  profiles: {},
  lastSyncedAt: null,
  error: null,
  pending: 0,
  devices: [],
  remoteTabs: {},
  remoteProfiles: [],
  heldPasswords: {},
}));

let doc: SyncDoc = emptyDoc();
let savedJson = "";
let running = false;
let again = false;
let timer: ReturnType<typeof setTimeout> | undefined;
let forcePasswords = false;
let cycleForcesPasswords = false;
let locked = false;
let loaded = true;
let newerFormat = false;
const NEWER_FORMAT = "This Mac's sync settings were saved by a newer version of Solara. Update Solara to keep syncing.";
let stopping = false;
let turningOn = false;
let phraseEntry: Promise<PhraseResult> | null = null;
let generation = 0;
let loading: Promise<void> | null = null;
let unverified = new Set<string>();
let unverifiedSince = 0;
let firstLooks = new Map<string, Set<string>>();
type Delivered = Map<string, Set<string>>;
let freshDelivered = new Map<string, Delivered>();
let revivalBatches = new Map<string, LogFile[]>();
type Rebuild = { since: number; settled?: string[]; noted?: Record<string, Record<string, string>> };
type Guarded = ScopeState & { rebuild?: Rebuild; heldOutbox?: Op[]; rebuildBaseline?: unknown };
const openRebuild = (): Rebuild => ({ since: Date.now() });
let baselines = new Map<string, Map<string, Map<string, string>>>();
const DOWNLOAD_GIVE_UP_MS = 86_400_000;
const FRESH_WAITS_FOR_DOWNLOADS_MS = 600_000;
const EDITABLE_WHILE_UNREADABLE = new Set(["pw:"]);
const STOP_WAITS_FOR_LOAD_MS = 3000;
let forceRequests = 0;
const passwordAdapters = new Map<string, Adapter>();
const extensionAdapters = new Map<string, ExtensionsAdapter>();

function load() {
  try {
    const json = readDocument(DOC);
    if (json) {
      const saved = JSON.parse(json) as SyncDoc;
      newerFormat = isObject(saved) && saved.v !== 1;
      if (!newerFormat) doc = { ...emptyDoc(), ...saved, types: { ...defaultTypes(), ...saved.types }, scopes: {} };
    }
    savedJson = json ?? "";
  } catch (error) {
    console.warn("[sync] couldn't read sync.json", error);
  }
}

type Journal = Record<string, LogFile[]>;
let journal: Journal = {};
let journalOnDisk = false;

async function openSealed<T>(name: string, fallback: T): Promise<T> {
  const sealed = readDocument(name);
  const json = sealed ? await SyncNative?.openLocal(sealed) : null;
  try {
    if (json) return JSON.parse(json) as T;
  } catch {}
  return fallback;
}

const isObject = (v: unknown): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v);

const readableRecord = (r: unknown) => isObject(r) && typeof r.h === "string" && Array.isArray(r.o) && typeof r.o[0] === "string" && typeof r.o[1] === "number";
const readableOp = (op: unknown) => isObject(op) && typeof op.k === "string" && typeof op.h === "string";

function readableScope(v: unknown): v is ScopeState {
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

const readableRebuild = (r: unknown) =>
  isObject(r) &&
  (r.settled === undefined || (Array.isArray(r.settled) && r.settled.every((p) => typeof p === "string"))) &&
  (r.noted === undefined || (isObject(r.noted) && Object.values(r.noted).every((n) => isObject(n) && Object.values(n).every((d) => typeof d === "string"))));

const readableBatch = (f: unknown): f is LogFile => isObject(f) && typeof f.device === "string" && typeof f.seq === "number" && Array.isArray(f.ops) && f.ops.every(readableOp);

async function loadState(loading: number): Promise<boolean> {
  const saved = await openSealed<unknown>(STATE, {});
  const savedJournal = (await openSealed<{ journal?: unknown }>(JOURNAL, {})).journal;
  if (loading !== generation) return false;
  const scopes: SyncDoc["scopes"] = {};
  for (const [name, scope] of Object.entries(isObject(saved) ? saved : {})) if (readableScope(scope)) scopes[name] = scope;
  journal = {};
  for (const [name, list] of Object.entries(isObject(savedJournal) ? savedJournal : {})) {
    const batches = Array.isArray(list) ? list.filter((f): f is LogFile => readableBatch(f) && f.device === doc.deviceId) : [];
    if (batches.length) journal[name] = batches;
  }
  journalOnDisk = Object.keys(journal).length > 0;
  const clock = new Clock(doc.deviceId ?? "", doc.clock);
  revivalBatches = new Map();
  const revived = new Map<string, number>();
  for (const link of Object.values(doc.profiles)) {
    const scope = `p:${link.syncId}`;
    const retired = doc.retired;
    const floor = retired?.[scope];
    if (!retired || floor === undefined) continue;
    doc.seqs = { ...doc.seqs, [scope]: Math.max(doc.seqs?.[scope] ?? 0, floor) };
    revived.set(scope, floor);
  }
  const skipped = (scope: string) => doc.retired?.[scope] !== undefined && !revived.has(scope);
  const expected = new Set([APP_SCOPE, ...Object.values(doc.profiles).map((l) => `p:${l.syncId}`), ...Object.keys(doc.seqs ?? {}), ...Object.keys(journal)]);
  for (const scope of expected) if (!skipped(scope) && !scopes[scope]) scopes[scope] = { ...emptyScope(), rebuild: openRebuild() } as Guarded;
  for (const [name, scope] of Object.entries(scopes) as [string, Guarded][]) {
    if ((doc.rebuilding?.includes(name) || scope.rebuildBaseline !== undefined) && !scope.rebuild) scope.rebuild = openRebuild();
    delete scope.rebuildBaseline;
  }
  delete doc.rebuilding;
  for (const scope of new Set([...Object.keys(doc.seqs ?? {}), ...Object.keys(journal)])) {
    if (skipped(scope)) continue;
    const mine = (journal[scope] ?? []).filter((f) => f.device === doc.deviceId);
    const written = doc.seqs?.[scope] ?? 0;
    if (revived.has(scope)) revivalBatches.set(scope, mine.filter((f) => f.seq <= written));
    restoreJournal((scopes[scope] ??= emptyScope()), revived.has(scope) ? mine.filter((f) => f.seq > written) : mine, clock, written);
  }
  for (const scope of revived.keys()) if (!revivalBatches.has(scope)) revivalBatches.set(scope, []);
  for (const scope of Object.values(scopes)) for (const record of Object.values(scope.records)) clock.observe(record.h);
  if (doc.deviceId) doc.clock = clock.last;
  doc.scopes = scopes;
  unverified = new Set([...expected, ...Object.keys(scopes)]);
  unverifiedSince = Date.now();
  firstLooks = new Map([...unverified].map((scope) => [scope, new Set<string>()]));
  freshDelivered = new Map();
  return true;
}

const persistJournal = (scope: string) => async (batches: LogFile[]) => {
  const list = (journal[scope] ??= []);
  for (const file of batches) if (!list.some((f) => f.device === file.device && f.seq === file.seq)) list.push(file);
  const sealed = await SyncNative!.sealLocal(JSON.stringify({ journal }));
  await saveDocument(JOURNAL, sealed);
  journalOnDisk = true;
};

function pruneJournal(saved: Record<string, number>) {
  for (const [scope, list] of Object.entries(journal)) {
    if (revivalBatches.has(scope)) continue;
    const left = list.filter((f) => f.seq > (saved[scope] ?? 0));
    if (left.length) journal[scope] = left;
    else delete journal[scope];
  }
  if (journalOnDisk && !Object.keys(journal).length) clearJournal();
}

function clearJournal() {
  journal = {};
  journalOnDisk = false;
  writeDocument(JOURNAL, "");
}

let savedState = "";
let sealing: Promise<void> | null = null;

function save() {
  if (newerFormat) return;
  const { scopes, ...meta } = doc;
  const json = JSON.stringify(loaded ? { ...meta, seqs: Object.fromEntries(Object.entries(scopes).map(([k, s]) => [k, writtenSeq(s)])) } : meta);
  if (json !== savedJson) {
    savedJson = json;
    writeDocument(DOC, json);
  }
  if (!loaded) return;
  const state = doc.enabled ? JSON.stringify(scopes) : "";
  if (state === savedState || sealing) return;
  if (!state) {
    savedState = "";
    writeDocument(STATE, "");
    return;
  }
  const seqs = Object.fromEntries(Object.entries(scopes).map(([k, s]) => [k, writtenSeq(s)]));
  const sealedDoc = doc;
  sealing = (async () => {
    let landed = false;
    try {
      const sealed = await SyncNative?.sealLocal(state);
      if (sealed) {
        await saveDocument(STATE, sealed);
        savedState = state;
        if (doc === sealedDoc) pruneJournal(seqs);
        landed = true;
      }
    } catch (error) {
      console.warn("[sync] couldn't save the sync state", error);
    } finally {
      sealing = null;
    }
    if (doc.enabled ? landed && JSON.stringify(doc.scopes) !== savedState : savedState !== "") save();
  })();
}

function publishUi(patch: Partial<SyncUi> = {}) {
  useSync.setState({
    enabled: doc.enabled,
    folder: doc.folder,
    types: { ...doc.types },
    profiles: { ...doc.profiles },
    lastSyncedAt: doc.lastSyncedAt,
    ...(doc.enabled ? summarize() : { devices: [], remoteTabs: {}, remoteProfiles: [], pending: 0 }),
    heldPasswords: heldPasswordsByProfile(),
    ...patch,
  });
}

const STORE_BACKED = ["set:", "prof:", "pth:", "share:", "devmode:", "pin", "pord:", "pgc:", "pgh:", "tilefold:"];
const storeBacked = (key: string) => STORE_BACKED.some((p) => key.startsWith(p));
type Extracted = { keys: Set<string>; ignore: (key: string) => boolean };
const extractedThisCycle = new Map<string, Map<string, Extracted>>();

function seenHooks(scope: string, state: ScopeState) {
  if (!syncRedesign.on) return {};
  return {
    beforeApply: (keys: Set<string>) => {
      for (const key of keys) {
        const record = state.records[key];
        if (record && storeBacked(key)) noteSeen(scope, key, record.o);
      }
    },
    extracted: (prefix: string, keys: Set<string>, ignore: (key: string) => boolean) => {
      if (!storeBacked(prefix)) return;
      const byPrefix = extractedThisCycle.get(scope) ?? new Map<string, Extracted>();
      byPrefix.set(prefix, { keys, ignore });
      extractedThisCycle.set(scope, byPrefix);
    },
  };
}

function pruneSeenKeys(scopes: Record<string, ScopeState>, now: number) {
  if (!syncRedesign.on) return;
  for (const [scope, state] of Object.entries(scopes)) {
    const byPrefix = extractedThisCycle.get(scope);
    pruneSeen(scope, (key) => {
      const owner = [...(byPrefix?.keys() ?? [])].filter((p) => key.startsWith(p)).sort((a, z) => z.length - a.length)[0];
      const extracted = owner ? byPrefix!.get(owner) : undefined;
      const record = state.records[key];
      return prunableSeen({
        extractedThisCycle: !!extracted,
        localHas: !!extracted?.keys.has(key),
        localIgnored: !!extracted?.ignore(key),
        record: record && { v: record.v, wall: hlcWall(record.h) },
        now,
      });
    });
  }
  extractedThisCycle.clear();
}

export const ledgerScopeOf = (profileId: string) => `${doc.folder}\n${doc.deviceId}@${doc.setupAt ?? 0}\n${doc.profiles[profileId]?.syncId ?? ""}`;

function heldPasswordsByProfile(): Record<string, number> {
  const out: Record<string, number> = {};
  for (const [profileId, adapter] of passwordAdapters) {
    const held = (adapter as Partial<HeldPasswords>).held?.() ?? 0;
    if (held) out[profileId] = held;
  }
  return out;
}

export function resolveHeldPasswords(profileId: string, choice: "restore" | "confirm") {
  (passwordAdapters.get(profileId) as Partial<HeldPasswords> | undefined)?.resolveHeld?.(choice);
  publishUi();
  forcePasswords = true;
  forceRequests++;
  scheduleSync(0);
}

export const deviceName = () => SyncNative?.deviceName() ?? "This Mac";

function appAdapters(retiring: boolean, everyType = false): Adapter[] {
  const id = doc.deviceId!;
  if (retiring) return [deviceAdapter(id, deviceName, true)];
  const enabledLinks = () => Object.fromEntries(Object.entries(doc.profiles).filter(([, l]) => l.enabled));
  return [
    ...(doc.types.settings || everyType ? [inTodaysNames(settingsAdapter)] : []),
    sharedDataAdapter(() => doc.profiles),
    profilesAdapter(enabledLinks),
    profileThemesAdapter(enabledLinks, () => doc.scopes[APP_SCOPE]?.records, themeAdopted),
    deviceAdapter(id, deviceName),
  ];
}

function profileAdapters(profileId: string, retiring: boolean, everyType = false): Adapter[] {
  const id = doc.deviceId!;
  if (retiring) return [deviceTabsAdapter(profileId, id, deviceName, true)];
  const s = useBrowser.getState();
  const ownsData = !s.profiles[profileId]?.dataId;
  const t = everyType ? { ...(Object.fromEntries(Object.keys(doc.types).map((type) => [type, true])) as typeof doc.types), history: doc.types.history, passwords: doc.types.passwords } : doc.types;
  let passwords = passwordAdapters.get(profileId);
  if (!passwords) {
    const readMarked = SyncNative?.readPasswordsWithMark?.bind(SyncNative);
    passwords = syncRedesign.on && readMarked ? ledgerPasswordsAdapter(profileId, () => cycleForcesPasswords, readMarked, () => ledgerScopeOf(profileId)) : passwordsAdapter(profileId, () => cycleForcesPasswords);
    passwordAdapters.set(profileId, passwords);
  }
  return [
    ...(t.pinned ? pinnedAreaAdapters(profileId) : []),
    ...(t.bookmarks && ownsData ? [inTodaysNames(bookmarksAdapter(profileId))] : []),
    ...(t.history && ownsData ? [inTodaysNames(historyAdapter(profileId))] : []),
    inTodaysNames(deviceTabsAdapter(profileId, id, deviceName, !t.tabs)),
    ...(t.passwords && ownsData ? [passwords] : []),
    ...(t.settings ? [developerModeAdapter(profileId)] : []),
    ...(t.extensions && ownsData && extensionSyncAvailable() ? [extensionsOf(profileId)] : []),
  ];
}

async function watchExtensions() {
  if (!doc.enabled || !doc.types.extensions) return;
  const s = useBrowser.getState();
  const profiles = [...new Set(Object.entries(doc.profiles).filter(([id, l]) => l.enabled && s.profiles[id] && !s.profiles[id]!.dataId).map(([id]) => engineProfile(id)))];
  if (profiles.length && (await probeExtensionSync(profiles[0]!))) watchExtensionIntents(profiles);
}

function extensionsOf(profileId: string): ExtensionsAdapter {
  let adapter = extensionAdapters.get(profileId);
  if (!adapter) extensionAdapters.set(profileId, (adapter = extensionsAdapterFor(profileId)));
  return adapter;
}

function scheduleSync(delay = AFTER_EDIT_MS) {
  if (!doc.enabled) return;
  clearTimeout(timer);
  timer = setTimeout(() => void runCycle(), delay);
}

export async function syncNow() {
  forcePasswords = true;
  forceRequests++;
  await runCycle();
}

async function runCycle({ retiring = false } = {}) {
  const native = SyncNative;
  if (!native || newerFormat || !doc.enabled || !doc.folder || !doc.deviceId || locked || !loaded || (stopping && !retiring)) return;
  if (running) {
    again = true;
    return;
  }
  running = true;
  extractedThisCycle.clear();
  cycleForcesPasswords = forcePasswords;
  const forcedBy = forceRequests;
  const cycleDoc = doc;
  let clock: Clock | null = null;
  clearTimeout(timer);
  const slow = setTimeout(() => useSync.getState().status === "updated" && publishUi({ status: "updating" }), 1000);
  try {
    await watchExtensions();
    const status = await native.chainStatus(doc.folder);
    if (status === "unavailable") return publishUi({ status: "offline", error: null });
    if (status === "missing") return await resetFromElsewhere();
    const transport = folderTransport(native, doc.folder);
    clock = new Clock(doc.deviceId, doc.clock);
    const device = doc.deviceId;
    const app = (doc.scopes[APP_SCOPE] ??= doc.joining ? { ...emptyScope(), awaitRemote: true } : { ...emptyScope(), joined: true });
    settleAppliedThemes(app);
    if (doc.types.settings && !retiring) app.unapplied = [...new Set([...app.unapplied, ...settingsToReapply(app.records)])];
    if (!retiring && !doc.joining) linkProfiles(app);
    const appGuard = guard(APP_SCOPE, app, device, appAdapters(retiring), transport, retiring);
    await syncScope({
      scope: APP_SCOPE,
      state: app,
      transport: appGuard.transport,
      adapters: appGuard.adapters,
      clock,
      device,
      options: { persist: persistJournal(APP_SCOPE), writtenKeysOnly: syncRedesign.on, ...seenHooks(APP_SCOPE, app) },
    });
    appGuard.settle();
    if (app.joined) linkProfiles(app);
    confirmThemes(app);
    let pending = app.pending;
    const s = useBrowser.getState();
    for (const [profileId, link] of Object.entries(doc.profiles)) {
      const exists = !!s.profiles[profileId];
      const retire = retiring || !!link.retire || !exists;
      if (!retire && !link.enabled) continue;
      const scope = `p:${link.syncId}`;
      const state = (doc.scopes[scope] ??= freshScope(scope));
      const scopeGuard = guard(scope, state, device, profileAdapters(profileId, retire), transport, retire);
      await syncScope({
        scope,
        state,
        transport: scopeGuard.transport,
        adapters: scopeGuard.adapters,
        clock,
        device,
        options: { expired: historyExpired, persist: persistJournal(scope), writtenKeysOnly: syncRedesign.on, ...seenHooks(scope, state) },
      });
      scopeGuard.settle();
      pending += state.pending;
      if (!retire && doc.types.extensions && !s.profiles[profileId]?.dataId && extensionSyncAvailable()) await extensionsOf(profileId).reconcile(visible(state, "ext:"), Date.now());
      if (retire) {
        delete link.retire;
        if (!exists) {
          doc.retired = { ...doc.retired, [scope]: state.seq };
          delete doc.scopes[scope];
          delete journal[scope];
          delete doc.profiles[profileId];
        }
      }
    }
    doc.clock = clock.last;
    doc.lastSyncedAt = Date.now();
    if (app.joined) doc.joining = false;
    pruneSeenKeys(doc.scopes, doc.lastSyncedAt);
    noteInStep(doc.scopes, doc.lastSyncedAt);
    if (forceRequests === forcedBy) forcePasswords = false;
    publishUi({ status: "updated", error: null, pending });
  } catch (error) {
    console.warn("[sync] cycle failed", error);
    publishUi({ status: "stalled", error: errorText(error) });
  } finally {
    clearTimeout(slow);
    running = false;
    cycleForcesPasswords = false;
    if (clock && doc === cycleDoc) doc.clock = clock.last;
    save();
    if (doc.enabled) {
      if (again) {
        again = false;
        scheduleSync(0);
      } else {
        scheduleSync(CYCLE_MS);
      }
    }
  }
}

function guard(scope: string, state: Guarded, device: string, adapters: Adapter[], transport: Transport, retiring: boolean) {
  const fresh = unverified.has(scope);
  if (fresh && state.outbox.length) {
    state.heldOutbox = [...(state.heldOutbox ?? []), ...state.outbox];
    state.outbox = [];
  }
  const looked = firstLooks.get(scope);
  const unlooked = (prefix: string) => !!looked && !looked.has(prefix);
  if (!fresh && !state.rebuild && !adapters.some((a) => unlooked(a.prefix))) {
    firstLooks.delete(scope);
    freshDelivered.delete(scope);
    return { adapters, transport, settle: () => settleRevival(scope, state) };
  }
  let pulled = false;
  let checked = false;
  let downloading = false;
  const delivered: Delivered = freshDelivered.get(scope) ?? new Map();
  if (looked) freshDelivered.set(scope, delivered);
  const watched: Transport = {
    ...transport,
    read: async (name, known) => {
      const listing = await transport.read(name, known);
      pulled = true;
      downloading = listing.pending.length > 0 || listing.damaged.length > 0;
      if (adapters.some((a) => unlooked(a.prefix) || rebuilding(a.prefix))) for (const file of listing.files) noteDelivered(delivered, file.payload, (key) => state.records[key]?.h);
      return listing;
    },
  };
  const waiting = () => fresh && downloading && Date.now() - unverifiedSince < FRESH_WAITS_FOR_DOWNLOADS_MS;
  const fromFolder = (key: string, value: unknown) => delivered.get(key)?.has(deliveredAs(value)) ?? false;
  const afterPull = () => {
    if (checked) return;
    checked = true;
    if (!fresh) return;
    const had = state.seq;
    state.seq = Math.max(state.seq, state.vv[device] ?? 0, ...(state.extra[device] ?? []));
    if (state.seq > had) state.rebuild ??= openRebuild();
    resendHeld(state, device);
    resendRevival(scope, state, device);
  };
  const ready = new Set<string>();
  const heldBack = new Set<string>();
  const rebuilding = (prefix: string) => !!state.rebuild && !state.rebuild.settled?.includes(prefix);
  const wrapped = adapters.map(
    (adapter): Adapter => ({
      ...adapter,
      ...(rebuilding(adapter.prefix) ? { adoptRemoteOnJoin: false } : {}),
      extract: async (base, queued, now, known, remote, stamp, downloading) => {
        if (!pulled || waiting()) return null;
        afterPull();
        const extraction = await adapter.extract(base, queued, now, known, remote, stamp, downloading);
        if (!extraction || retiring) return extraction;
        ready.add(adapter.prefix);
        if (adapter.ownsItsChanges) {
          looked?.add(adapter.prefix);
          return extraction;
        }
        if (!unlooked(adapter.prefix) && !rebuilding(adapter.prefix)) return extraction;
        const unapplied = new Set(state.unapplied);
        const stale = (key: string, value: unknown) => (unapplied.has(key) && !EDITABLE_WHILE_UNREADABLE.has(adapter.prefix)) || fromFolder(key, value);
        const guarded = guardedExtraction(scope, adapter.prefix, state, extraction, known, rebuilding(adapter.prefix) ? fromFolder : stale, rebuilding(adapter.prefix), heldBack);
        looked?.add(adapter.prefix);
        return guarded;
      },
      apply: async (visible, changed, base, records) => {
        if (waiting() || (rebuilding(adapter.prefix) && stillDownloading(state))) return false;
        const before = baselineOf(scope, adapter.prefix);
        const standIn = (key: string) => rebuilding(adapter.prefix) || heldBack.has(key);
        const ok = await adapter.apply(visible, changed, before ? (key) => base(key) ?? (standIn(key) ? parseKept(before.get(key)) : undefined) : base, records);
        if (!before || ok === false) return ok;
        const noted = rebuilding(adapter.prefix) ? notedFor(state, adapter.prefix, before) : null;
        const written = syncRedesign.on && ok instanceof Set ? [...changed].filter((key) => ok.has(key)) : changed;
        for (const key of written) {
          if (visible.has(key)) before.set(key, choice(visible.get(key)));
          else before.delete(key);
          if (!noted) continue;
          if (visible.has(key)) noted[key] = digest(choice(visible.get(key)));
          else delete noted[key];
        }
        return ok;
      },
    }),
  );
  const settle = () => {
    if (pulled && !waiting()) unverified.delete(scope);
    settleRevival(scope, state);
    const rebuild = state.rebuild;
    if (!rebuild || !pulled || stillDownloading(state)) return;
    const prefixes = adapters.map((a) => a.prefix);
    const owner = (key: string) => prefixes.filter((p) => key.startsWith(p)).sort((a, z) => z.length - a.length)[0];
    for (const prefix of prefixes) {
      if (!ready.has(prefix) || !rebuilding(prefix) || state.unapplied.some((key) => owner(key) === prefix)) continue;
      const own = adapters.find((a) => a.prefix === prefix)?.ownsItsChanges;
      const stale = own ? [] : staleKeys(state, prefix, notedFor(state, prefix, baselineOf(scope, prefix)!)).filter((key) => owner(key) === prefix);
      if (stale.length) {
        state.unapplied = [...state.unapplied, ...stale];
        continue;
      }
      rebuild.settled = [...(rebuild.settled ?? []), prefix];
      if (rebuild.noted) delete rebuild.noted[prefix];
    }
    if (Object.values(doc.types).every(Boolean) && prefixes.every((p) => !rebuilding(p))) delete state.rebuild;
  };
  return { adapters: wrapped, transport: watched, settle };
}

function staleKeys(state: ScopeState, prefix: string, noted: Record<string, string>): string[] {
  const keys = new Set([...Object.keys(state.records), ...Object.keys(noted)].filter((key) => key.startsWith(prefix)));
  return [...keys].filter((key) => {
    const value = state.records[key]?.v;
    return (value === null || value === undefined ? undefined : digest(choice(value))) !== noted[key] && !(value === undefined && key in noted);
  });
}

function notedFor(state: Guarded, prefix: string, kept: Map<string, string>): Record<string, string> {
  const rebuild = state.rebuild!;
  rebuild.noted ??= {};
  return (rebuild.noted[prefix] ??= Object.fromEntries([...kept].map(([key, value]) => [key, digest(value)])));
}

function keepNotes() {
  for (const [scope, byPrefix] of baselines) {
    const state = doc.scopes[scope] as Guarded | undefined;
    if (!state?.rebuild) continue;
    for (const [prefix, kept] of byPrefix) {
      if (state.rebuild.settled?.includes(prefix)) continue;
      const noted = notedFor(state, prefix, kept);
      for (const [key, value] of kept) noted[key] ??= digest(value);
    }
  }
}

function digest(text: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) h = Math.imul(h ^ text.charCodeAt(i), 0x01000193);
  return (h >>> 0).toString(36);
}

const choice = (value: unknown) => {
  if (!isObject(value) || !("pos" in value)) return canonical(value);
  const { pos: _derived, ...chosen } = value;
  return canonical(chosen);
};

const deliveredAs = (value: unknown) => (value === null || value === undefined ? "null" : choice(value));

function noteDelivered(delivered: Delivered, payload: string, had: (key: string) => string | undefined) {
  let file: unknown;
  try {
    file = JSON.parse(payload);
  } catch {
    return;
  }
  if (!isObject(file)) return;
  const note = (key: unknown, value: unknown, h: unknown) => {
    if (typeof key !== "string" || typeof h !== "string") return;
    const known = had(key);
    if (known !== undefined && h <= known) return;
    const seen = delivered.get(key) ?? new Set<string>();
    seen.add(deliveredAs(value));
    delivered.set(key, seen);
  };
  if (Array.isArray(file.ops)) for (const op of file.ops) if (isObject(op)) note(op.k, op.v, op.h);
  if (isObject(file.records)) for (const [key, record] of Object.entries(file.records)) if (isObject(record)) note(key, record.v, record.h);
}

const parseKept = (text: string | undefined) => (text === undefined ? undefined : (JSON.parse(text) as unknown));

function baselineOf(scope: string, prefix: string) {
  return baselines.get(scope)?.get(prefix);
}

function noteBaseline(scope: string, prefix: string, extraction: Extraction) {
  let byPrefix = baselines.get(scope);
  if (!byPrefix) baselines.set(scope, (byPrefix = new Map()));
  if (byPrefix.has(prefix)) return false;
  byPrefix.set(prefix, new Map([...extraction.values].map(([key, value]) => [key, choice(value)])));
  if (loaded) keepNotes();
  return true;
}

function stillDownloading(state: ScopeState): boolean {
  const now = Date.now();
  const young = (at: number) => now - at <= DOWNLOAD_GIVE_UP_MS;
  return Object.values(state.pendingSince ?? {}).some(young) || Object.entries(state.damaged).some(([id, at]) => !state.files[id] && young(at));
}

function guardedExtraction(
  scope: string,
  prefix: string,
  state: Guarded,
  extraction: Extraction,
  known: (key: string) => boolean,
  fromFolder: (key: string, value: unknown) => boolean,
  rebuilding: boolean,
  heldBack: Set<string>,
): Extraction {
  noteBaseline(scope, prefix, extraction);
  const kept = baselineOf(scope, prefix)!;
  const noted = rebuilding ? notedFor(state, prefix, kept) : null;
  const downloading = rebuilding && stillDownloading(state);
  const edited = (key: string, value: unknown) => (noted ? noted[key] !== digest(choice(value)) : kept.get(key) !== choice(value));
  const recorded = (key: string, value: unknown) => {
    const record = state.records[key];
    return !!record && record.v !== null && choice(record.v) === choice(value);
  };
  const changedHere = (key: string, value: unknown) => kept.has(key) && kept.get(key) !== choice(value);
  const publishes = (key: string, value: unknown) => {
    if (!known(key)) return !downloading;
    if (!rebuilding) return edited(key, value) || !fromFolder(key, value);
    return !recorded(key, value) && (changedHere(key, value) || (edited(key, value) && !fromFolder(key, value)));
  };
  const values = new Map([...extraction.values].filter(([key, value]) => publishes(key, value)));
  const gone = [...(noted ? Object.keys(noted) : kept.keys())].filter((key) => key.startsWith(prefix) && !extraction.values.has(key) && !extraction.ignore?.(key) && known(key));
  const deleted = new Set(gone.filter((key) => !rebuilding || kept.has(key) || !fromFolder(key, null)));
  const settledHere = rebuilding ? [...extraction.values].filter(([key, value]) => known(key) && !values.has(key) && edited(key, value)) : [];
  for (const key of deleted) {
    const record = state.records[key];
    if (record && record.v !== null && state.base[key] === undefined) state.base[key] = canonical(record.v);
  }
  const backToBase = new Set([...values].filter(([key, value]) => (rebuilding ? changedHere(key, value) : edited(key, value)) && state.base[key] === canonical(value)).map(([key]) => key));
  for (const [key, value] of [...values, ...settledHere]) {
    kept.set(key, choice(value));
    if (noted) noted[key] = digest(choice(value));
  }
  for (const key of gone) {
    kept.delete(key);
    if (noted) delete noted[key];
  }
  for (const key of extraction.values.keys()) if (known(key) && !values.has(key)) heldBack.add(key);
  const deferred = (key: string) => rebuilding || fromFolder(key, extraction.values.get(key) ?? null);
  return {
    values,
    ignore: (key) => (extraction.ignore?.(key) ?? false) || (!values.has(key) && !deleted.has(key) && deferred(key)),
    republish: (key) => backToBase.has(key) || (extraction.republish?.(key) ?? false),
    published: extraction.published,
  };
}

function resendHeld(state: Guarded, device: string) {
  const held = state.heldOutbox;
  delete state.heldOutbox;
  if (!held?.length) return;
  for (const op of held) {
    const record = state.records[op.k];
    if (record && record.h === op.h) record.o = [device, state.seq + 1];
  }
  state.outbox = [...held, ...state.outbox];
}

function settleRevival(scope: string, state: ScopeState) {
  const held = revivalBatches.get(scope);
  if (!held || held.length || state.outbox.length || state.journal?.length) return;
  revivalBatches.delete(scope);
  if (!doc.retired) return;
  delete doc.retired[scope];
  if (!Object.keys(doc.retired).length) delete doc.retired;
}

function resendRevival(scope: string, state: ScopeState, device: string) {
  const held = revivalBatches.get(scope);
  if (!held?.length) return;
  for (const file of held) {
    for (const op of file.ops) {
      const current = state.records[op.k];
      if (current && current.h >= op.h) continue;
      state.records[op.k] = { h: op.h, v: op.v, o: [device, state.seq + 1] };
      state.outbox.push(op);
    }
  }
  held.length = 0;
}

async function noteWhatThisMacHas(only?: string) {
  if (only === undefined) baselines = new Map();
  const scopes = [[APP_SCOPE, null] as const, ...Object.entries(doc.profiles).map(([id, link]) => [`p:${link.syncId}`, id] as const)];
  const toNote = scopes.flatMap(([scope, profileId]) =>
    (profileId === null ? appAdapters(false, true) : profileAdapters(profileId, false, true))
      .filter((adapter) => adapter.prefix !== "ext:" && !adapter.ownsItsChanges && (only === undefined || adapter.prefix === only))
      .map((adapter) => [scope, adapter] as const),
  );
  const passwordsLast = [...toNote.filter(([, a]) => a.prefix !== "pw:"), ...toNote.filter(([, a]) => a.prefix === "pw:")];
  for (const [scope, adapter] of passwordsLast) {
    if (baselineOf(scope, adapter.prefix)) continue;
    try {
      const extraction = await adapter.extract(() => undefined, () => false, Date.now(), () => false, () => undefined, () => undefined, () => false);
      if (extraction) noteBaseline(scope, adapter.prefix, extraction);
    } catch (error) {
      console.warn(`[sync] ${adapter.prefix} wasn't ready to note what this Mac had`, error);
    }
  }
}

const rebuildingAny = () => Object.values(doc.scopes).some((state) => !!(state as Guarded).rebuild);

function freshScope(scope: string, extra: Partial<ScopeState> = {}): ScopeState {
  const seq = doc.retired?.[scope];
  if (seq === undefined) return { ...emptyScope(), ...extra };
  const { [scope]: _gone, ...rest } = doc.retired!;
  if (Object.keys(rest).length) doc.retired = rest;
  else delete doc.retired;
  return { ...emptyScope(), ...extra, seq };
}

const errorText = (error: unknown) => (error instanceof Error ? error.message : String(error));

function pairedTheme(app: ScopeState, syncId: string): Pick<Profile, "theme"> | null {
  const record = app.records[`pth:${syncId}`]?.v;
  if (record) return themeFromRecord(record, app.records[themeAngleKey(syncId)]?.v);
  const profile = app.records[`prof:${syncId}`]?.v as ProfileRecord | null | undefined;
  return profile ? legacyThemeOf(profile) : null;
}

function settledTheme(app: ScopeState, syncId: string): boolean {
  const record = app.records[`pth:${syncId}`]?.v;
  return !!record && !!themeFromRecord(record);
}

function pairTheme(app: ScopeState, profileId: string, link: ProfileLink) {
  const theme = pairedTheme(app, link.syncId);
  if (theme) useBrowser.getState().updateProfile(profileId, theme);
  if (settledTheme(app, link.syncId)) delete link.themeAdopting;
  else link.themeAdopting = true;
}

function settleAppliedThemes(app: ScopeState | undefined) {
  if (!app) return;
  for (const link of Object.values(doc.profiles)) {
    if (!link.themeAdopting) continue;
    const key = `pth:${link.syncId}`;
    const record = app.records[key]?.v;
    if (record && themeFromRecord(record) && app.base[key] === canonical(record)) delete link.themeAdopting;
  }
}

function confirmThemes(app: ScopeState) {
  settleAppliedThemes(app);
  if (app.pending > 0 || Object.keys(app.damaged).length > 0) return;
  if (Object.values(app.files).some((f) => f.k === "bad")) return;
  for (const link of Object.values(doc.profiles)) {
    if (!link.themeAdopting) continue;
    const record = app.records[`pth:${link.syncId}`];
    if (!record || record.v === null) delete link.themeAdopting;
  }
}

function themeAdopted(profileId: string) {
  const link = doc.profiles[profileId];
  if (link?.themeAdopting) delete link.themeAdopting;
}

export function adoptProfileTheme(profileId: string) {
  const link = doc.profiles[profileId];
  if (!link?.themeAdopting) return;
  delete link.themeAdopting;
  save();
  if (doc.enabled) scheduleSync(AFTER_EDIT_MS);
}

function linkProfiles(app: ScopeState) {
  const s = useBrowser.getState();
  const remote = [...visible(app, "prof:")].map(([k, v]) => [k.slice(5), v as ProfileRecord] as const);
  const taken = new Set(Object.values(doc.profiles).map((l) => l.syncId));
  for (const id of s.profileOrder) {
    const profile = s.profiles[id];
    if (!profile || isIncognitoProfile(id) || doc.profiles[id]) continue;
    const match = doc.joining
      ? remote.find(([syncId, r]) => !taken.has(syncId) && (id === DEFAULT_PROFILE_ID ? r.d : r.n === profile.name))?.[0]
      : undefined;
    const syncId = match ?? SyncNative!.newDeviceId();
    doc.profiles[id] = { syncId, enabled: true };
    taken.add(syncId);
    if (match) {
      doc.scopes[`p:${syncId}`] = freshScope(`p:${syncId}`, { awaitRemote: true });
      pairTheme(app, id, doc.profiles[id]!);
    }
  }
  for (const [id, link] of Object.entries(doc.profiles)) if (!s.profiles[id] && !link.retire) link.retire = true;
}

async function resetFromElsewhere() {
  await SyncNative?.forget(doc.deviceId!);
  generation++;
  doc = { ...emptyDoc(), folder: doc.folder, types: doc.types };
  passwordAdapters.clear();
  extensionAdapters.clear();
  clearJournal();
  save();
  publishUi({ status: "reset", error: "This device is out of sync. Sync may have been reset from another device." });
}

function summarize(): Pick<SyncUi, "devices" | "remoteTabs" | "remoteProfiles"> {
  const app = doc.scopes[APP_SCOPE];
  if (!app) return { devices: [], remoteTabs: {}, remoteProfiles: [] };
  const lastSeen = new Map<string, number>();
  for (const scope of Object.values(doc.scopes)) {
    for (const [device, at] of Object.entries(scope.seen)) lastSeen.set(device, Math.max(at, lastSeen.get(device) ?? 0));
  }
  const names = new Map([...visible(app, "dev:")].map(([k, v]) => [k.slice(4), (v as DeviceRecord).n]));
  const devices: SyncedDevice[] = [...names].map(([id, name]) => ({ id, name, lastSeen: lastSeen.get(id) ?? null, current: id === doc.deviceId }));
  devices.sort((a, b) => Number(b.current) - Number(a.current) || (b.lastSeen ?? 0) - (a.lastSeen ?? 0));
  const remoteTabs: Record<string, RemoteTabs[]> = {};
  for (const [profileId, link] of Object.entries(doc.profiles)) {
    const scope = doc.scopes[`p:${link.syncId}`];
    if (!scope || !link.enabled) continue;
    remoteTabs[profileId] = [...visible(scope, "tabs:")]
      .map(([k, v]) => ({ deviceId: k.slice(5), value: v as DeviceTabs }))
      .filter(({ deviceId, value }) => deviceId !== doc.deviceId && names.has(deviceId) && value.tabs.length > 0)
      .map(({ deviceId, value }) => ({ deviceId, name: names.get(deviceId) || value.n || "Unknown Device", tabs: value.tabs.map((t) => ({ url: t.u, title: t.t })) }));
  }
  const linked = new Set(Object.values(doc.profiles).map((l) => l.syncId));
  const remoteProfiles = [...visible(app, "prof:")]
    .filter(([k]) => !linked.has(k.slice(5)))
    .map(([k, v]): RemoteProfile => {
      const syncId = k.slice(5);
      const record = v as ProfileRecord;
      const { adds, sharesWith, waitingFor } = sharedDataChain(syncId);
      const ownerName = adds[1] ? remoteProfileRecord(adds[1])?.n : sharesWith ? useBrowser.getState().profiles[sharesWith]?.name : undefined;
      return {
        syncId,
        name: record.n,
        color: record.c,
        icon: record.i,
        ...(ownerName !== undefined ? { sharesWith: { name: ownerName, added: !!adds[1] } } : {}),
        ...(waitingFor ? { waiting: true as const } : {}),
      };
    });
  return { devices, remoteTabs, remoteProfiles };
}

export async function folderInfo(path?: string | null): Promise<FolderInfo | null> {
  return (await SyncNative?.folderInfo(path ?? doc.folder ?? null)) ?? null;
}

function setSyncFolder(path: string) {
  if (doc.enabled) return;
  doc.folder = path;
  save();
  publishUi();
}

export async function chooseSyncFolder(): Promise<string | null> {
  const picked = (await SyncNative?.chooseFolder(doc.folder)) ?? null;
  if (picked) setSyncFolder(picked);
  return picked;
}

function begin(folder: string, deviceId: string, joining: boolean) {
  generation++;
  unverified = new Set();
  firstLooks = new Map();
  freshDelivered = new Map();
  revivalBatches = new Map();
  doc = { ...emptyDoc(), types: doc.types, enabled: true, folder, deviceId, setupAt: Date.now(), joining };
  locked = false;
  loaded = true;
  clearJournal();
  save();
  publishUi({ status: "starting", error: null });
  scheduleSync(0);
}

export async function turnOnSync(folder: string): Promise<{ ok: true } | { error: string }> {
  const native = SyncNative;
  if (!native) return { error: "Sync isn’t available in this build." };
  if (newerFormat) return { error: NEWER_FORMAT };
  if (doc.enabled || turningOn) return { error: "Sync is already on." };
  turningOn = true;
  try {
    return await turnOn(native, folder);
  } finally {
    turningOn = false;
  }
}

async function turnOn(native: NonNullable<typeof SyncNative>, folder: string): Promise<{ ok: true } | { error: string }> {
  const deviceId = native.newDeviceId();
  try {
    if (!(await native.createPhrase(deviceId))) return { error: "Couldn’t save the sync key in your Keychain." };
    await native.createChain(folder);
  } catch (error) {
    await native.forget(deviceId);
    return { error: `Couldn’t use that folder: ${errorText(error)}` };
  }
  begin(folder, deviceId, false);
  return { ok: true };
}

export async function enterRecoveryPhrase(folder: string, text: string): Promise<PhraseResult | { error: "unavailable" }> {
  const native = SyncNative;
  if (!native) return { error: "unavailable" };
  if (doc.enabled && doc.deviceId && locked) {
    if (phraseEntry) return phraseEntry;
    phraseEntry = unlockWithPhrase(native, folder, text);
    try {
      return await phraseEntry;
    } finally {
      phraseEntry = null;
    }
  }
  if (newerFormat || doc.enabled || turningOn) return { error: "unavailable" };
  turningOn = true;
  try {
    const deviceId = native.newDeviceId();
    const result = await native.enterPhrase(deviceId, text, folder);
    if ("ok" in result) begin(folder, deviceId, true);
    return result;
  } finally {
    turningOn = false;
  }
}

async function unlockWithPhrase(native: NonNullable<typeof SyncNative>, folder: string, text: string): Promise<PhraseResult> {
  const unlocking = generation;
  const result = await native.enterPhrase(doc.deviceId!, text, doc.folder ?? folder);
  if (!("ok" in result)) return result;
  if (unlocking !== generation) return { error: "interrupted" };
  try {
    if (!(await loadState(unlocking)) || unlocking !== generation) return { error: "interrupted" };
    loaded = true;
    keepNotes();
    if (rebuildingAny()) save();
  } catch (error) {
    if (unlocking === generation) showLocked(error);
    return { error: "keychain" };
  }
  locked = false;
  loaded = true;
  publishUi({ status: "starting", error: null });
  scheduleSync(0);
  return result;
}

const LOCKED_MESSAGE = "Enter your recovery phrase to keep syncing on this Mac.";

function showLocked(error?: unknown) {
  locked = true;
  loaded = false;
  if (error) console.warn("[sync] couldn't open the saved sync state", error);
  publishUi({ status: "locked", error: LOCKED_MESSAGE });
}

export async function stopSync({ deleteData = false } = {}) {
  const native = SyncNative;
  if (!native || !doc.enabled || stopping) return;
  stopping = true;
  try {
    await turnOff(native, deleteData);
  } finally {
    stopping = false;
  }
}

async function turnOff(native: NonNullable<typeof SyncNative>, deleteData: boolean) {
  clearTimeout(timer);
  if (loading && !loaded && !locked) await Promise.race([loading, new Promise((r) => setTimeout(r, STOP_WAITS_FOR_LOAD_MS))]);
  while (running) await new Promise((r) => setTimeout(r, 100));
  try {
    if (!locked) await runCycle({ retiring: true });
  } catch {}
  clearTimeout(timer);
  const folder = doc.folder;
  if (deleteData && folder) {
    try {
      await native.deleteChain(folder);
    } catch (error) {
      console.warn("[sync] deleting sync data failed", error);
    }
  }
  if (doc.deviceId) await native.forget(doc.deviceId);
  generation++;
  revivalBatches = new Map();
  doc = { ...emptyDoc(), folder, types: doc.types };
  locked = false;
  loaded = true;
  passwordAdapters.clear();
  extensionAdapters.clear();
  clearJournal();
  savedState = "";
  writeDocument(STATE, "");
  save();
  publishUi({ status: "off", error: null });
}

export function setTypeSynced(type: DataType, enabled: boolean) {
  doc.types = { ...doc.types, [type]: enabled };
  save();
  publishUi();
  scheduleSync(0);
}

export function setProfileSynced(profileId: string, enabled: boolean) {
  const link = doc.profiles[profileId];
  if (!link) return;
  doc.profiles[profileId] = enabled
    ? { syncId: link.syncId, enabled, ...(link.themeAdopting ? { themeAdopting: true as const } : {}) }
    : { ...link, enabled, retire: true };
  save();
  publishUi();
  scheduleSync(0);
}

const remoteProfileRecord = (syncId: string) => (doc.scopes[APP_SCOPE]?.records[`prof:${syncId}`]?.v ?? undefined) as ProfileRecord | undefined;

const sharedDataOwner = (syncId: string): string | null => {
  const owner = (doc.scopes[APP_SCOPE]?.records[`share:${syncId}`]?.v as ShareRecord | null | undefined)?.o;
  return owner && owner !== syncId ? owner : null;
};

const linkedProfileId = (syncId: string): string | null => {
  const profiles = useBrowser.getState().profiles;
  return Object.entries(doc.profiles).find(([id, link]) => link.syncId === syncId && !link.retire && profiles[id])?.[0] ?? null;
};

function sharedDataChain(syncId: string): { adds: string[]; sharesWith: string | null; waitingFor?: string } {
  const adds = [syncId];
  for (let at = syncId; ; ) {
    const owner = sharedDataOwner(at);
    if (!owner) return { adds, sharesWith: null };
    const here = linkedProfileId(owner);
    if (here) return { adds, sharesWith: here };
    if (!remoteProfileRecord(owner)) return { adds, sharesWith: null, waitingFor: owner };
    if (adds.includes(owner)) {
      const lowest = adds.slice(adds.indexOf(owner)).sort()[0]!;
      return { adds: adds.slice(0, adds.indexOf(lowest) + 1), sharesWith: null };
    }
    adds.push(owner);
    at = owner;
  }
}

export const appScopeRecords = () => doc.scopes[APP_SCOPE]?.records ?? {};

export function addRemoteProfile(syncId: string): string | null {
  if (!remoteProfileRecord(syncId) || linkedProfileId(syncId)) return null;
  const { adds, sharesWith, waitingFor } = sharedDataChain(syncId);
  if (waitingFor) return null;
  let shareWith = sharesWith;
  for (const add of adds.reverse()) shareWith = addLinkedProfile(add, remoteProfileRecord(add)!, shareWith);
  save();
  publishUi();
  scheduleSync(0);
  return shareWith;
}

function addLinkedProfile(syncId: string, record: ProfileRecord, shareWith: string | null): string {
  const id = useBrowser.getState().createProfile({ name: record.n, color: record.c, icon: record.i, shareWith });
  const app = doc.scopes[APP_SCOPE];
  doc.profiles[id] = { syncId, enabled: true };
  if (app) pairTheme(app, id, doc.profiles[id]!);
  else {
    const theme = legacyThemeOf(record);
    if (theme) useBrowser.getState().updateProfile(id, theme);
    doc.profiles[id]!.themeAdopting = true;
  }
  doc.scopes[`p:${syncId}`] = freshScope(`p:${syncId}`, { awaitRemote: true });
  return id;
}

export function startSync() {
  if (!SyncNative) return;
  load();
  editJournal();
  if (newerFormat) return publishUi({ status: "unavailable", error: NEWER_FORMAT });
  publishUi({ status: doc.enabled ? "starting" : "off" });
  void watchExtensions();
  if (doc.enabled && doc.deviceId) {
    loaded = false;
    void noteWhatThisMacHas();
    const unlocking = ++generation;
    loading = SyncNative.unlock(doc.deviceId)
      .then(async (ok) => {
        if (unlocking !== generation) return;
        if (!ok) return showLocked();
        if (!(await loadState(unlocking)) || unlocking !== generation) return;
        loaded = true;
        keepNotes();
        if (rebuildingAny()) save();
        settleAppliedThemes(doc.scopes[APP_SCOPE]);
        publishUi();
        scheduleSync(500);
      })
      .catch((error) => {
        if (unlocking === generation) showLocked(error);
      })
      .finally(() => {
        if (unlocking === generation) loading = null;
      });
  }
  useBrowser.subscribe((s, prev) => {
    if (doc.enabled && s.bookmarksReady !== prev.bookmarksReady) void noteWhatThisMacHas("bm:");
    if (doc.enabled && s.historyReady !== prev.historyReady) void noteWhatThisMacHas("h:");
    if (!doc.enabled || running) return;
    if (s.bookmarks !== prev.bookmarks || s.settings !== prev.settings || s.profiles !== prev.profiles || s.groups !== prev.groups) scheduleSync();
  });
  if (__DEV__) {
    (globalThis as { acSync?: object }).acSync = {
      useSync, syncNow, turnOnSync, enterRecoveryPhrase, stopSync, setTypeSynced, setProfileSynced, addRemoteProfile, setSyncFolder, folderInfo,
      doc: () => doc,
      native: SyncNative,
      get menu(): typeof import("./menu") {
        return require("./menu");
      },
      get sheets(): typeof import("../components/settings/panes/SyncSheets") {
        return require("../components/settings/panes/SyncSheets");
      },
    };
  }
}

import { liveCommand, liveInitialReplica, onLiveReplica, type LiveReplica } from "@ardia/settings";
import { create } from "zustand";
import type { CompletedItem, CompletionState, FolderStatus, LiveAccount, LiveFolder, LiveFolderKind, LiveItem, LiveSourceId } from "./types";

export type LiveConfig = {
  githubClientId: string;
  bitbucketUser: string;
  confluenceSite: string;
  confluenceEmail: string;
  googleClientId: string;
};

export type CalendarSettings = {
  alertLead: string;
  alertCondition: "always" | "activeOnly";
  showPreview: boolean;
  showTimeToNext: boolean;
  hiddenCalendarIds: string[];
  prompted: boolean;
};

export type MeetingGroup = {
  groupId: string;
  callTabId: string;
  occurrence: string | null;
  title: string;
  start: number | null;
  end: number | null;
  endedAt: number | null;
};

type LiveState = {
  folders: Record<string, LiveFolder>;
  folderOrder: string[];
  items: Record<string, LiveItem[]>;
  known: Record<string, string[]>;
  unread: Record<string, string[]>;
  hidden: Record<string, LiveItem[]>;
  completed: Record<string, CompletedItem[]>;
  completing: Record<string, string[]>;
  status: Record<string, FolderStatus>;
  expandedStacks: Record<string, boolean>;
  showAll: Record<string, boolean>;
  accounts: Partial<Record<LiveSourceId, LiveAccount>>;
  config: LiveConfig;
  calendar: CalendarSettings;
  meetingGroups: Record<string, MeetingGroup>;
  dismissedAlerts: string[];
};

export const DEFAULT_CONFIG: LiveConfig = { githubClientId: "", bitbucketUser: "", confluenceSite: "", confluenceEmail: "", googleClientId: "" };

export const DEFAULT_CALENDAR: CalendarSettings = {
  alertLead: "1",
  alertCondition: "always",
  showPreview: true,
  showTimeToNext: true,
  hiddenCalendarIds: [],
  prompted: false,
};

const FOLDER_OPTION_DEFAULTS = { groupStacks: true, showCompleted: true } satisfies Partial<LiveFolder>;

const withOptionDefaults = (folders: Record<string, LiveFolder> = {}) =>
  Object.fromEntries(Object.entries(folders).map(([id, f]) => [id, { ...FOLDER_OPTION_DEFAULTS, ...f }]));

const empty = (): LiveState => ({
  folders: {}, folderOrder: [], items: {}, known: {}, unread: {}, hidden: {}, completed: {}, completing: {}, status: {}, expandedStacks: {}, showAll: {},
  accounts: {}, config: DEFAULT_CONFIG, calendar: DEFAULT_CALENDAR, meetingGroups: {}, dismissedAlerts: [],
});

const initial = (() => {
  try { return liveInitialReplica(); }
  catch { return { revision: 0, replicaJSON: "{}" }; }
})();

const parseReplica = (replica: LiveReplica): Partial<LiveState> => JSON.parse(replica.replicaJSON) as Partial<LiveState>;
const saved = parseReplica(initial);
let lastRevision = initial.revision;
let fieldJSON: Partial<Record<keyof LiveState, string>> = {};

export const useLive = create<LiveState>()(() => ({
  ...empty(),
  ...saved,
  folders: withOptionDefaults(saved.folders),
  config: { ...DEFAULT_CONFIG, ...saved.config },
  calendar: { ...DEFAULT_CALENDAR, ...saved.calendar },
  showAll: {},
}));

for (const [key, value] of Object.entries(useLive.getState())) fieldJSON[key as keyof LiveState] = JSON.stringify(value);

export const live = () => useLive.getState();
export const setLive = (patch: Partial<Pick<LiveState, "showAll">> | ((s: LiveState) => Partial<Pick<LiveState, "showAll">>)) => {
  const next = typeof patch === "function" ? patch(live()) : patch;
  if (next.showAll) useLive.setState({ showAll: next.showAll });
};

export function applyLiveReplica(replica: LiveReplica): void {
  if (replica.revision <= lastRevision) return;
  const parsed = parseReplica(replica);
  const before = live();
  const changed: Partial<LiveState> = {};
  for (const key of Object.keys(parsed) as (keyof LiveState)[]) {
    if (key === "showAll") continue;
    const value = parsed[key];
    const json = JSON.stringify(value);
    if (json === fieldJSON[key]) continue;
    fieldJSON[key] = json;
    (changed as Record<string, unknown>)[key] = key === "folders" ? withOptionDefaults(value as LiveState["folders"]) : value;
  }
  lastRevision = replica.revision;
  if (Object.keys(changed).length) useLive.setState({ ...changed, showAll: before.showAll });
}

onLiveReplica(applyLiveReplica);
try { applyLiveReplica(liveInitialReplica()); } catch {}

export const FOLDER_DEFAULTS: Record<LiveFolderKind, { name: string; sources: LiveSourceId[] }> = {
  pullRequests: { name: "Pull Requests", sources: ["github"] },
  documents: { name: "Documents", sources: ["notion"] },
};

const command = (name: string, payload: Record<string, unknown>) => liveCommand(name, payload);

export async function createFolder(profileId: string, kind: LiveFolderKind, sources?: LiveSourceId[]): Promise<string> {
  const result = await command("createFolder", { profileId, kind, ...(sources ? { sources } : {}) });
  if (!result.folderId) throw new Error("Live folder creation returned no ID");
  return result.folderId;
}

export const updateFolder = (folderId: string, patch: Partial<Omit<LiveFolder, "id" | "profileId" | "kind">>) => command("updateFolder", { folderId, patch });
export const removeFolder = (folderId: string) => command("removeFolder", { folderId });
export const arrangeFolders = (placed: { id: string; after: string | null }[]) => command("arrangeFolders", { placed });
export const applyFetch = (folderId: string, items: LiveItem[], gone: Record<string, CompletionState>) => command("applyFetch", { folderId, items, gone });
export const setStatus = (folderId: string, status: Partial<FolderStatus>) => command("setStatus", { folderId, status });
export const markRead = (folderId: string, itemIds?: string[]) => command("markRead", { folderId, ...(itemIds ? { itemIds } : {}) });
export const markUnread = (folderId: string, itemId: string) => command("markUnread", { folderId, itemId });
export const hideItems = (folderId: string, items: LiveItem[]) => command("hideItems", { folderId, items });
export const unhide = (folderId: string) => command("unhide", { folderId });
export const setExpandedStack = (key: string, expanded: boolean) => command("setExpandedStack", { key, expanded });
export const updateConfig = (patch: Partial<LiveConfig>) => command("updateConfig", { patch });
export const updateCalendarSettings = (patch: Partial<CalendarSettings>) => command("updateCalendarSettings", { patch });
export const setCalendarHidden = (id: string, hidden: boolean) => command("setCalendarHidden", { id, hidden });
export const dismissAlert = (occurrence: string) => command("dismissAlert", { occurrence });
export const setMeetingGroup = (group: MeetingGroup | null, groupId?: string) => command("setMeetingGroup", { group, ...(groupId ? { groupId } : {}) });

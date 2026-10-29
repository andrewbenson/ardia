import { focusWindow } from "@ardia/shell";
import { publishSettingsTopic, type SettingsHandler } from "@ardia/settings";
import { connectCalendar, refreshCalendar, setCalendarHidden, useCalendar } from "../../../live/calendar";
import { deleteLiveFolder, manualRefresh } from "../../../live/engine";
import { connectGoogleDrive } from "../../../live/googleAuth";
import { isMocked } from "../../../live/net";
import { connectBitbucket, connectConfluence, connectGithub, connectNotion, disconnect, startGithubDeviceFlow, type DeviceFlow } from "../../../live/sources";
import { updateCalendarSettings, updateConfig, updateFolder, useLive, type CalendarSettings } from "../../../live/store";
import type { LiveSourceId } from "../../../live/types";
import { useBrowser } from "../../../store/browser";

const deviceFlows = new Map<string, DeviceFlow>();

function browserWindow(): string | null {
  const s = useBrowser.getState();
  return s.ui.focusOrder.find((id) => s.windows[id] && !s.windows[id]!.incognito) ?? s.windowOrder.find((id) => !s.windows[id]!.incognito) ?? null;
}

function openInBrowser(url: string) {
  const windowId = browserWindow();
  if (!windowId) return;
  useBrowser.getState().newTab(windowId, { url });
  void focusWindow(windowId);
}

function pickBooleans<K extends string>(patch: Record<string, unknown>, keys: readonly K[]): Partial<Record<K, boolean>> {
  const picked: Partial<Record<K, boolean>> = {};
  for (const key of keys) if (typeof patch[key] === "boolean") picked[key] = patch[key] as boolean;
  return picked;
}

const ALERT_CONDITIONS: readonly CalendarSettings["alertCondition"][] = ["always", "activeOnly"];

export const liveHandlers: Record<string, SettingsHandler> = {
  "liveFolders.refreshFolder": (id: string) => manualRefresh(id),
  "liveFolders.deleteFolder": (id: string) => deleteLiveFolder(id),
  "liveFolders.updateFolder": (id: string, patch: Record<string, unknown>) => {
    if (!useLive.getState().folders[id]) return;
    return updateFolder(id, pickBooleans(patch ?? {}, ["groupStacks", "showCompleted"] as const));
  },
  "liveFolders.disconnect": (source: LiveSourceId) => disconnect(source),
  "liveFolders.connectGithub": (token: string) => connectGithub(token),
  "liveFolders.setGithubClientId": (clientId: string) => updateConfig({ githubClientId: clientId.trim() }),
  "liveFolders.startGithubDeviceFlow": async (clientId: string) => {
    const flow = await startGithubDeviceFlow(clientId.trim());
    const id = flow.id;
    deviceFlows.set(id, flow);
    flow.done.finally(() => deviceFlows.delete(id)).catch(() => {});
    return { id, userCode: flow.userCode, verificationUri: flow.verificationUri, expiresAt: flow.expiresAt };
  },
  "liveFolders.finishGithubDeviceFlow": async (id: string) => {
    const flow = deviceFlows.get(id);
    if (!flow) throw new Error("Cancelled");
    try {
      await flow.done;
    } finally {
      deviceFlows.delete(id);
    }
  },
  "liveFolders.cancelGithubDeviceFlow": (id: string) => {
    deviceFlows.get(id)?.cancel();
    deviceFlows.delete(id);
  },
  "liveFolders.connectBitbucket": (user: string, token: string) => connectBitbucket(user, token),
  "liveFolders.connectNotion": (token: string) => connectNotion(token),
  "liveFolders.connectConfluence": (site: string, email: string, token: string) => connectConfluence(site, email, token),
  "liveFolders.connectGoogleDrive": async (clientId: string, clientSecret: string) => {
    const windowId = browserWindow();
    if (!windowId) throw new Error("Open a browser window first");
    void focusWindow(windowId);
    await connectGoogleDrive(windowId, clientId, clientSecret);
  },
  "liveFolders.openInBrowser": (url: string) => openInBrowser(url),

  "calendar.refresh": () => refreshCalendar(),
  "calendar.connect": () => connectCalendar().then(() => undefined),
  "calendar.setHidden": (id: string, hidden: boolean) => setCalendarHidden(id, hidden),
  "calendar.updateOptions": (patch: Record<string, unknown>) => {
    const next: Partial<CalendarSettings> = pickBooleans(patch ?? {}, ["showPreview", "showTimeToNext"] as const);
    if (typeof patch?.alertLead === "string") next.alertLead = patch.alertLead;
    if (ALERT_CONDITIONS.includes(patch?.alertCondition as CalendarSettings["alertCondition"])) next.alertCondition = patch.alertCondition as CalendarSettings["alertCondition"];
    if (Object.keys(next).length) return updateCalendarSettings(next);
  },
};

type LiveState = ReturnType<typeof useLive.getState>;

function foldersTopic(s: LiveState) {
  return {
    folders: s.folderOrder
      .map((id) => s.folders[id])
      .filter((f) => !!f)
      .map((f) => {
        const status = s.status[f.id];
        return {
          id: f.id,
          profileId: f.profileId,
          kind: f.kind,
          name: f.name,
          sources: f.sources,
          groupStacks: f.groupStacks,
          showCompleted: f.showCompleted,
          status: status
            ? { state: status.state, lastFetch: status.lastFetch, error: status.error ? { kind: status.error.kind, source: status.error.source } : null }
            : null,
          hiddenCount: s.hidden[f.id]?.length ?? 0,
        };
      }),
    accounts: Object.fromEntries(Object.entries(s.accounts).flatMap(([source, a]) => (a ? [[source, { login: a.login, name: a.name }]] : []))),
    config: {
      githubClientId: s.config.githubClientId,
      bitbucketUser: s.config.bitbucketUser,
      confluenceSite: s.config.confluenceSite,
      confluenceEmail: s.config.confluenceEmail,
      googleClientId: s.config.googleClientId,
    },
    mocked: isMocked,
  };
}

function calendarTopic() {
  const { access, calendars } = useCalendar.getState();
  const c = useLive.getState().calendar;
  return {
    access,
    calendars: calendars.map((cal) => ({ id: cal.id, title: cal.title, color: cal.color, account: cal.account, owned: cal.owned })),
    options: { alertLead: c.alertLead, alertCondition: c.alertCondition, showPreview: c.showPreview, showTimeToNext: c.showTimeToNext, hiddenCalendarIds: c.hiddenCalendarIds },
  };
}

let published = false;

export function publishLive(): void {
  if (published) return;
  published = true;
  let lastFolders = "";
  let lastCalendar = "";
  const publishFolders = () => {
    const json = JSON.stringify(foldersTopic(useLive.getState()));
    if (json === lastFolders) return;
    lastFolders = json;
    publishSettingsTopic("liveFolders.state", JSON.parse(json));
  };
  const publishCalendar = () => {
    const json = JSON.stringify(calendarTopic());
    if (json === lastCalendar) return;
    lastCalendar = json;
    publishSettingsTopic("calendar.state", JSON.parse(json));
  };
  publishFolders();
  publishCalendar();
  useLive.subscribe((s, prev) => {
    if (s.folders !== prev.folders || s.folderOrder !== prev.folderOrder || s.status !== prev.status || s.hidden !== prev.hidden || s.accounts !== prev.accounts || s.config !== prev.config) {
      publishFolders();
    }
    if (s.calendar !== prev.calendar) publishCalendar();
  });
  useCalendar.subscribe((s, prev) => {
    if (s.access !== prev.access || s.calendars !== prev.calendars) publishCalendar();
  });
}

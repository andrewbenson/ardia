import { nativeSafeMode } from "../store/nativeStore";
import { confirm } from "@ardia/shell";
import { liveMeetingBrowser, onLiveCloseGroup } from "@ardia/settings";
import { useBrowser, type BrowserState } from "../store/browser";
import { changedIds } from "../store/changes";
import { activeTabId } from "../store/model";
import { groupOf } from "../store/organize";
import { useCalendar } from "./calendar";
import { eventForCall, isCalendarUrl, meetingOf, relatedLinks, type CalendarEvent } from "./meetings";
import { answerAlertOffer, live, offerAlertsForPinnedTab, setMeetingGroup, useLive } from "./store";
import { PRODUCT } from "../lib/productName";

export const MEETING_FALLBACK_TITLE = "Meeting";

const store = () => useBrowser.getState();

export function groupCall(tabId: string, event?: CalendarEvent | null): string {
  const s = store();
  const tab = s.tabs[tabId];
  const call = tab && meetingOf(tab.url);
  if (!tab || !call || tab.pinned) return "";
  const current = groupOf(s, tabId);
  if (current) return live().meetingGroups[current.id] ? current.id : "";
  const match = event ?? eventForCall(useCalendar.getState().events, tab.url, Date.now());
  const same = Object.values(live().meetingGroups).find((m) => {
    const g = s.groups[m.groupId];
    const callTab = s.tabs[m.callTabId];
    return g && g.windowId === tab.windowId && !m.endedAt && ((!!m.occurrence && m.occurrence === match?.occurrence) || (!!callTab && meetingOf(callTab.url)?.key === call.key));
  });
  if (same) {
    s.addTabsToGroup(same.groupId, [tabId]);
    return same.groupId;
  }
  const title = match?.title || MEETING_FALLBACK_TITLE;
  const groupId = s.createGroup([tabId], { name: title });
  if (!groupId) return "";
  setMeetingGroup({ groupId, callTabId: tabId, occurrence: match?.occurrence ?? null, title, start: match?.start ?? null, end: match?.end ?? null, endedAt: null });
  return groupId;
}

export function joinMeeting(windowId: string, event: CalendarEvent, joinUrl: string, openAll = false) {
  const s = store();
  if (!s.windows[windowId]) return;
  const callTab = s.newTab(windowId, { url: joinUrl });
  const grouped = s.settings.autoGroupMeetingTabs ? groupCall(callTab, event) : "";
  if (openAll) {
    for (const url of relatedLinks(event)) {
      const id = store().newTab(windowId, { url, background: true, openerId: callTab });
      if (grouped && !groupOf(store(), id)) store().addTabsToGroup(grouped, [id]);
    }
  }
  store().activate(callTab);
}

let started = false;

export function startMeetingGroups() {
  if (started || nativeSafeMode()) return;
  started = true;

  useBrowser.subscribe((s, prev) => {
    for (const id of changedIds(s.tabs, prev.tabs)) {
      const tab = s.tabs[id];
      if (!tab) continue;
      const before = prev.tabs[id];
      if (before && before.url === tab.url && before.pinned === tab.pinned) continue;
      if (s.settings.autoGroupMeetingTabs && !tab.pinned && meetingOf(tab.url) && (!before || !meetingOf(before.url))) groupCall(id);
      if (!before && tab.openerId && !groupOf(s, id)) {
        const opener = groupOf(s, tab.openerId);
        if (opener && live().meetingGroups[opener.id] && !live().meetingGroups[opener.id]!.endedAt) store().addTabsToGroup(opener.id, [id]);
      }
      if (tab.pinned && isCalendarUrl(tab.url) && (!before || !before.pinned) && !live().calendar.prompted) void offerAlerts(tab.windowId, tab.url);
    }
  });

  const changed = (s: BrowserState, prev: BrowserState) => {
    if (s.groups !== prev.groups || s.tabs !== prev.tabs || s.windows !== prev.windows || s.live !== prev.live) scheduleSnapshot();
  };
  useBrowser.subscribe(changed);
  useLive.subscribe((s, prev) => { if (s.meetingGroups !== prev.meetingGroups) scheduleSnapshot(); });
  onLiveCloseGroup((groupId) => { if (store().groups[groupId]) store().closeGroup(groupId); });
  scheduleSnapshot();
}

let snapshotTimer: ReturnType<typeof setTimeout> | null = null;

function scheduleSnapshot() {
  if (snapshotTimer) return;
  snapshotTimer = setTimeout(() => {
    snapshotTimer = null;
    const s = store();
    const groups: Record<string, { id: string; windowId: string; tabIds: string[] }> = {};
    const tabs: Record<string, { id: string; url: string; lastActiveAt: number | null; playingAudio: boolean }> = {};
    const activeTabByWindow: Record<string, string | null> = {};
    for (const m of Object.values(live().meetingGroups)) {
      const g = s.groups[m.groupId];
      if (!g) continue;
      groups[g.id] = { id: g.id, windowId: g.windowId, tabIds: g.tabIds };
      for (const id of new Set([...g.tabIds, m.callTabId])) {
        const tab = s.tabs[id];
        if (tab) tabs[id] = { id, url: tab.url, lastActiveAt: tab.lastActiveAt ?? null, playingAudio: !!s.live[id]?.playingAudio };
      }
      activeTabByWindow[g.windowId] = activeTabId(s, g.windowId) ?? null;
    }
    void liveMeetingBrowser({ groups, tabs, activeTabByWindow });
  }, 100);
}

async function offerAlerts(windowId: string, url: string) {
  const result = await offerAlertsForPinnedTab(url);
  if (!result.boolean) return;
  const { confirmed } = await confirm({
    title: "Would you like to see meeting alerts for this calendar?",
    message: `${PRODUCT} can alert you when a new meeting is about to begin. You can hide these alerts or manage how close to a meeting start they show up.`,
    confirmTitle: "Show Alerts",
    cancelTitle: "Don't Show These Alerts",
    windowId,
  });
  await answerAlertOffer(confirmed);
}

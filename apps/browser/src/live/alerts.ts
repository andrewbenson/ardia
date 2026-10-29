import { create } from "zustand";
import { useBrowser } from "../store/browser";
import { joinMeeting } from "./meetingGroups";
import { joinLink, type CalendarEvent } from "./meetings";
import { onLiveSnapshot, dismissAlert } from "./store";

export const useMeetingAlert = create<{ event: CalendarEvent | null }>()(() => ({ event: null }));

let alertJSON = "null";

export function applyMeetingAlertReplica(meetingAlertJSON: string): void {
  if (meetingAlertJSON === alertJSON) return;
  alertJSON = meetingAlertJSON;
  useMeetingAlert.setState({ event: JSON.parse(meetingAlertJSON) as CalendarEvent | null });
}

onLiveSnapshot((replica) => { if (replica.meetingAlertJSON) applyMeetingAlertReplica(replica.meetingAlertJSON); });

export function joinEvent(event: CalendarEvent, openAll = false, windowId = frontWindow()) {
  const link = joinLink(event);
  if (!link || !windowId) return;
  joinMeeting(windowId, event, link.url, openAll);
  dismiss(event);
}

export function dismiss(event: CalendarEvent) {
  if (useMeetingAlert.getState().event?.occurrence === event.occurrence) useMeetingAlert.setState({ event: null });
  void dismissAlert(event.occurrence).catch(() => {
    if (useMeetingAlert.getState().event === null) useMeetingAlert.setState({ event });
  });
}

const frontWindow = () => {
  const s = useBrowser.getState();
  const id = s.ui.focusedWindowId;
  return id && s.windows[id] && !s.windows[id]!.incognito ? id : s.windowOrder.find((w) => !s.windows[w]!.incognito);
};

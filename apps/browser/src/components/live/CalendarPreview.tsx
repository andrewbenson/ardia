import { useState } from "react";
import { NativePage } from "@solara/settings";


import { useTheme } from "../../lib/theme";
import { HoverSurface } from "./LiveItemCard";
import { joinEvent } from "../../live/alerts";
import { connectCalendar, refreshCalendar, useCalendar, useNow } from "../../live/calendar";
import { isCalendarUrl, isMeeting, joinLink, joinTitle, relativeTime, timeRange, type CalendarEvent } from "../../live/meetings";
import { useLive } from "../../live/store";
import { useBrowser } from "../../store/browser";
import { dismissHover } from "../sidebar/hover";
import type { Anchor } from "../sidebar/state";

import { PRODUCT } from "../../lib/productName";

export function useIsCalendarTab(tabId: string | null): boolean {
  const pinnedCalendar = useBrowser((s) => {
    const t = tabId ? s.tabs[tabId] : undefined;
    return !!t?.pinned && isCalendarUrl(t.pinnedUrl ?? t.url);
  });
  const on = useLive((s) => s.calendar.showPreview);
  return pinnedCalendar && on;
}

const JOINABLE_BEFORE_MS = 10 * 60_000;

export type CalendarPreviewBody = "denied" | "signIn" | "loading" | "error" | "none" | "noMore" | "events";

export function useCalendarPreviewState(tabId: string) {
  const now = useNow(15_000);
  const { access, events, loading, error, lastFetch } = useCalendar();
  const connected = access === "fullAccess" || access === "fixture";
  const endOfDay = new Date(now);
  endOfDay.setHours(23, 59, 59, 999);
  const today = events.filter((e) => !e.cancelled && !e.declined && e.start <= endOfDay.getTime() && e.end > new Date(now).setHours(0, 0, 0, 0));
  const upcoming = today.filter((e) => e.end > now);
  const allDay = upcoming.filter((e) => e.allDay);
  const timed = upcoming.filter((e) => !e.allDay);
  const date = new Date(now).toLocaleDateString([], { weekday: "short", month: "short", day: "numeric" });
  const body: CalendarPreviewBody = !connected
    ? access === "denied" || access === "restricted"
      ? "denied"
      : "signIn"
    : !lastFetch && loading
      ? "loading"
      : error && !lastFetch
        ? "error"
        : !today.length
          ? "none"
          : !upcoming.length
            ? "noMore"
            : "events";
  const state = {
    tabId,
    date,
    connected,
    loading,
    product: PRODUCT,
    body,
    allDay: allDay.map((e) => ({ id: e.occurrence, title: e.title || "Untitled event", color: e.color })),
    events: timed.map((e) => {
      const link = joinLink(e);
      const joinable = !!link && isMeeting(e) && now >= e.start - JOINABLE_BEFORE_MS && now < e.end;
      return {
        id: e.occurrence,
        title: e.title || "Untitled event",
        color: e.color,
        time: timeRange(e),
        when: e.start <= now ? "Now" : relativeTime(e.start, now),
        running: e.start <= now,
        past: e.end <= now,
        joinTitle: joinable ? joinTitle(link!.provider) : null,
        people: e.attendees.filter((a) => !a.me).map((a) => a.name || a.email),
      };
    }),
  };
  return { state, now, access, connected, loading, error, lastFetch, today, upcoming, allDay, timed, date };
}

export function calendarPreviewAction(tabId: string, windowId: string, timed: CalendarEvent[], e: { kind: string; id?: unknown }) {
  if (e.kind === "activate") {
    dismissHover();
    useBrowser.getState().activate(tabId);
  } else if (e.kind === "join") {
    const event = timed.find((x) => x.occurrence === e.id);
    if (event) {
      dismissHover();
      joinEvent(event, false, windowId);
    }
  } else if (e.kind === "refresh") void refreshCalendar();
  else if (e.kind === "connect") void connectCalendar();
}

export function CalendarPreview({ tabId, windowId, anchor }: { tabId: string; windowId: string; anchor: Anchor }) {
  const theme = useTheme();
  const { state: preview, timed } = useCalendarPreviewState(tabId);
  const state = JSON.stringify({ card: "calendarPreview", dark: !!theme.dark, nowColor: colorsNow(!!theme.dark), ...preview });
  return (
    <HoverSurface anchor={anchor} width={300}>
      <NativeCard state={state} onEvent={(e) => calendarPreviewAction(tabId, windowId, timed, e)} />
    </HoverSurface>
  );
}

const colorsNow = (dark: boolean) => (dark ? "#E5534B" : "#D1242F");

export function NativeCard({ state, onEvent }: { state: string; onEvent: (e: { kind: string } & Record<string, unknown>) => void }) {
  const [height, setHeight] = useState(1);
  return (
    <NativePage
      kind={(JSON.parse(state) as { card: "calendarPreview" | "meetingAlert" }).card}
      state={state}
      style={{ height }}
      onPageEvent={(e) => {
        const ev = e.nativeEvent;
        if (ev.kind === "height") setHeight(Math.max(1, Math.ceil(Number(ev.height))));
        else onEvent(ev);
      }}
    />
  );
}


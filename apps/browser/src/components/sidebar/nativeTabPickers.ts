import { displayUrl } from "@ardia/core";
import { hostedKinds, publishSettingsTopic, takeSwitcherPress, windowShellActive } from "@ardia/settings";
import { useEffect, useState } from "react";
import { switchToTab } from "../../lib/actions";
import { hex, useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import { tabTitle } from "./actions";
import { setSidebarUi, sidebarUi } from "./state";
import { commitSwitcher, hoverSwitcherRow, leaveSwitcherRow } from "./switcher";
import { useSidebarTokens } from "./tokens";

const SEARCH = "sidebar.tabSearch";
const SWITCHER = "sidebar.switcher";
const published: Record<string, Record<string, object>> = { [SEARCH]: {}, [SWITCHER]: {} };
const queued = new Set<string>();
let searchOpens = 0;

function publish(topic: string, windowId: string, value: object | null) {
  if (value) published[topic]![windowId] = value;
  else if (published[topic]![windowId]) delete published[topic]![windowId];
  else return;
  if (queued.has(topic)) return;
  queued.add(topic);
  queueMicrotask(() => {
    queued.delete(topic);
    publishSettingsTopic(topic, { windows: { ...published[topic] } });
  });
}

export function useNativeTabPickers(windowId: string): boolean {
  const [active] = useState(() => hostedKinds().includes("tabPickers") && windowShellActive(windowId));
  return active;
}

export function useTabPickerTheme() {
  const theme = useTheme();
  const tokens = useSidebarTokens();
  return {
    dark: !!theme.dark,
    theme: {
      panel: hex(theme.panel),
      panelBorder: hex(theme.panelBorder),
      panelShadowOpacity: String(theme.panelShadowOpacity),
      textPrimary: theme.textPrimary,
      textSecondary: theme.textSecondary,
      textTertiary: theme.textTertiary,
      placeholder: theme.placeholder,
      selection: theme.selection,
      divider: theme.divider,
      rowSelected: theme.rowSelected,
      icon: theme.icon,
      switcherFocus: tokens.switcherFocus,
      switcherOutline: tokens.switcherOutline,
    },
  };
}

export type NativeSearchRow = { kind: "tab" | "closed"; id: string; title: string; url: string; favicon: string | null; icon: string | null; profileId: string; detail: string | null };

export function hostOf(url: string): string {
  try {
    return new URL(url).hostname.replace(/^www\./, "");
  } catch {
    return "";
  }
}

export function useNativeTabSearch(windowId: string, rows: { open: NativeSearchRow[]; closed: NativeSearchRow[] } | null) {
  const look = useTabPickerTheme();
  const [openId] = useState(() => ++searchOpens);
  const key = rows ? JSON.stringify([rows, look]) : null;
  useEffect(() => {
    if (!key || !rows) return publish(SEARCH, windowId, null);
    const wire = (r: NativeSearchRow) => ({ ...r, display: r.url ? displayUrl(r.url) : "", host: hostOf(r.url) });
    publish(SEARCH, windowId, { open: rows.open.map(wire), closed: rows.closed.map(wire), ...look, openId });
  }, [key, windowId, openId]);
  useEffect(() => () => publish(SEARCH, windowId, null), [windowId]);
}

export function useNativeTabSwitcher(windowId: string, switcher: { ids: string[]; index: number } | null) {
  const look = useTabPickerTheme();
  const rows = useBrowser((s) => {
    if (!switcher) return null;
    const entries = switcher.ids.flatMap((id) => {
      const t = s.tabs[id];
      return t ? [[id, { id, title: tabTitle(t), url: t.url, display: t.url ? displayUrl(t.url) : "", favicon: t.favicon, icon: t.customIcon, profileId: t.profileId }]] : [];
    });
    return JSON.stringify(Object.fromEntries(entries));
  });
  const key = switcher && rows ? JSON.stringify([switcher.ids, switcher.index, rows, look]) : null;
  useEffect(() => {
    if (!key || !switcher || !rows) return publish(SWITCHER, windowId, null);
    publish(SWITCHER, windowId, { ids: switcher.ids, index: switcher.index, rows: JSON.parse(rows), ...look });
  }, [key, windowId]);
  useEffect(() => () => publish(SWITCHER, windowId, null), [windowId]);
}

addNativeSettingsHandlers({
  [SEARCH]: (windowId: string, event: string, kind?: string, id?: string) => {
    if (event === "close") {
      if (sidebarUi().searchTabs === windowId) setSidebarUi({ searchTabs: null });
      return;
    }
    if (event !== "choose" || !id) return;
    if (sidebarUi().searchTabs === windowId) setSidebarUi({ searchTabs: null });
    if (kind === "tab") switchToTab(id);
    else useBrowser.getState().restoreClosed(id, windowId);
  },
  [SWITCHER]: (windowId: string, event: string, index: number) => {
    if (sidebarUi().switcher?.windowId !== windowId) return;
    if (event === "hover") hoverSwitcherRow(index);
    else if (event === "leave") leaveSwitcherRow(index);
    else if (event === "commit") {
      takeSwitcherPress(windowId);
      commitSwitcher(index);
    }
  },
});

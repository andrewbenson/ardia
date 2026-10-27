import { displayUrl, type Suggestion } from "@ardia/core";
import { newTabSources, type NewTabMenuChoice } from "@ardia/settings";
import { pickFiles, readDocument, showMenu, startDictation } from "@ardia/shell";
import { useEffect, useRef, useState, type RefObject } from "react";
import { findNodeHandle, Image } from "react-native";
import { claimFocusTag } from "../../lib/focusClaims";
import { faviconUri } from "../../lib/favicons";
import { perfProbeEnabled } from "../../lib/perfProbe";
import { bundledSiteIcon } from "../../lib/siteIcons";
import type { Theme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { activeTabId, bookmarkProfileId, viewTabIds } from "../../store/model";
import type { HistoryEntry } from "../../store/types";
import { journeyBarCommitted, journeyBarFocused, journeyKeystroke, journeyNavigate, journeySuggestions } from "../../telemetry/journeys";
import { sampleOmniboxLatency, trackSuggestionChosen } from "../../telemetry/track";
import { historyPatch } from "../ntp/historyPatch";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import { currentBarActions } from "./actions";
import { useOmniboxDriver } from "./devDriver";
import { useBarExtensions } from "./extensions";
import { openFromBar, switchFromBar, type Disposition } from "./open";
import { clipboardPasteAction, pasteMenuItem, pasteTarget } from "./paste";
import { runBarAction, runBarExtension } from "./runBar";
import { profileBookmarks } from "./useSuggestions";

export { openFromBar };

const FAVICON_WAIT_MS = 3000;
const benchOffline = readDocument("bench-offline") !== null;

addNativeSettingsHandlers({
  "newTab.favicon": async (url: string, profileId: string | null, dark: boolean) => {
    const cached = await faviconUri(url, profileId ?? undefined, 0);
    if (cached) return cached;
    const icon = bundledSiteIcon(url, dark);
    if (icon !== undefined) return Image.resolveAssetSource(icon)?.uri ?? null;
    return faviconUri(url, profileId ?? undefined, FAVICON_WAIT_MS);
  },
});

const PUBLISH_DELAY_MS = 50;

export function themeTokens(theme: Theme): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(theme)) if (typeof value === "string") out[key] = value;
  return out;
}

function debounced(run: () => void) {
  let timer: ReturnType<typeof setTimeout> | undefined;
  return {
    schedule: () => {
      clearTimeout(timer);
      timer = setTimeout(run, PUBLISH_DELAY_MS);
    },
    cancel: () => clearTimeout(timer),
  };
}

type HistoryRowJSON = { url: string; title: string; favicon: string | null; visits: number; lastVisit: number };

const historyRow = (h: HistoryEntry): HistoryRowJSON => ({ url: h.url, title: h.title, favicon: h.favicon ?? null, visits: h.visits, lastVisit: h.lastVisit });
const publishedHistory = new Map<string, { list: HistoryEntry[]; rev: number }>();
let historyRev = 0;
let historyQueue = Promise.resolve();

function publishProfileHistory(profileId: string) {
  historyQueue = historyQueue.then(async () => {
    const list = useBrowser.getState().history[profileId] ?? [];
    const last = publishedHistory.get(profileId);
    if (last?.list === list) return;
    const rev = ++historyRev;
    const patch = last ? historyPatch(last.list, list) : null;
    const patched =
      !!last &&
      !!patch &&
      (await newTabSources.patchHistory(profileId, last.rev, rev, { removed: patch.removed, inserts: patch.inserts.map(([i, h]) => [i, historyRow(h)]) }));
    if (!patched) await newTabSources.setHistory(profileId, rev, list.map(historyRow));
    publishedHistory.set(profileId, { list, rev });
  });
}

export function usePublishSources(windowId: string, profileId: string) {
  const extensions = useBarExtensions(windowId);
  useEffect(() => {
    void newTabSources.setExtensions(windowId, extensions);
  }, [windowId, extensions]);

  useEffect(() => {
    let tabs: unknown = null;
    let history: unknown = null;
    let bookmarks: unknown = null;
    let bookmarkProfile = "";
    let actions = "";
    const publishTabs = debounced(() => {
      const s = useBrowser.getState();
      const rows = Object.values(s.tabs)
        .filter((t) => t.profileId === profileId)
        .map((t) => ({ id: t.id, url: t.url, title: t.title, favicon: t.favicon ?? null }));
      void newTabSources.setTabs(profileId, rows);
    });
    const publishHistory = debounced(() => publishProfileHistory(profileId));
    const publishBookmarks = debounced(() => {
      const s = useBrowser.getState();
      void newTabSources.setBookmarks(profileId, profileBookmarks(s.bookmarks, bookmarkProfileId(s, s.windows[windowId])));
    });
    const publishActions = debounced(() => {
      const next = JSON.stringify(currentBarActions(windowId));
      if (next === actions) return;
      actions = next;
      void newTabSources.setActions(windowId, JSON.parse(next) as unknown[]);
    });
    const check = () => {
      const s = useBrowser.getState();
      if (s.tabs !== tabs) {
        tabs = s.tabs;
        publishTabs.schedule();
      }
      const h = s.history[profileId];
      if (h !== history) {
        history = h;
        publishHistory.schedule();
      }
      const bp = bookmarkProfileId(s, s.windows[windowId]);
      if (s.bookmarks !== bookmarks || bp !== bookmarkProfile) {
        bookmarks = s.bookmarks;
        bookmarkProfile = bp;
        publishBookmarks.schedule();
      }
      publishActions.schedule();
    };
    check();
    const off = useBrowser.subscribe(check);
    return () => {
      off();
      publishTabs.cancel();
      publishHistory.cancel();
      publishBookmarks.cancel();
      publishActions.cancel();
    };
  }, [windowId, profileId]);
}

export function useThemeTokens(theme: Theme): Record<string, string> {
  const [tokens] = useState(() => new Map<Theme, Record<string, string>>());
  let found = tokens.get(theme);
  if (!found) tokens.set(theme, (found = themeTokens(theme)));
  return found;
}

export type NativeBarHandle = {
  focus(): Promise<void>;
  applyMenu(choice: NewTabMenuChoice): Promise<void>;
  type(text: string): Promise<void>;
  clear(): Promise<void>;
  key(key: string, mods?: { metaKey?: boolean; altKey?: boolean; shiftKey?: boolean; ctrlKey?: boolean }): Promise<void>;
  select(start: number, end: number): Promise<void>;
  submit(): Promise<void>;
  driverState(): Promise<string>;
  measure(): Promise<{ x: number; y: number; width: number; height: number }>;
};

type Event<T> = { nativeEvent: T };

export function useNativeBar({
  ref,
  windowId,
  tabId,
  profileId,
  driverId,
  focusTag,
  go,
  switchTo = (target, url, disposition) => switchFromBar(target, url, tabId, disposition),
}: {
  ref: RefObject<NativeBarHandle | null>;
  windowId: string;
  tabId: string;
  profileId: string;
  driverId: string;
  focusTag: string;
  go(url: string, disposition?: Disposition): void;
  switchTo?(tabId: string, url: string, disposition: Disposition): void;
}) {
  usePublishSources(windowId, profileId);
  const claim = () => claimFocusTag(windowId, focusTag, () => findNodeHandle(ref.current as never));

  const driverState = useRef<Record<string, unknown>>({ items: [] });
  const refreshState = () => void ref.current?.driverState().then((s) => (driverState.current = JSON.parse(s) as Record<string, unknown>), () => {});
  useOmniboxDriver(driverId, {
    type: (text) => void ref.current?.type(text).then(refreshState),
    clear: () => void ref.current?.clear().then(refreshState),
    key: (key, mods) => void ref.current?.key(key, mods).then(refreshState),
    select: (start, end) => void ref.current?.select(start, end),
    submit: () => void ref.current?.submit(),
    measure: () => ref.current?.measure() ?? Promise.resolve({ x: 0, y: 0, width: 0, height: 0 }),
    state: () => driverState.current,
  });

  const openChip = async () => {
    const s = useBrowser.getState();
    const active = activeTabId(s, windowId);
    const others = viewTabIds(s, windowId)
      .map((id) => s.tabs[id]!)
      .filter((t) => t.id !== active && t.url)
      .slice(0, 12);
    const choice = await showMenu([
      ...others.map((t) => ({ id: `tab:${t.id}`, title: t.title || displayUrl(t.url) })),
      ...(others.length ? [{ separator: true as const }] : []),
      { id: "files", title: "Open File…", symbol: "doc" },
    ]);
    if (choice?.startsWith("tab:")) switchFromBar(choice.slice(4), "", tabId, "current");
    if (choice === "files") {
      const [file] = await pickFiles();
      if (file) go(file);
    }
  };

  const contextMenu = async (hasSelection: boolean, hasValue: boolean) => {
    const paste = await clipboardPasteAction();
    const choice = await showMenu([
      ...pasteMenuItem(paste),
      ...(paste ? [{ separator: true as const }] : []),
      { id: "cut", title: "Cut", enabled: hasSelection },
      { id: "copy", title: "Copy", enabled: hasSelection },
      { id: "paste", title: "Paste", enabled: !!paste },
      { separator: true },
      { id: "selectAll", title: "Select All", enabled: hasValue },
    ]);
    if (choice === "pasteAndGo" && paste) return go(pasteTarget(paste));
    if (choice === "cut" || choice === "copy" || choice === "paste" || choice === "selectAll") void ref.current?.applyMenu(choice as NewTabMenuChoice);
    else void ref.current?.focus();
  };

  const props = {
    driven: __DEV__ || perfProbeEnabled,
    offline: benchOffline,
    onDriverState: (e: Event<{ json: string }>) => (driverState.current = JSON.parse(e.nativeEvent.json) as Record<string, unknown>),
    onOpen: (e: Event<{ url: string; disposition: Disposition }>) => go(e.nativeEvent.url, e.nativeEvent.disposition),
    onSwitch: (e: Event<{ tabId: string; url: string; disposition: Disposition }>) => switchTo(e.nativeEvent.tabId, e.nativeEvent.url, e.nativeEvent.disposition),
    onAction: (e: Event<{ id: string }>) => runBarAction(e.nativeEvent.id, windowId),
    onExtension: (e: Event<{ suggestion: unknown }>) => runBarExtension(e.nativeEvent.suggestion as Extract<Suggestion, { kind: "extension" }>, windowId),
    onRemoveHistory: (e: Event<{ url: string }>) => useBrowser.getState().removeHistory(profileId, [e.nativeEvent.url]),
    onChosen: (e: Event<{ suggestion: unknown }>) => trackSuggestionChosen((e.nativeEvent.suggestion ?? undefined) as Suggestion | undefined),
    onOpenChip: () => void openChip(),
    onDictate: () => startDictation(),
    onContextMenu: (e: Event<{ hasSelection: boolean; hasValue: boolean }>) => void contextMenu(e.nativeEvent.hasSelection, e.nativeEvent.hasValue),
    onJourney: (e: Event<{ mark: string }>) => {
      const mark = e.nativeEvent.mark;
      if (mark === "committed") journeyBarCommitted(tabId);
      else if (mark === "focused") {
        claim();
        journeyBarFocused(tabId);
      } else if (mark === "keystroke") journeyKeystroke(tabId);
      else if (mark === "suggestions") journeySuggestions(tabId);
      else if (mark === "navigate") journeyNavigate(tabId);
    },
    onLatency: (e: Event<{ ms: number }>) => sampleOmniboxLatency(e.nativeEvent.ms),
  };
  return { props, claim };
}

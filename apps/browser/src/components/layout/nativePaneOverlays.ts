import { publishSettingsTopic } from "@ardia/settings";
import { useCallback, useEffect, useRef, useState } from "react";
import type { View } from "react-native";
import { webviews } from "../../lib/webviews";
import type { Theme } from "../../lib/theme";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import { patchPage, setPopover } from "./pageState";

const VERSION = 1;
export type PaneHistoryEvent = { kind: "open"; index: number; metaKey: boolean; shiftKey: boolean; altKey: boolean; middle: boolean } | { kind: "fullHistory" | "dismiss" };
export type PaneClick = { metaKey: boolean; shiftKey: boolean; altKey: boolean };
const handlers = new Map<string, { current: ((event: never) => void) | null }>();
const windows: Record<string, Record<string, Record<string, object>>> = {};
let queued = false;

function publish() {
  if (queued) return;
  queued = true;
  queueMicrotask(() => {
    queued = false;
    publishSettingsTopic("pane.overlays", { v: VERSION, windows });
  });
}

function setOverlay(windowId: string, tabId: string, kind: string, state: object | null) {
  const tabs = (windows[windowId] ??= {});
  const entry = (tabs[tabId] ??= {});
  if (state) entry[kind] = state;
  else delete entry[kind];
  if (!Object.keys(entry).length) delete tabs[tabId];
  if (!Object.keys(tabs).length) delete windows[windowId];
  publish();
}

addNativeSettingsHandlers({
  "pane.sadTab": (_windowId: string, tabId: string, action: string) => {
    if (action === "reload") {
      patchPage(tabId, { crashed: null });
      return void webviews.get(tabId)?.reload();
    }
    if (action === "exit" || action === "wait") {
      patchPage(tabId, { unresponsive: false });
      return void webviews.get(tabId)?.resolveUnresponsive(action === "exit");
    }
  },
  "pane.history": (windowId: string, tabId: string, event: PaneHistoryEvent) => handlers.get(`history:${windowId}:${tabId}`)?.current?.(event as never),
  "pane.selection": (windowId: string, tabId: string, click: PaneClick) => handlers.get(`selection:${windowId}:${tabId}`)?.current?.(click as never),
  "pane.zoom": (_windowId: string, tabId: string, kind: string, step: number) => {
    if (kind === "dismiss") return setPopover(tabId, null);
    if (kind === "step") void webviews.get(tabId)?.zoomStep(Math.sign(Number(step)) as -1 | 0 | 1);
  },
});

export function useNativePaneHandler<Event>(kind: "history" | "selection", active: boolean, windowId: string, tabId: string, handler: (event: Event) => void) {
  const ref = useRef(handler);
  ref.current = handler;
  useEffect(() => {
    if (!active) return;
    const key = `${kind}:${windowId}:${tabId}`;
    const entry = ref as { current: ((event: never) => void) | null };
    handlers.set(key, entry);
    return () => void (handlers.get(key) === entry && handlers.delete(key));
  }, [kind, active, windowId, tabId]);
}

export function usePageFrame() {
  const [frame, setFrame] = useState<PageFrame | null>(null);
  const ref = useRef<View>(null);
  const onLayout = useCallback(
    () => ref.current?.measureInWindow((x, y, width, height) => setFrame((f) => (f && f.join() === [x, y, width, height].join() ? f : [x, y, width, height]))),
    [],
  );
  return { frame, ref, onLayout };
}

export function useNativePaneOverlay(active: boolean, windowId: string, tabId: string, kind: string, state: object | null) {
  const key = state && JSON.stringify(state);
  useEffect(() => {
    if (active) setOverlay(windowId, tabId, kind, state);
  }, [active, windowId, tabId, kind, key]);
  useEffect(() => () => void (active && setOverlay(windowId, tabId, kind, null)), [active, windowId, tabId, kind]);
}

export type PageFrame = [number, number, number, number];

export function useNativeSadTab(active: boolean, windowId: string, tabId: string, mode: "crashed" | "unresponsive" | null, frame: PageFrame | null, theme: Theme) {
  const { dark, textPrimary, textSecondary, panel, panelBorder, panelShadowOpacity, goButton, goButtonText } = theme;
  useNativePaneOverlay(active, windowId, tabId, "sadTab", mode && frame ? { mode, frame, dark, textPrimary, textSecondary, panel, panelBorder, panelShadowOpacity, goButton, goButtonText } : null);
}

import { publishSettingsTopic } from "@ardia/settings";
import { useEffect } from "react";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import type { Theme } from "../../lib/theme";
import { hideToast, useToasts } from "./splitActions";
import type { Rect } from "./geometry";

const VERSION = 1;
const themes: Record<string, object> = {};
let themeQueued = false;
let toastsStarted = false;
const actions = new Map<string, () => void>();

function publishThemes() {
  if (themeQueued) return;
  themeQueued = true;
  queueMicrotask(() => {
    themeQueued = false;
    publishSettingsTopic("split.theme", { v: VERSION, windows: themes });
  });
}

export function useNativeSplitChrome(windowId: string, shell: boolean, theme: Theme, fullscreenTab: string | null, peek: boolean) {
  const { dark, accent, textPrimary, textSecondary, textTertiary, icon, toolbarHover, toolbarPressed, urlPill, rowHover, rowSelected, placeholder, selection, ntpBarBorder } = theme;
  useEffect(() => {
    if (!shell) return;
    startToasts();
    const tokens = { accent, textPrimary, textSecondary, textTertiary, icon, toolbarHover, toolbarPressed, urlPill, rowHover, rowSelected, placeholder, selection, ntpBarBorder };
    themes[windowId] = { theme: { dark, ...tokens }, fullscreenTab, covered: peek };
    publishThemes();
  }, [shell, windowId, dark, accent, textPrimary, textSecondary, textTertiary, icon, toolbarHover, toolbarPressed, urlPill, rowHover, rowSelected, placeholder, selection, ntpBarBorder, fullscreenTab, peek]);
  useEffect(
    () => () => {
      if (!shell) return;
      delete themes[windowId];
      publishThemes();
    },
    [shell, windowId],
  );
}

function startToasts() {
  if (toastsStarted) return;
  toastsStarted = true;
  const publish = (toasts: ReturnType<typeof useToasts.getState>["toasts"]) => {
    const windows: Record<string, object> = {};
    actions.clear();
    for (const [windowId, toast] of Object.entries(toasts)) {
      if (!toast) continue;
      if (toast.action) actions.set(`${windowId}:${toast.id}`, toast.action.run);
      windows[windowId] = { id: toast.id, title: toast.title, message: toast.message ?? null, icon: toast.icon ?? null, action: toast.action?.title ?? null, sticky: !!toast.sticky };
    }
    publishSettingsTopic("split.toast", { v: VERSION, windows });
  };
  useToasts.subscribe((s, prev) => {
    if (s.toasts !== prev.toasts) publish(s.toasts);
  });
  publish(useToasts.getState().toasts);
}

addNativeSettingsHandlers({
  "split.toast": (windowId: string, id: number, event: string) => {
    if (event === "action") actions.get(`${windowId}:${id}`)?.();
    hideToast(windowId, id);
  },
  "split.devResult": (run: number, json: string) => {
    const g = globalThis as { __splitDev?: Record<number, object> };
    (g.__splitDev ??= {})[run] = JSON.parse(json);
  },
});

export type NativeDropFrame = { shown: boolean; grown: boolean; px: number; target: { tabId: string; side: string } | null; panes: [string, Rect][] };

let lastDrop = "";

export function publishNativeDrop(windowId: string, frame: NativeDropFrame) {
  const message = {
    v: VERSION,
    windowId,
    shown: frame.shown,
    grown: frame.grown,
    px: frame.px,
    target: frame.target ? [frame.target.tabId, frame.target.side] : null,
    panes: frame.panes.map(([tabId, r]) => [tabId, r.x, r.y, r.width, r.height]),
  };
  const key = JSON.stringify(message);
  if (key === lastDrop) return;
  lastDrop = key;
  publishSettingsTopic("split.drag", message);
}

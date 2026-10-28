import { publishSettingsTopic } from "@ardia/settings";
import { useEffect } from "react";
import { webviews } from "../../lib/webviews";
import type { Theme } from "../../lib/theme";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import { patchPage } from "./pageState";

const VERSION = 1;
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
});

export type PageFrame = [number, number, number, number];

export function useNativeSadTab(active: boolean, windowId: string, tabId: string, mode: "crashed" | "unresponsive" | null, frame: PageFrame | null, theme: Theme) {
  const { dark, textPrimary, textSecondary, panel, panelBorder, panelShadowOpacity, goButton, goButtonText } = theme;
  const shown = mode && frame;
  useEffect(() => {
    if (!active) return;
    setOverlay(windowId, tabId, "sadTab", shown ? { mode, frame, dark, textPrimary, textSecondary, panel, panelBorder, panelShadowOpacity, goButton, goButtonText } : null);
  }, [active, windowId, tabId, mode, frame?.join(), dark, textPrimary, textSecondary, panel, panelBorder, panelShadowOpacity, goButton, goButtonText]);
  useEffect(() => () => void (active && setOverlay(windowId, tabId, "sadTab", null)), [active, windowId, tabId]);
}

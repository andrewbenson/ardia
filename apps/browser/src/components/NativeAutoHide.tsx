import { breadcrumb } from "@solara/core";
import { requireOptionalNativeModule, type EventSubscription } from "expo-modules-core";
import { useEffect } from "react";
import { layout, useTheme } from "../lib/theme";
import { useBrowser } from "../store/browser";
import { revealToolbar, setToolbarPeek, type ToolbarMode } from "./layout/toolbarAutoHide";
import { toolbarPalette } from "./layout/toolbarColors";
import { stripesUri } from "./NativeToolbar";
import { useTabDeveloperMode, useToolbarSiteColor } from "./site/developerMode";

type AutoHideNative = {
  set(windowId: string, tabId: string, json: string): Promise<void>;
  remove(windowId: string, tabId: string): Promise<void>;
  addListener(event: "onAutoHideEvent", listener: (e: { windowId: string; tabId: string; kind: "reveal" | "peek"; on: boolean }) => void): EventSubscription;
};

const native = requireOptionalNativeModule<AutoHideNative>("SolaraAutoHide");

export function NativeAutoHide({ windowId, tabId, mode, pane, extra }: { windowId: string; tabId: string; mode: ToolbarMode; pane: { x: number; y: number; width: number; height: number }; extra: number }) {
  const theme = useTheme();
  const url = useBrowser((s) => s.tabs[tabId]?.url ?? "");
  const palette = toolbarPalette(theme, useToolbarSiteColor(tabId));
  const developer = useTabDeveloperMode(tabId);
  const host = url.startsWith("file:") ? "File" : breadcrumb(url).host;
  const json = JSON.stringify({
    mode,
    shownTop: layout.toolbarHeight + extra,
    pane,
    card: theme.card,
    band: palette.background,
    divider: palette.divider,
    secondary: palette.secondary,
    host,
    hasPage: !!url,
    stripes: developer ? stripesUri(palette) : null,
  });
  useEffect(() => {
    void native?.set(windowId, tabId, json);
  }, [windowId, tabId, json]);
  useEffect(() => () => void native?.remove(windowId, tabId), [windowId, tabId]);
  useEffect(() => {
    const sub = native?.addListener("onAutoHideEvent", (e) => {
      if (e.windowId !== windowId || e.tabId !== tabId) return;
      if (e.kind === "reveal") revealToolbar(tabId);
      else setToolbarPeek(tabId, e.on);
    });
    return () => sub?.remove();
  }, [windowId, tabId]);
  return null;
}

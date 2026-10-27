import { WindowBackdrop } from "@ardia/shaders";
import { ContextMenuArea, setTrafficLightsCenter, WindowDragRegion } from "@ardia/shell";
import { useEffect, useRef, useState } from "react";
import { StyleSheet, View } from "react-native";
import { profileAccent, useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { useActiveTab, useTabLive, useWindowId, useWindowProfile, useWindowUi } from "../../store/hooks";
import type { Tab } from "../../store/types";
import { CommandPanel } from "../CommandPanel";
import { ContentCard } from "../ContentCard";
import { DownloadsPopover } from "../Downloads";
import { ExtensionOverlays } from "../extensions/ExtensionOverlays";
import { ToolbarPopupAnchor } from "../extensions/ToolbarExtensions";
import { setUrlAnchor } from "../layout/windowLayout";
import { showUrlBarMenu } from "../omnibox/paste";
import { useHover } from "../primitives";
import { copyPageUrl } from "../site/selection";
import { ProfileBadge, profileSymbol } from "../profiles/icons";
import { addMediaActions, mediaTheme, nativeMedia, NativeMediaView } from "../media/nativeMedia";
import { breadcrumb } from "@ardia/core";
import { usePageProgress } from "../../store/pageProgress";
import { usePage } from "../layout/pageState";
import { insecureLevel } from "../Toolbar";
import { openInMainWindow, openLittleArdiaProfileMenu } from "./actions";
import { PageLabel, SMALL_BAR_BUTTON, SMALL_BAR_HEIGHT, SMALL_INSET, SMALL_LIGHTS_CENTER, SmallBar, SmallBarBadgeButton } from "./SmallChrome";
import { PRODUCT } from "../../lib/productName";

const FIELD_LEFT = 84;

export function LittleArdiaWindow() {
  const theme = useTheme();
  const [width, setWidth] = useState(0);
  return (
    <View style={{ flex: 1 }} onLayout={(e) => setWidth(e.nativeEvent.layout.width)}>
      <WindowBackdrop vibrancy {...theme.backdrop} colors={theme.windowTint} grainOpacity={theme.grain} style={StyleSheet.absoluteFill} />
      <View style={{ flex: 1, flexDirection: "row", paddingTop: SMALL_BAR_HEIGHT, paddingLeft: SMALL_INSET, paddingRight: SMALL_INSET, paddingBottom: SMALL_INSET }}>
        <ContentCard />
      </View>
      <View style={{ position: "absolute", left: 0, right: 0, top: 0 }}>
        <LittleArdiaBar />
      </View>
      <CommandPanel windowWidth={width} />
      <DownloadsPopover />
      <ExtensionOverlays />
    </View>
  );
}

const copiedUntil: Record<string, ReturnType<typeof setTimeout>> = {};

addMediaActions({
  smallBar: (windowId, tabId, extra) => {
    const s = useBrowser.getState();
    const tab = tabId ? s.tabs[tabId] : undefined;
    switch (extra.action) {
      case "copy":
        if (!tab?.url) return;
        void copyPageUrl(tab.id);
        clearTimeout(copiedUntil[windowId]);
        useCopied.set(windowId, true);
        copiedUntil[windowId] = setTimeout(() => useCopied.set(windowId, false), 1400);
        return;
      case "open":
        return openInMainWindow(windowId);
      case "field":
        return tab ? s.openPanel(windowId, tab.url) : undefined;
      case "fieldMenu":
        return tab?.url ? void showUrlBarMenu(tab) : undefined;
      case "profile":
        return void openLittleArdiaProfileMenu(windowId);
    }
  },
});

const useCopied = (() => {
  const listeners = new Set<() => void>();
  const copied: Record<string, boolean> = {};
  return {
    set(windowId: string, on: boolean) {
      copied[windowId] = on;
      for (const l of listeners) l();
    },
    use(windowId: string) {
      const [, bump] = useState(0);
      useEffect(() => {
        const l = () => bump((n) => n + 1);
        listeners.add(l);
        return () => void listeners.delete(l);
      }, []);
      return !!copied[windowId];
    },
  };
})();

function LittleArdiaBar() {
  return nativeMedia("littleSolara.bar") ? <NativeLittleArdiaBar /> : <RNLittleArdiaBar />;
}

function NativeLittleArdiaBar() {
  const theme = useTheme();
  const windowId = useWindowId();
  const tab = useActiveTab();
  const panelOpen = useWindowUi().panel.open;
  const profile = useWindowProfile();
  const severalProfiles = useBrowser((s) => s.profileOrder.length > 1);
  const copied = useCopied.use(windowId);
  const live = useTabLive(tab?.id ?? "");
  const progress = usePageProgress(tab?.id ?? "");
  const insecure = usePage(tab?.id ?? "", (p) => !!insecureLevel(p));
  const holder = useRef<View>(null);
  useEffect(() => {
    void setTrafficLightsCenter(windowId, SMALL_LIGHTS_CENTER);
  }, [windowId]);
  const buttons = [
    { id: "copy", icon: copied ? "checkmark" : "link", size: 14, disabled: !tab?.url, tooltip: "Copy Link (⇧⌘C)" },
    { id: "open", icon: "arrow.up.left.and.arrow.down.right", size: 13, tooltip: `Open in ${PRODUCT} (⌘O)` },
  ];
  const count = buttons.length + (severalProfiles ? 1 : 0);
  const anchor = () =>
    holder.current?.measureInWindow((x, y, width) => {
      const right = SMALL_INSET + count * SMALL_BAR_BUTTON + Math.max(0, count - 1) * 2 + 6;
      const fieldWidth = width - FIELD_LEFT - right;
      if (fieldWidth > 0) setUrlAnchor(windowId, { left: x + FIELD_LEFT, top: y + (SMALL_BAR_HEIGHT - 28) / 2, width: fieldWidth, sidebar: { height: 28 } });
    });
  useEffect(anchor, [count]);
  const url = tab?.url ?? "";
  const host = !url ? "" : url.startsWith("file:") ? "File" : breadcrumb(url).host;
  const state = {
    tabId: tab?.id ?? null,
    icon: insecure ? "insecure" : url ? "favicon" : "search",
    url,
    favicon: tab?.favicon ?? null,
    profileId: tab?.profileId ?? profile.id,
    host,
    title: tab ? tab.customTitle || tab.title : "",
    loading: !!live.isLoading,
    progress,
    hidden: panelOpen || !tab,
    buttons,
    profile: severalProfiles
      ? { swatch: profileAccent(profile), symbol: profileSymbol(profile.icon), text: profile.icon ?? (profile.name.trim()[0] ?? "?").toUpperCase(), emoji: !!profile.icon, tooltip: `Profile: ${profile.name}` }
      : null,
    theme: mediaTheme(theme, { iconDisabled: theme.iconDisabled }),
  };
  return (
    <View ref={holder} onLayout={anchor} style={{ height: SMALL_BAR_HEIGHT }}>
      <WindowDragRegion style={StyleSheet.absoluteFill} />
      <NativeMediaView kind="littleSolara.bar" windowId={windowId} state={state} />
      {tab ? <ToolbarPopupAnchor windowId={windowId} tabId={tab.id} top={(SMALL_BAR_HEIGHT - SMALL_BAR_BUTTON) / 2} right={SMALL_INSET} /> : null}
    </View>
  );
}

function RNLittleArdiaBar() {
  const windowId = useWindowId();
  const tab = useActiveTab();
  const panelOpen = useWindowUi().panel.open;
  const severalProfiles = useBrowser((s) => s.profileOrder.length > 1);
  const [copied, setCopied] = useState(false);
  const copiedTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  useEffect(() => {
    void setTrafficLightsCenter(windowId, SMALL_LIGHTS_CENTER);
  }, [windowId]);
  useEffect(() => () => clearTimeout(copiedTimer.current), []);

  const copy = () => {
    if (!tab?.url) return;
    void copyPageUrl(tab.id);
    setCopied(true);
    clearTimeout(copiedTimer.current);
    copiedTimer.current = setTimeout(() => setCopied(false), 1400);
  };

  return (
    <SmallBar
      fieldLeft={FIELD_LEFT}
      field={tab ? <PageField tab={tab} windowId={windowId} hidden={panelOpen} /> : null}
      buttons={[
        { icon: copied ? "checkmark" : "link", size: 14, disabled: !tab?.url, tooltip: "Copy Link (⇧⌘C)", onPress: copy },
        { icon: "arrow.up.left.and.arrow.down.right", size: 13, tooltip: `Open in ${PRODUCT} (⌘O)`, onPress: () => openInMainWindow(windowId) },
      ]}
      trailing={severalProfiles ? <ProfileButton windowId={windowId} /> : undefined}
    >
      <WindowDragRegion style={StyleSheet.absoluteFill} />
      {tab ? <ToolbarPopupAnchor windowId={windowId} tabId={tab.id} top={(SMALL_BAR_HEIGHT - SMALL_BAR_BUTTON) / 2} right={SMALL_INSET} /> : null}
    </SmallBar>
  );
}

function ProfileButton({ windowId }: { windowId: string }) {
  const profile = useWindowProfile();
  return (
    <SmallBarBadgeButton tooltip={`Profile: ${profile.name}`} onPress={() => void openLittleArdiaProfileMenu(windowId)}>
      <ProfileBadge profile={profile} size={16} />
    </SmallBarBadgeButton>
  );
}

function PageField({ tab, windowId, hidden }: { tab: Tab; windowId: string; hidden: boolean }) {
  const { hovered, hoverProps } = useHover();
  const field = useRef<View>(null);
  const anchor = () =>
    field.current?.measureInWindow((x, y, width, height) => {
      if (width) setUrlAnchor(windowId, { left: x, top: y, width, sidebar: { height } });
    });

  return (
    <View ref={field} onLayout={anchor} {...hoverProps} style={{ flex: 1, opacity: hidden ? 0 : 1 }}>
      <ContextMenuArea style={{ flex: 1 }} onContextMenu={() => tab.url && void showUrlBarMenu(tab)}>
        <WindowDragRegion
          clickable
          accessibilityRole="button"
          onRegionClick={() => useBrowser.getState().openPanel(windowId, tab.url)}
          style={{ flex: 1 }}
        >
          <PageLabel tab={tab} hovered={hovered} />
        </WindowDragRegion>
      </ContextMenuArea>
    </View>
  );
}

import { hostedKinds, SolaraHostedView } from "@ardia/settings";
import { memo, useMemo } from "react";
import { Image, StyleSheet } from "react-native";
import { useShallow } from "zustand/react/shallow";
import { closeTab, toggleMute } from "../../lib/actions";
import { faviconUri } from "../../lib/favicons";
import { bundledSiteIcon } from "../../lib/siteIcons";
import { shortcutHint } from "../../lib/commandShortcuts";
import { PRODUCT } from "../../lib/productName";
import { useLifecycle } from "../../lib/tabLifecycle";
import { hex, profileTheme, selectedTabGlow, spaceLookSource, useSelectedTabGlow, useTheme, type Theme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { engineMark, ENGINE_SYMBOLS } from "../../store/engines";
import { useSettings } from "../../store/hooks";
import { activeTabId, isIncognitoProfile } from "../../store/model";
import { cleanedTabsFor } from "../../store/organize";
import { canTidyPins } from "../../store/tidyPins";
import { usePagerPages } from "../layout/profilePager";
import { openNewTabInSplit } from "../layout/splitActions";
import { isDeveloperMode } from "../../lib/developerMode";
import { developerModeFor } from "../site/developerMode";
import { toggleNewTabBar } from "../omnibox/newTabBar";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import { clickTab, commitRename, endRename, startRename } from "./actions";
import { pressGroupClose, pressTabClose } from "./closeControl";
import { dismissHover, nativeRowHover } from "./hover";
import { closeAllTabs, middleClickTab, openGroupMenu, openOverflowMenu, openSidebarMenu, openTabMenu } from "./menus";
import { useSidebarUi } from "./state";
import { tidyPins } from "./tidyPinsUi";
import { openTileFolderMenu, toggleFolderPanel } from "./tileFolderUi";

let nativeSidebar: boolean | undefined;

export function nativeSidebarEnabled(): boolean {
  return (nativeSidebar ??= hostedKinds().includes("sidebar"));
}

const NEW_TAB_MARK: number = PRODUCT === "Solara" ? require("../../../assets/solara/new-tab-mark.png") : require("../../../assets/new-tab-mark.png");
const THEME_KEYS = [
  "textTab",
  "tabSelectedText",
  "tabHover",
  "tabPressed",
  "tabSelected",
  "rowHover",
  "divider",
  "textPrimary",
  "textSecondary",
  "textTertiary",
  "icon",
  "pinnedResting",
  "pinnedRestingStroke",
  "pinnedSelectedFill",
  "pinnedSelectedRim",
  "pinnedSelectedOutline",
  "accent",
  "toolbarHover",
  "toolbarPressed",
] as const;
const NONE: string[] = [];

type Mods = { meta?: boolean; shift?: boolean; alt?: boolean };

const FAVICON_WAIT_MS = 3000;

addNativeSettingsHandlers({
  "sidebar.favicon": async (url: string, profileId: string | null, dark: boolean) => {
    const cached = await faviconUri(url, profileId ?? undefined, 0);
    if (cached) return cached;
    const icon = bundledSiteIcon(url, dark);
    if (icon !== undefined) return Image.resolveAssetSource(icon)?.uri ?? null;
    return faviconUri(url, profileId ?? undefined, FAVICON_WAIT_MS);
  },
  "sidebar.action": (windowId: string, name: string, id: string, extra: Mods & { kind?: "tab" | "group" | "folder"; split?: boolean; text?: string | null }) => {
    const s = useBrowser.getState();
    if (name === "hover") return nativeRowHover(windowId, extra.kind && id ? { kind: extra.kind as "tab" | "group" | "folder", id } : null);
    dismissHover();
    switch (name) {
      case "clicked":
        if (s.selectionAnchors[windowId] !== id) useBrowser.setState({ selectionAnchors: { ...s.selectionAnchors, [windowId]: id } });
        if (s.selection[windowId]?.length) s.setSelection(windowId, []);
        return;
      case "click":
        return clickTab(windowId, id, { metaKey: !!extra.meta, shiftKey: !!extra.shift, altKey: !!extra.alt });
      case "close":
        return pressTabClose(id);
      case "middleClick":
        return s.tabs[id]?.pinned && !s.tabs[id]?.pinnedAsRow ? void closeTab(id) : middleClickTab(id);
      case "rename":
        return void startRename(windowId, { kind: extra.kind === "group" ? "group" : "tab", id });
      case "backToPinned":
        return s.returnToPinnedUrl(id);
      case "tileDoubleClick":
        if (activeTabId(s, windowId) === id) s.returnToPinnedUrl(id);
        return;
      case "toggleMute":
        return toggleMute(id);
      case "tabMenu": {
        const tab = s.tabs[id];
        return tab ? void openTabMenu(windowId, tab) : undefined;
      }
      case "groupMenu":
        return void openGroupMenu(windowId, id);
      case "toggleGroup": {
        const group = s.groups[id];
        return group ? s.updateGroup(id, { collapsed: !group.collapsed }) : undefined;
      }
      case "closeGroup":
        return pressGroupClose(id);
      case "sidebarMenu":
        return void openSidebarMenu(windowId);
      case "overflowMenu":
        return void openOverflowMenu(windowId);
      case "newTab":
        if (extra.split) return openNewTabInSplit(windowId);
        return void (toggleNewTabBar(windowId) || s.newTab(windowId, { newTabCommand: true }));
      case "folder":
        return void toggleFolderPanel(windowId, id);
      case "folderMenu":
        return void openTileFolderMenu(windowId, id);
      case "tidy":
        return tidyPins(windowId, id || undefined);
      case "clear":
        return closeAllTabs(windowId);
      case "renamed": {
        const target = { kind: extra.kind === "group" ? ("group" as const) : ("tab" as const), id };
        return typeof extra.text === "string" ? commitRename(target, extra.text) : endRename(target);
      }
    }
  },
});

function liveIds(s: ReturnType<typeof useBrowser.getState>, windowId: string, key: "isLoading" | "playingAudio"): string {
  const ids = s.windows[windowId]?.tabIds ?? NONE;
  let out = "";
  for (const id of ids) if (s.live[id]?.[key]) out += (out ? "," : "") + id;
  return out;
}

const split = (ids: string) => (ids ? ids.split(",") : NONE);

function themeTokens(theme: Theme): Record<string, string> {
  const tokens: Record<string, string> = {};
  for (const key of THEME_KEYS) tokens[key] = theme[key];
  tokens.backdropTint = theme.backdrop.tintColor;
  return tokens;
}

function usePageLooks(windowId: string) {
  const { pages, paging } = usePagerPages(windowId);
  const ids = paging ? pages.map((p) => p.id) : NONE;
  const profiles = useBrowser((s) => s.profiles);
  const appDark = useBrowser((s) => s.ui.appDark);
  const source = useBrowser((s) => spaceLookSource(s.settings));
  const glowSetting = useBrowser((s) => s.settings.selectedTabGlow);
  const tidy = useBrowser((s) => ids.filter((id) => canTidyPins(s, windowId, id)).join(","));
  const key = ids.join(",");
  return useMemo(() => {
    if (!key) return null;
    const tidyIds = new Set(split(tidy));
    return key.split(",").map((profileId) => {
      const theme = profileTheme(profiles[profileId], appDark, source);
      const glow = selectedTabGlow(theme, glowSetting);
      return {
        profileId,
        dark: theme.dark,
        theme: themeTokens(theme),
        border: theme.tabSelectedBorder.map(hex),
        glow: { color: glow.shadowColor, opacity: glow.shadowOpacity, radius: glow.shadowRadius },
        tidy: tidyIds.has(profileId),
        incognito: isIncognitoProfile(profileId),
      };
    });
  }, [key, profiles, appDark, source, glowSetting, tidy]);
}

export const NativeSidebar = memo(function NativeSidebar({ windowId, profileId, addressBar }: { windowId: string; profileId: string; addressBar: boolean }) {
  const theme = useTheme();
  const glow = useSelectedTabGlow();
  const selection = useBrowser((s) => s.selection[windowId] ?? NONE);
  const loading = useBrowser((s) => liveIds(s, windowId, "isLoading"));
  const playing = useBrowser((s) => liveIds(s, windowId, "playingAudio"));
  const sleeping = useLifecycle(useShallow((l) => Object.keys(l.discarded).filter((id) => l.discarded[id])));
  const renaming = useSidebarUi((u) => (u.renaming?.windowId === windowId && (u.renaming.kind === "tab" || u.renaming.kind === "group") ? `${u.renaming.kind}:${u.renaming.id}` : null));
  const clear = useSettings((s) => s.showClearButton);
  const tidy = useBrowser((s) => canTidyPins(s, windowId, profileId));
  const newTabAtTop = useSettings((s) => s.newTabButtonPosition === "top");
  const iconRing = useSettings((s) => s.pinnedTabIconRing);
  const cleaned = useBrowser((s) => cleanedTabsFor(s, windowId).length);
  const closeHint = useBrowser((s) => shortcutHint("closeTab", s) ?? null);
  const developer = useBrowser((s) => {
    let out = "";
    for (const id of s.windows[windowId]?.tabIds ?? NONE) {
      const tab = s.tabs[id];
      if (tab && isDeveloperMode(tab.url, developerModeFor(s.settings, tab.profileId))) out += (out ? "," : "") + id;
    }
    return out;
  });
  const engines = useBrowser(
    useShallow((s) => {
      const out: Record<string, string> = {};
      for (const id of s.windows[windowId]?.tabIds ?? NONE) {
        const mark = engineMark(s, id);
        if (mark) out[id] = ENGINE_SYMBOLS[mark];
      }
      return out;
    }),
  );

  const pages = usePageLooks(windowId);

  const state = useMemo(() => {
    return JSON.stringify({
      profileId,
      dark: theme.dark,
      theme: themeTokens(theme),
      border: theme.tabSelectedBorder.map(hex),
      glow: { color: glow.shadowColor, opacity: glow.shadowOpacity, radius: glow.shadowRadius },
      selection,
      loading: split(loading),
      playing: split(playing),
      sleeping,
      closeHint,
      backHint: null,
      renaming,
      addressBar,
      tidy,
      clear,
      iconRing,
      newTabAtTop,
      incognito: isIncognitoProfile(profileId),
      cleaned,
      engines,
      developer: split(developer),
      newTabMark: Image.resolveAssetSource(NEW_TAB_MARK)?.uri ?? null,
      pages,
    });
  }, [pages, theme, glow.shadowColor, glow.shadowOpacity, glow.shadowRadius, profileId, selection, loading, playing, sleeping, closeHint, renaming, addressBar, tidy, clear, iconRing, newTabAtTop, cleaned, engines, developer]);

  return <SolaraHostedView kind="sidebar" windowId={windowId} state={state} style={StyleSheet.absoluteFill} />;
});

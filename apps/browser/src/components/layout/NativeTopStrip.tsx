import { hostedKinds, SolaraHostedView } from "@ardia/settings";
import { memo, useMemo } from "react";
import { Image, StyleSheet } from "react-native";
import { useShallow } from "zustand/react/shallow";
import { toggleMute } from "../../lib/actions";
import { shortcutHint } from "../../lib/commandShortcuts";
import { PRODUCT } from "../../lib/productName";
import { useLifecycle } from "../../lib/tabLifecycle";
import { hex, profileTheme, selectedTabGlow, spaceLookSource, useSelectedTabGlow, useTheme, type Theme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { engineMark, ENGINE_SYMBOLS } from "../../store/engines";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import { clickTab } from "../sidebar/actions";
import { pressGroupClose, pressTabClose } from "../sidebar/closeControl";
import { openGroupMenu, openTabMenu } from "../sidebar/menus";
import { openTileFolderMenu } from "../sidebar/tileFolderUi";
import { toggleNewTabBar } from "../omnibox/newTabBar";
import { useToolbarSiteColor } from "../site/developerMode";
import { usePagerPages } from "./profilePager";
import { openNewTabInSplit } from "./splitActions";
import { openFolderMenu, openTileFolderStripMenu } from "./stripFolderMenu";
import { tuckTarget } from "./stripGroups";

let nativeTopStrip: boolean | undefined;

export function nativeTopStripEnabled(): boolean {
  return (nativeTopStrip ??= hostedKinds().includes("topStrip"));
}

const NEW_TAB_MARK: number = PRODUCT === "Solara" ? require("../../../assets/solara/new-tab-mark.png") : require("../../../assets/new-tab-mark.png");
const THEME_KEYS = [
  "textTab",
  "tabSelectedText",
  "tabHover",
  "tabPressed",
  "tabSelected",
  "textPrimary",
  "textSecondary",
  "textTertiary",
  "icon",
  "pinnedResting",
  "pinnedRestingStroke",
  "pinnedSelectedFill",
  "accent",
  "toolbarHover",
  "toolbarPressed",
  "card",
] as const;
const NONE: string[] = [];

addNativeSettingsHandlers({
  "topStrip.action": (windowId: string, name: string, id: string, extra: { meta?: boolean; shift?: boolean; alt?: boolean; collapse?: boolean; split?: boolean }) => {
    const s = useBrowser.getState();
    switch (name) {
      case "click":
        return clickTab(windowId, id, { metaKey: !!extra.meta, shiftKey: !!extra.shift, altKey: !!extra.alt });
      case "activate":
        return s.activate(id);
      case "close":
        return pressTabClose(id);
      case "toggleMute":
        return toggleMute(id);
      case "tabMenu": {
        const tab = s.tabs[id];
        return tab ? void openTabMenu(windowId, tab) : undefined;
      }
      case "groupMenu":
        return void openGroupMenu(windowId, id);
      case "toggleGroup":
        return s.groups[id] ? s.updateGroup(id, { collapsed: !!extra.collapse }) : undefined;
      case "closeGroup":
        return pressGroupClose(id);
      case "tuck": {
        const group = s.groups[id];
        const target = group && tuckTarget(s, windowId, group.profileId, id);
        return target ? s.activate(target) : undefined;
      }
      case "folderMenu":
        return void openFolderMenu(windowId, id);
      case "tileFolder":
        return void openTileFolderStripMenu(windowId, id);
      case "tileFolderMenu":
        return void openTileFolderMenu(windowId, id);
      case "newTab":
        if (extra.split) return openNewTabInSplit(windowId);
        return void (toggleNewTabBar(windowId) || s.newTab(windowId, { newTabCommand: true }));
    }
  },
});

function themeTokens(theme: Theme): Record<string, string> {
  const tokens: Record<string, string> = {};
  for (const key of THEME_KEYS) tokens[key] = theme[key];
  tokens.windowTint = theme.windowTint[0]!;
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
  const key = ids.join(",");
  return useMemo(() => {
    if (!key) return null;
    return key.split(",").map((profileId) => {
      const theme = profileTheme(profiles[profileId], appDark, source);
      const glow = selectedTabGlow(theme, glowSetting);
      return {
        profileId,
        dark: theme.dark,
        theme: themeTokens(theme),
        border: theme.tabSelectedBorder.map(hex),
        glow: { color: glow.shadowColor, opacity: glow.shadowOpacity, radius: glow.shadowRadius },
        tidy: false,
        incognito: false,
      };
    });
  }, [key, profiles, appDark, source, glowSetting]);
}

const split = (ids: string) => (ids ? ids.split(",") : NONE);

export const NativeTopStrip = memo(function NativeTopStrip({ windowId, profileId, floating, pageWidth }: { windowId: string; profileId: string; floating: boolean; pageWidth: number }) {
  const theme = useTheme();
  const glow = useSelectedTabGlow();
  const activeId = useBrowser((s) => s.windows[windowId]?.activeTabIds[profileId] ?? "");
  const band = useToolbarSiteColor(activeId || undefined);
  const playing = useBrowser((s) => {
    let out = "";
    for (const id of s.windows[windowId]?.tabIds ?? NONE) if (s.live[id]?.playingAudio) out += (out ? "," : "") + id;
    return out;
  });
  const sleeping = useLifecycle(useShallow((l) => Object.keys(l.discarded).filter((id) => l.discarded[id])));
  const closeHint = useBrowser((s) => shortcutHint("closeTab", s) ?? null);
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

  const state = useMemo(
    () =>
      JSON.stringify({
        profileId,
        dark: theme.dark,
        theme: themeTokens(theme),
        border: theme.tabSelectedBorder.map(hex),
        glow: { color: glow.shadowColor, opacity: glow.shadowOpacity, radius: glow.shadowRadius },
        floating,
        pageWidth,
        playing: split(playing),
        sleeping,
        engines,
        capture: {},
        bands: band && activeId ? { [activeId]: band } : {},
        closeHint,
        developer: NONE,
        newTabMark: Image.resolveAssetSource(NEW_TAB_MARK)?.uri ?? null,
        pages,
      }),
    [pages, theme, glow.shadowColor, glow.shadowOpacity, glow.shadowRadius, profileId, floating, pageWidth, playing, sleeping, engines, band, activeId, closeHint],
  );

  return <SolaraHostedView kind="topStrip" windowId={windowId} state={state} style={StyleSheet.absoluteFill} />;
});

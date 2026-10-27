import { NativeSitePanelView, type NativeSitePanelEvent } from "@ardia/settings";
import { translation } from "@ardia/shell";
import { useState } from "react";
import { StyleSheet, View } from "react-native";
import { useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { isIncognitoProfile } from "../../store/model";
import { activateExtension, openWebStore, showExtensionMenu, useWindowExtensions } from "../extensions/state";
import { useThemeTokens } from "../omnibox/nativeBar";
import { addExtensionMenu } from "./SiteExtensions";
import { chooseLanguage } from "./TranslateControls";
import { defaultTarget, isNeverTranslated, languageName, setNeverTranslate, toggleTranslation, useTranslateState } from "./translate";

type Rect = [number, number, number, number];

export type SitePanelItem =
  | { kind: "tiles"; tiles: { id: string; icon: string; label: string; active?: boolean }[] }
  | { kind: "section"; title: string; tight?: boolean }
  | { kind: "extensions"; columns: number; extensions: { id: string; name: string; icon?: string | null; symbol?: string; dimmed?: boolean }[] }
  | { kind: "setting"; id: string; icon: string; title: string; value: string; on: boolean; pressable: boolean }
  | {
      kind: "row";
      id: string;
      icon?: string;
      iconColor?: string;
      title: string;
      detail?: string;
      pressable?: boolean;
      accessory?: { kind: "value"; title: string } | { kind: "toggle"; value: boolean } | { kind: "zoom"; zoom: number };
    }
  | { kind: "separator" }
  | { kind: "header"; title: string; detail?: string; favicon: { url: string; favicon: string | null; profileId: string } }
  | { kind: "certificate"; rows: [string, string][] }
  | { kind: "footer"; top: number; chip: { icon: string; title: string; color?: string; open: boolean }; moreOpen: boolean }
  | { kind: "slot"; id: "extensions" | "translate"; columns?: number };

export type SitePanelHandler = {
  press?(rect: Rect, clickAt: number): void;
  menu?(rect: Rect): void;
  toggle?(value: boolean): void;
  zoom?(step: number): void;
};

const anchorOf = ([x, y, width, height]: Rect) => ({ x, y, width, height });

export function NativeSiteBody({
  tabId,
  windowId,
  items,
  handlers,
  onClose,
}: {
  tabId: string;
  windowId: string;
  items: SitePanelItem[];
  handlers: Record<string, SitePanelHandler>;
  onClose: () => void;
}) {
  const theme = useTheme();
  const tokens = useThemeTokens(theme);
  const [height, setHeight] = useState<number | null>(null);
  const extensions = useWindowExtensions(windowId);
  const translate = useTranslateState(tabId);
  const tab = useBrowser((s) => s.tabs[tabId]);
  useBrowser((s) => s.settings.neverTranslateSites);
  const all: Record<string, SitePanelHandler> = { ...handlers };
  const expanded: Exclude<SitePanelItem, { kind: "slot" }>[] = [];
  for (const item of items) {
    if (item.kind !== "slot") {
      expanded.push(item);
      continue;
    }
    if (item.id === "extensions") {
      expanded.push({ kind: "section", title: "Extensions" });
      expanded.push({
        kind: "extensions",
        columns: item.columns ?? 4,
        extensions: [
          ...extensions.map((ext) => ({ id: `ext:${ext.id}`, name: ext.pinned ? `${ext.actionTitle || ext.name} (pinned)` : ext.actionTitle || ext.name, icon: ext.actionIcon || ext.icon || null })),
          { id: "ext:add", name: "Add Extension", icon: null, symbol: "plus" },
        ],
      });
      for (const ext of extensions) {
        all[`ext:${ext.id}`] = {
          press: (rect) => {
            onClose();
            void activateExtension(windowId, ext, anchorOf(rect), undefined, tabId);
          },
          menu: () => void showExtensionMenu(windowId, ext),
        };
      }
      all["ext:add"] = {
        press: () => {
          onClose();
          openWebStore(windowId);
        },
        menu: () => void addExtensionMenu(windowId, onClose),
      };
      continue;
    }
    const never = tab ? isNeverTranslated(tab.profileId, tab.url) : false;
    if (!translation || !tab || (!translate.source && translate.status === "idle" && !never)) continue;
    const translated = translate.status !== "idle";
    if (!never) {
      expanded.push({
        kind: "row",
        id: "translate:toggle",
        icon: translated ? "arrow.uturn.backward" : "translate",
        title: translated ? `Show Original (${languageName(translate.source ?? "")})` : `Translate to ${languageName(defaultTarget())}`,
        pressable: true,
      });
      expanded.push({ kind: "row", id: "translate:choose", icon: "globe", title: "Choose Another Language…", pressable: true });
      all["translate:toggle"] = {
        press: () => {
          onClose();
          toggleTranslation(tabId);
        },
      };
      all["translate:choose"] = {
        press: () => {
          onClose();
          void chooseLanguage(tabId);
        },
      };
    }
    if (!isIncognitoProfile(tab.profileId)) {
      expanded.push({ kind: "row", id: "translate:never", icon: "nosign", title: "Never Translate This Site", accessory: { kind: "toggle", value: never } });
      all["translate:never"] = { toggle: (v) => setNeverTranslate(tabId, v) };
    }
    expanded.push({ kind: "separator" });
  }
  const state = JSON.stringify({ items: expanded, dark: !!theme.dark, theme: tokens });
  const onEvent = (e: NativeSitePanelEvent) => {
    const handler = all[e.id];
    if (!handler) return;
    if (e.kind === "press") handler.press?.(e.rect, e.clickAt);
    else if (e.kind === "menu") handler.menu?.(e.rect);
    else if (e.kind === "toggle") handler.toggle?.(e.value);
    else handler.zoom?.(e.step);
  };
  return (
    <View style={{ height: height ?? undefined, minHeight: 1 }}>
      <NativeSitePanelView style={StyleSheet.absoluteFill} state={state} onSitePanelEvent={(e) => onEvent(e.nativeEvent)} onSitePanelHeight={(e) => setHeight(e.nativeEvent.height)} />
    </View>
  );
}

import { MouseArea, Symbol } from "@ardia/shell";
import { useEffect, useMemo, useState } from "react";
import { Image, Pressable, StyleSheet, Text, View } from "react-native";
import { nativeToolbarAvailable, NativePanelView, windowShellActive, type NativePanelEvent } from "@ardia/settings";
import { useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { openModeFor, openUrl } from "../bookmarks/actions";
import { openInternalPage } from "../pages/urls";
import { Favicon, NEW_TAB_MARK, NewTabIcon, useHover } from "../primitives";
import { modifiersOf, PANEL, Popover, POPOVER_MARGIN, PopoverSeparator } from "./controls";
import { closeHistoryMenu, goToHistoryItem, useHistoryMenu, type HistoryItem } from "./history";
import { useNativeHistoryHandler, useNativePaneOverlay, usePageFrame } from "./nativePaneOverlays";

const WIDTH = 300;
const FAVICON_X = PANEL.inset + (PANEL.iconSlot - 16) / 2;

export function HistoryPopover({ tabId, windowId, anchors, nativeAllowed = true }: { tabId: string; windowId: string; anchors: { back: number; forward: number }; nativeAllowed?: boolean }) {
  const menu = useHistoryMenu((s) => (s.menu?.tabId === tabId ? s.menu : null));
  const theme = useTheme();
  const profileId = useBrowser((s) => s.tabs[tabId]?.profileId ?? "");
  const favicons = useMemo(() => {
    if (!menu) return new Map<string, string | null>();
    const history = useBrowser.getState().history[profileId] ?? [];
    const urls = new Set(menu.items.map((i) => i.url));
    return new Map(history.filter((h) => urls.has(h.url)).map((h) => [h.url, h.favicon]));
  }, [menu, profileId]);
  const [inShell] = useState(() => nativeAllowed && windowShellActive(windowId));
  const { frame, ref, onLayout } = usePageFrame();
  useEffect(() => () => void (useHistoryMenu.getState().menu?.tabId === tabId && closeHistoryMenu()), [tabId]);
  const left = menu ? Math.max(POPOVER_MARGIN, (menu.direction < 0 ? anchors.back : anchors.forward) - FAVICON_X - 2) : 0;
  const panelState = menu && {
    items: menu.items.map((item) => ({ title: item.title, url: item.url, favicon: favicons.get(item.url) ?? null, newTab: item.offset === "newTab" })),
    profileId,
    dark: !!theme.dark,
    theme: { textPrimary: theme.textPrimary, textSecondary: theme.textSecondary, icon: theme.icon },
    newTabMark: Image.resolveAssetSource(NEW_TAB_MARK)?.uri ?? null,
    popover: { width: WIDTH, top: POPOVER_MARGIN, left },
  };
  const open = (item: HistoryItem, e: { metaKey?: boolean; shiftKey?: boolean; altKey?: boolean; middle?: boolean }) => {
    const mode = openModeFor(e);
    if (mode === "current" || mode === "split" || !item.url) {
      closeHistoryMenu();
      return void goToHistoryItem(tabId, item);
    }
    if (mode !== "background") closeHistoryMenu();
    openUrl(item.url, windowId, mode);
  };

  const onPanelEvent = (ev: { kind: string; index?: unknown; metaKey?: unknown; shiftKey?: unknown; altKey?: unknown; middle?: unknown }) => {
    if (!menu) return;
    if (ev.kind === "dismiss") return closeHistoryMenu();
    if (ev.kind === "fullHistory") {
      closeHistoryMenu();
      return openInternalPage("history", windowId);
    }
    const item = menu.items[Number(ev.index)];
    if (item) open(item, { metaKey: !!ev.metaKey, shiftKey: !!ev.shiftKey, altKey: !!ev.altKey, middle: !!ev.middle });
  };
  useNativePaneOverlay(inShell, windowId, tabId, "history", panelState && frame ? { ...panelState, frame } : null);
  useNativeHistoryHandler(inShell, windowId, tabId, onPanelEvent);
  if (!menu) return null;
  if (inShell) return <View ref={ref} pointerEvents="none" collapsable={false} onLayout={onLayout} style={StyleSheet.absoluteFill} />;

  if (nativeToolbarAvailable()) {
    return (
      <NativePanelView
        kind="history"
        style={StyleSheet.absoluteFill}
        pointerEvents="box-none"
        state={JSON.stringify(panelState)}
        onPanelEvent={(e) => onPanelEvent(e.nativeEvent as NativePanelEvent & { index?: unknown })}
      />
    );
  }

  return (
    <Popover width={WIDTH} top={POPOVER_MARGIN} left={left} onDismiss={closeHistoryMenu}>
      <View style={{ paddingVertical: PANEL.listPadding }}>
        {menu.items.map((item) => (
          <Row key={item.key} item={item} favicon={favicons.get(item.url) ?? null} onOpen={(e) => open(item, e)} />
        ))}
        <PopoverSeparator />
        <ActionRow
          icon="clock"
          title="Show Full History"
          onPress={() => {
            closeHistoryMenu();
            openInternalPage("history", windowId);
          }}
        />
      </View>
    </Popover>
  );
}

function RowFrame({ children, hovered, pressed }: { children: React.ReactNode; hovered: boolean; pressed: boolean }) {
  const theme = useTheme();
  return (
    <View
      style={{
        height: PANEL.rowHeight,
        marginHorizontal: PANEL.rowInset,
        paddingHorizontal: PANEL.rowPadding,
        borderRadius: PANEL.rowRadius,
        flexDirection: "row",
        alignItems: "center",
        gap: PANEL.iconGap,
        backgroundColor: pressed || hovered ? (theme.dark ? `rgba(255,255,255,${pressed ? 0.12 : 0.07})` : `rgba(0,0,0,${pressed ? 0.1 : 0.06})`) : undefined,
      }}
    >
      {children}
    </View>
  );
}

function Row({
  item,
  favicon,
  onOpen,
}: {
  item: HistoryItem;
  favicon: string | null;
  onOpen: (e: { metaKey?: boolean; shiftKey?: boolean; altKey?: boolean; middle?: boolean }) => void;
}) {
  const theme = useTheme();
  const { hovered, hoverProps } = useHover();
  return (
    <View {...hoverProps} tooltip={item.url || undefined}>
      <MouseArea onMiddleClick={(e) => onOpen({ ...e, middle: true })}>
        <Pressable onPress={(e) => onOpen(modifiersOf(e))}>
          {({ pressed }) => (
            <RowFrame hovered={hovered} pressed={pressed}>
              <View style={{ width: PANEL.iconSlot, alignItems: "center" }}>{item.offset === "newTab" ? <NewTabIcon size={16} /> : <Favicon url={item.url} favicon={favicon} size={16} />}</View>
              <Text numberOfLines={1} style={{ flex: 1, fontSize: 13, color: theme.textPrimary }}>
                {item.title}
              </Text>
            </RowFrame>
          )}
        </Pressable>
      </MouseArea>
    </View>
  );
}

function ActionRow({ icon, title, onPress }: { icon: string; title: string; onPress: () => void }) {
  const theme = useTheme();
  const { hovered, hoverProps } = useHover();
  return (
    <View {...hoverProps}>
      <Pressable onPress={onPress}>
        {({ pressed }) => (
          <RowFrame hovered={hovered} pressed={pressed}>
            <Symbol name={icon} size={PANEL.iconSize} color={theme.icon} style={{ width: PANEL.iconSlot, height: PANEL.iconSlot }} />
            <Text numberOfLines={1} style={{ flex: 1, fontSize: 13, color: theme.textPrimary }}>
              {title}
            </Text>
          </RowFrame>
        )}
      </Pressable>
    </View>
  );
}


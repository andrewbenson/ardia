import { ContextMenuArea, FadeLabel, OutsidePressArea, Surface } from "@ardia/shell";
import { requireOptionalNativeModule, type EventSubscription } from "expo-modules-core";
import { useEffect, useMemo, useState } from "react";
import { Animated, Pressable, Text, View } from "react-native";
import { useShallow } from "zustand/react/shallow";
import { hex, layout, useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { useIsActiveTab, useTab } from "../../store/hooks";
import { activeTabId, plural } from "../../store/model";
import { folderIn, folderLabel, folderMembers } from "../../store/tileFolders";
import { SLIDE } from "../layout/stripReorder";
import { useHover } from "../primitives";
import { clickTab, tabTitle } from "./actions";
import { useDragController, useDragItem, useFolderAway } from "./dnd";
import { openTabMenu } from "./menus";
import { TabIcon } from "./TabIcon";
import { closeFolderPanel, closeFolderPanelOnPress, openTileFolderMenu, useFolderPanel } from "./tileFolderUi";

const PANEL_GAP = 6;
const PANEL_PAD = 6;

type Frame = { x: number; y: number; w: number; h: number };

type FolderPanelNative = {
  available(): boolean;
  show(windowId: string, json: string): Promise<void>;
  hide(windowId: string): Promise<void>;
  addListener(event: "onFolderPanelEvent", listener: (e: { windowId: string; folderId: string; kind: string; tabId?: string }) => void): EventSubscription;
};

const nativePanel = requireOptionalNativeModule<FolderPanelNative>("SolaraFolderPanel");
let nativeOn: boolean | null = null;
const nativeFolderPanel = () => (nativeOn ??= (() => {
  try {
    return !!nativePanel?.available();
  } catch {
    return false;
  }
})());

export function FolderPanel({ windowId }: { windowId: string }) {
  const open = useFolderPanel((u) => (u.open?.windowId === windowId ? u.open : null));
  if (nativeFolderPanel()) return <NativeFolderPanel windowId={windowId} folderId={open?.folderId ?? null} />;
  if (!open) return null;
  return <PanelBody key={open.folderId} windowId={windowId} folderId={open.folderId} anchor={open.anchor} />;
}

function PanelBody({ windowId, folderId, anchor }: { windowId: string; folderId: string; anchor: { x: number; y: number; width: number; height: number } }) {
  const theme = useTheme();
  const controller = useDragController();
  const members = useBrowser(useShallow((s) => folderMembers(s, windowId, folderId)));
  const label = useBrowser((s) => folderLabel(folderIn(s, windowId, folderId)));
  const away = useFolderAway();
  const [root, setRoot] = useState<Frame | null>(null);
  const shown = useMemo(() => new Animated.Value(0), []);
  const tail = useDragItem("tail:folder", { kind: "tail", tabIds: [], section: "folder" });

  useEffect(() => {
    controller?.root?.measureInWindow((x, y, w, h) => setRoot({ x, y, w, h }));
  }, [controller]);
  useEffect(() => {
    if (!root) return;
    const spring = Animated.spring(shown, { toValue: 1, ...SLIDE });
    spring.start();
    return () => spring.stop();
  }, [root, shown]);
  useEffect(() => {
    if (!members.length) closeFolderPanel();
  }, [members.length]);
  useEffect(
    () =>
      useBrowser.subscribe((s, prev) => {
        if (s.windows === prev.windows) return;
        const w = s.windows[windowId];
        if (!w || w.profileId !== prev.windows[windowId]?.profileId || activeTabId(s, windowId) !== activeTabId(prev, windowId)) closeFolderPanel();
      }),
    [windowId],
  );
  useEffect(
    () => () => {
      controller?.regions.delete("folder");
    },
    [controller],
  );
  if (!root) return null;

  return (
    <Animated.View
      ref={(v: View | null) => {
        controller?.regions.set("folder", v);
      }}
      pointerEvents={away ? "none" : "box-none"}
      style={{
        position: "absolute",
        left: layout.sidebarInset,
        width: root.w - layout.sidebarInset * 2,
        top: anchor.y + anchor.height + PANEL_GAP - root.y,
        opacity: away ? 0 : shown,
        transform: [{ scale: shown.interpolate({ inputRange: [0, 1], outputRange: [0.92, 1] }) }],
      }}
    >
      <OutsidePressArea onOutsidePress={closeFolderPanelOnPress}>
        <Surface
          fill={hex(theme.panel)}
          cornerRadius={12}
          borderColor={hex(theme.panelBorder)}
          borderWidth={0.5}
          shadowColor="#000000"
          shadowOpacity={theme.panelShadowOpacity * 0.8}
          shadowRadius={16}
          shadowOffset={[0, 6]}
          style={{ padding: PANEL_PAD }}
        >
          <ContextMenuArea onContextMenu={() => void openTileFolderMenu(windowId, folderId)}>
            <Text numberOfLines={1} style={{ fontSize: 12, fontWeight: "600", color: theme.textSecondary, marginTop: 2, marginBottom: 6, marginHorizontal: 6 }}>
              {label} · {plural(members.length, "tab")}
            </Text>
          </ContextMenuArea>
          <View style={{ gap: layout.rowGap }}>
            {members.map((id) => (
              <MemberRow key={id} tabId={id} windowId={windowId} />
            ))}
            <Animated.View ref={tail.wrapper.ref} style={tail.wrapper.style} />
          </View>
        </Surface>
      </OutsidePressArea>
    </Animated.View>
  );
}

function NativeFolderPanel({ windowId, folderId }: { windowId: string; folderId: string | null }) {
  const theme = useTheme();
  const members = useBrowser(useShallow((s) => (folderId ? folderMembers(s, windowId, folderId) : [])));
  const label = useBrowser((s) => (folderId ? folderLabel(folderIn(s, windowId, folderId)) : ""));
  const rows = useBrowser(
    useShallow((s) => {
      const active = activeTabId(s, windowId);
      return members.map((id) => {
        const tab = s.tabs[id];
        return tab ? `${id}\u0001${tabTitle(tab)}\u0001${id === active ? 1 : 0}` : "";
      });
    }),
  );
  useEffect(() => {
    if (folderId && !members.length) closeFolderPanel();
  }, [folderId, members.length]);
  useEffect(
    () =>
      useBrowser.subscribe((s, prev) => {
        if (!folderId || s.windows === prev.windows) return;
        const w = s.windows[windowId];
        if (!w || w.profileId !== prev.windows[windowId]?.profileId || activeTabId(s, windowId) !== activeTabId(prev, windowId)) closeFolderPanel();
      }),
    [windowId, folderId],
  );
  useEffect(() => {
    const sub = nativePanel?.addListener("onFolderPanelEvent", (e) => {
      if (e.windowId !== windowId || e.folderId !== folderId) return;
      const tab = e.tabId ? useBrowser.getState().tabs[e.tabId] : undefined;
      if (e.kind === "open" && e.tabId) {
        closeFolderPanel();
        clickTab(windowId, e.tabId);
      } else if (e.kind === "tabMenu" && tab) void openTabMenu(windowId, tab);
      else if (e.kind === "folderMenu" && folderId) void openTileFolderMenu(windowId, folderId);
      else if (e.kind === "outsidePress") closeFolderPanel();
    });
    return () => sub?.remove();
  }, [windowId, folderId]);
  const tokens = { panel: theme.panel, panelBorder: theme.panelBorder, textPrimary: theme.textPrimary, textSecondary: theme.textSecondary, textTab: theme.textTab, tabHover: theme.tabHover, tabPressed: theme.tabPressed, pinnedSelectedFill: theme.pinnedSelectedFill };
  const json = folderId
    ? JSON.stringify({
        folderId,
        label,
        members: rows.filter(Boolean).map((r) => {
          const [tabId, title, active] = r.split("\u0001");
          return { tabId, title, active: active === "1" };
        }),
        dark: !!theme.dark,
        theme: tokens,
        panelShadowOpacity: theme.panelShadowOpacity,
      })
    : null;
  useEffect(() => {
    if (json) void nativePanel?.show(windowId, json);
    else void nativePanel?.hide(windowId);
  }, [json, windowId]);
  useEffect(() => () => void nativePanel?.hide(windowId), [windowId]);
  return null;
}

function MemberRow({ tabId, windowId }: { tabId: string; windowId: string }) {
  const theme = useTheme();
  const tab = useTab(tabId);
  const active = useIsActiveTab(tabId);
  const { hovered, hoverProps } = useHover();
  const { wrapper, handle } = useDragItem(`fm:${tabId}`, { kind: "row", tabIds: [tabId], section: "folder" });
  if (!tab) return null;
  return (
    <Animated.View ref={wrapper.ref} style={wrapper.style} {...handle}>
      <View {...hoverProps}>
        <ContextMenuArea onContextMenu={() => void openTabMenu(windowId, tab)}>
          <Pressable
            onPress={() => {
              closeFolderPanel();
              clickTab(windowId, tabId);
            }}
          >
            {({ pressed }) => (
              <View
                style={{
                  height: layout.rowHeight,
                  borderRadius: 8,
                  flexDirection: "row",
                  alignItems: "center",
                  paddingHorizontal: 9,
                  backgroundColor: pressed ? theme.tabPressed : active ? theme.pinnedSelectedFill : hovered ? theme.tabHover : undefined,
                }}
              >
                <TabIcon tabId={tabId} url={tab.url} favicon={tab.favicon} icon={tab.customIcon} />
                <FadeLabel text={tabTitle(tab)} fontSize={13} color={active ? theme.textPrimary : theme.textTab} style={{ flex: 1, height: 18, marginLeft: 8 }} />
              </View>
            )}
          </Pressable>
        </ContextMenuArea>
      </View>
    </Animated.View>
  );
}

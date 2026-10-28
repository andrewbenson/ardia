import { terminateCastRoute, type ActionState, type CastRoute, type InstalledExtension } from "@ardia/ardiacore";
import { ContextMenuArea, showMenu, Symbol } from "@ardia/shell";
import { memo, useEffect, useMemo, useRef, useState } from "react";
import { Image, Pressable, Text, View } from "react-native";
import { useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { toggleCastPicker, useCastRoutes } from "../media/cast";
import type { ToolbarPalette } from "../layout/toolbarColors";
import { usePages } from "../layout/pageState";
import { useHover } from "../primitives";
import { dropToolbarAnchor, setToolbarAnchor } from "./bridge";
import {
  activateExtension,
  openManageExtensions,
  openPinDialog,
  openWebStore,
  showExtensionMenu,
  useExtensions,
  useWindowExtensions,
  windowExtensions,
  type Anchor,
} from "./state";

const BUTTON = 28;
const GAP = 2;
const PITCH = BUTTON + GAP;

function useToolbarExtensions(windowId: string, limit: number) {
  const shown = useWindowExtensions(windowId);
  const routes = useCastRoutes(windowId);
  const casting = routes.length > 0;
  return useMemo(() => {
    const all = shown.filter((x) => x.pinned);
    const room = Math.max(0, limit - (casting ? 1 : 0));
    const overflow = all.length > room;
    return { pinned: overflow ? all.slice(0, Math.max(0, room - 1)) : all, overflow, casting, routes };
  }, [shown, routes, casting, limit]);
}

export const extensionsFitting = (room: number) => Math.max(1, Math.floor((room + GAP) / PITCH));

export function useToolbarExtensionsWidth(windowId: string, limit = Infinity): number {
  const { pinned, overflow, casting } = useToolbarExtensions(windowId, limit);
  const count = pinned.length + (overflow ? 1 : 0) + (casting ? 1 : 0);
  return count ? count * PITCH - GAP + 6 : 0;
}

type ToolbarExtensionsProps = {
  tabId: string;
  windowId: string;
  palette: ToolbarPalette;
  top: number;
  right: number;
  limit?: number;
};

export type NativeExtensionButton = {
  id: string;
  anchor?: string;
  icon: string;
  size: number;
  box: number;
  radius: number;
  color?: string;
  image?: string | null;
  imageSize?: number;
  dimmed?: boolean;
  badge?: { text: string; color: string; textColor: string } | null;
  active?: boolean;
  menu?: boolean;
  tooltip: string;
};

export function useNativeToolbarExtensions(windowId: string, tabId: string, limit = Infinity) {
  const theme = useTheme();
  const { pinned, overflow, routes } = useToolbarExtensions(windowId, limit);
  const browserId = usePages((p) => {
    for (const [id, tab] of Object.entries(p.browsers)) if (tab === tabId) return Number(id);
    return 0;
  });
  const fetched = useExtensions((e) => (browserId ? e.actions[browserId] : undefined));
  const held = useRef<Record<string, ActionState>>({});
  if (fetched) held.current = { ...held.current, ...fetched };
  const popup = useExtensions((e) => (e.popup?.windowId === windowId ? e.popup.extensionId : null));
  const anchors = useRef(new Map<string, Anchor>());
  const owner = useRef({ windowId, tabId });
  owner.current = { windowId, tabId };
  useEffect(
    () => () => {
      for (const [slot, anchor] of anchors.current) dropToolbarAnchor(windowId, tabId, slot, anchor);
      anchors.current.clear();
    },
    [windowId, tabId],
  );
  const buttons: NativeExtensionButton[] = [];
  if (routes.length) {
    buttons.push({
      id: "ext-cast",
      icon: "tv.and.mediabox.fill",
      size: 14,
      box: BUTTON,
      radius: 7,
      color: theme.accent,
      menu: true,
      tooltip: routes.map((r) => (r.description ? `${r.description} on ${r.sink}` : `Casting to ${r.sink}`)).join("\n"),
    });
  }
  for (const ext of pinned) {
    const state = held.current[ext.id];
    const badgeText = state?.badgeText ?? "";
    const fill = state?.badgeColor && state.badgeColor !== "#000000" ? state.badgeColor : "#5F6368";
    buttons.push({
      id: `ext:${ext.id}`,
      anchor: ext.id,
      icon: "puzzlepiece.extension",
      size: 14,
      box: BUTTON,
      radius: 7,
      image: state?.icon || ext.actionIcon || ext.icon || null,
      imageSize: 16,
      dimmed: state ? !state.enabled : false,
      badge: badgeText ? { text: badgeText, color: fill, textColor: state?.badgeTextColor ?? contrastText(fill) } : null,
      active: popup === ext.id,
      menu: true,
      tooltip: state?.title || ext.actionTitle || ext.name,
    });
  }
  if (overflow) buttons.push({ id: "ext-overflow", anchor: "*", icon: "puzzlepiece.extension", size: 14, box: BUTTON, radius: 7, tooltip: "Extensions" });
  const onAnchors = (next: Record<string, [number, number, number, number]>) => {
    const { windowId: w, tabId: t } = owner.current;
    for (const [slot, anchor] of anchors.current) if (!next[slot]) dropToolbarAnchor(w, t, slot, anchor);
    const kept = new Map<string, Anchor>();
    for (const [slot, [x, y, width, height]] of Object.entries(next)) {
      const anchor = { x, y, width, height };
      kept.set(slot, anchor);
      setToolbarAnchor(w, t, slot, anchor);
    }
    anchors.current = kept;
  };
  const anchorOf = (slot: string) => anchors.current.get(slot) ?? { x: 0, y: 0, width: BUTTON, height: BUTTON };
  const onClick = (id: string, kind: "press" | "menu") => {
    if (id === "ext-cast") {
      if (kind === "menu") return void castMenu(windowId, routes);
      return void toggleCastPicker(windowId, tabId);
    }
    if (id === "ext-overflow") return void overflowMenu(windowId, tabId, anchorOf("*"));
    const ext = pinned.find((x) => `ext:${x.id}` === id);
    if (!ext) return false;
    if (kind === "menu") return void showExtensionMenu(windowId, ext);
    void activateExtension(windowId, ext, anchorOf(ext.id), fetched?.[ext.id], tabId);
  };
  return { buttons, onAnchors, onClick };
}

export const ToolbarExtensions = memo(function ToolbarExtensions(props: ToolbarExtensionsProps) {
  return <TabToolbarExtensions key={`${props.windowId}|${props.tabId}`} {...props} />;
});

function TabToolbarExtensions({
  tabId,
  windowId,
  palette,
  top,
  right,
  limit = Infinity,
}: ToolbarExtensionsProps) {
  const { pinned, overflow, routes } = useToolbarExtensions(windowId, limit);
  const browserId = usePages((p) => {
    for (const [id, tab] of Object.entries(p.browsers)) if (tab === tabId) return Number(id);
    return 0;
  });
  if (!pinned.length && !overflow && !routes.length) return <EmptyAnchor windowId={windowId} tabId={tabId} top={top} right={right} />;
  return (
    <View style={{ position: "absolute", top, right, flexDirection: "row", gap: GAP }}>
      {routes.length ? <CastButton windowId={windowId} tabId={tabId} routes={routes} palette={palette} /> : null}
      {pinned.map((ext) => (
        <ExtensionButton key={ext.id} ext={ext} windowId={windowId} tabId={tabId} browserId={browserId} palette={palette} />
      ))}
      {overflow && <OverflowButton windowId={windowId} tabId={tabId} palette={palette} />}
    </View>
  );
}

export function ToolbarPopupAnchor(props: { windowId: string; tabId: string; top: number; right: number }) {
  return <EmptyAnchor key={`${props.windowId}|${props.tabId}`} {...props} />;
}

function EmptyAnchor({ windowId, tabId, top, right }: { windowId: string; tabId: string; top: number; right: number }) {
  const { ref, measure } = useAnchor(windowId, tabId, "*");
  return <View ref={ref} pointerEvents="none" style={{ position: "absolute", top, right, width: BUTTON, height: BUTTON }} onLayout={() => void measure()} />;
}

function useAnchor(windowId: string, tabId: string, slot: string) {
  const ref = useRef<View>(null);
  const [owner] = useState(() => ({ windowId, tabId, slot }));
  const mine = useRef<Anchor | null>(null);
  useEffect(
    () => () => {
      if (mine.current) dropToolbarAnchor(owner.windowId, owner.tabId, owner.slot, mine.current);
      mine.current = null;
    },
    [owner],
  );
  const measure = () =>
    new Promise<Anchor>((resolve) => {
      const view = ref.current;
      if (!view) return resolve({ x: 0, y: 0, width: BUTTON, height: BUTTON });
      view.measureInWindow((x, y, width, height) => {
        const anchor = { x, y, width, height };
        if (ref.current) {
          mine.current = anchor;
          setToolbarAnchor(owner.windowId, owner.tabId, owner.slot, anchor);
        }
        resolve(anchor);
      });
    });
  return { ref, measure };
}

function ExtensionButton({ ext, windowId, tabId, browserId, palette }: { ext: InstalledExtension; windowId: string; tabId: string; browserId: number; palette: ToolbarPalette }) {
  const fetched = useExtensions((e) => (browserId ? e.actions[browserId] : undefined));
  const held = useRef<ActionState | undefined>(undefined);
  if (fetched) held.current = fetched[ext.id];
  const state = held.current;
  const open = useExtensions((e) => e.popup?.windowId === windowId && e.popup.extensionId === ext.id);
  const { hovered, hoverProps } = useHover();
  const { ref, measure } = useAnchor(windowId, tabId, ext.id);
  const badge = state?.badgeText ?? "";
  const dimmed = state ? !state.enabled : false;
  const title = state?.title || ext.actionTitle || ext.name;
  const icon = state?.icon || ext.actionIcon || ext.icon;
  return (
    <View ref={ref} tooltip={title} {...hoverProps} onLayout={() => void measure()}>
      <ContextMenuArea onContextMenu={() => void showExtensionMenu(windowId, ext)}>
        <Pressable onPress={async () => activateExtension(windowId, ext, await measure(), fetched?.[ext.id], tabId)}>
          {({ pressed }) => (
            <View
              style={{
                width: BUTTON,
                height: BUTTON,
                borderRadius: 7,
                alignItems: "center",
                justifyContent: "center",
                backgroundColor: pressed || open ? palette.pressed : hovered ? palette.hover : undefined,
              }}
            >
              {icon ? (
                <View pointerEvents="none">
                  <Image source={{ uri: icon }} style={{ width: 16, height: 16, opacity: dimmed ? 0.45 : 1 }} />
                </View>
              ) : (
                <Symbol name="puzzlepiece.extension" size={14} color={palette.icon} style={{ width: 18, height: 18 }} />
              )}
              {badge ? <Badge text={badge} color={state?.badgeColor} textColor={state?.badgeTextColor} /> : null}
            </View>
          )}
        </Pressable>
      </ContextMenuArea>
    </View>
  );
}

function Badge({ text, color, textColor }: { text: string; color?: string | null; textColor?: string | null }) {
  const fill = color && color !== "#000000" ? color : "#5F6368";
  return (
    <View
      pointerEvents="none"
      style={{
        position: "absolute",
        right: 1,
        bottom: 3,
        minWidth: 13,
        height: 11,
        paddingHorizontal: 2.5,
        borderRadius: 3,
        backgroundColor: fill,
        alignItems: "center",
        justifyContent: "center",
      }}
    >
      <Text numberOfLines={1} style={{ fontSize: 8.5, lineHeight: 11, fontWeight: "700", color: textColor ?? contrastText(fill) }}>
        {text.slice(0, 4)}
      </Text>
    </View>
  );
}

function contrastText(hex: string) {
  const n = parseInt(hex.slice(1, 7), 16);
  const [r, g, b] = [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  return 0.299 * r + 0.587 * g + 0.114 * b > 160 ? "#000000" : "#FFFFFF";
}

function CastButton({ windowId, tabId, routes, palette }: { windowId: string; tabId: string; routes: CastRoute[]; palette: ToolbarPalette }) {
  const theme = useTheme();
  const { hovered, hoverProps } = useHover();
  const tooltip = routes.map((r) => (r.description ? `${r.description} on ${r.sink}` : `Casting to ${r.sink}`)).join("\n");
  const menu = () => castMenu(windowId, routes);
  return (
    <View tooltip={tooltip} {...hoverProps}>
      <ContextMenuArea onContextMenu={() => void menu()}>
        <Pressable onPress={() => void toggleCastPicker(windowId, tabId)}>
          {({ pressed }) => (
            <View
              style={{
                width: BUTTON,
                height: BUTTON,
                borderRadius: 7,
                alignItems: "center",
                justifyContent: "center",
                backgroundColor: pressed ? palette.pressed : hovered ? palette.hover : undefined,
              }}
            >
              <Symbol name="tv.and.mediabox.fill" size={14} color={theme.accent} style={{ width: 18, height: 18 }} />
            </View>
          )}
        </Pressable>
      </ContextMenuArea>
    </View>
  );
}

function OverflowButton({ windowId, tabId, palette }: { windowId: string; tabId: string; palette: ToolbarPalette }) {
  const { hovered, hoverProps } = useHover();
  const { ref, measure } = useAnchor(windowId, tabId, "*");
  const onPress = async () => overflowMenu(windowId, tabId, await measure());
  return (
    <View ref={ref} tooltip="Extensions" {...hoverProps} onLayout={() => void measure()}>
      <Pressable onPress={onPress}>
        {({ pressed }) => (
          <View
            style={{
              width: BUTTON,
              height: BUTTON,
              borderRadius: 7,
              alignItems: "center",
              justifyContent: "center",
              backgroundColor: pressed ? palette.pressed : hovered ? palette.hover : undefined,
            }}
          >
            <Symbol name="puzzlepiece.extension" size={14} color={palette.icon} style={{ width: 18, height: 18 }} />
          </View>
        )}
      </Pressable>
    </View>
  );
}

async function castMenu(windowId: string, routes: CastRoute[]) {
  const choice = await showMenu([
    ...routes.map((r) => ({ id: `stop:${r.id}`, title: `Stop Casting to ${r.sink}`, symbol: "stop.circle" })),
    { separator: true as const },
    { id: "open", title: "Cast…", symbol: "tv.and.mediabox" },
  ]);
  if (choice === "open") void toggleCastPicker(windowId);
  else if (choice?.startsWith("stop:")) void terminateCastRoute(choice.slice(5));
}

async function overflowMenu(windowId: string, tabId: string, anchor: Anchor) {
  const enabled = windowExtensions(useBrowser.getState(), windowId);
  const choice = await showMenu([
    ...enabled.map((x) => ({ id: `open:${x.id}`, title: x.name, symbol: x.pinned ? "pin.fill" : undefined })),
    ...(enabled.length ? [{ separator: true as const }] : []),
    { id: "pin", title: "Pin Extensions…", symbol: "pin" },
    { id: "manage", title: "Manage Extensions…", symbol: "puzzlepiece.extension" },
    { id: "add", title: "Add Extension…", symbol: "plus" },
  ]);
  if (choice === "pin") return openPinDialog(windowId);
  if (choice === "manage") return openManageExtensions(windowId);
  if (choice === "add") return openWebStore(windowId);
  const ext = choice?.startsWith("open:") ? enabled.find((x) => x.id === choice.slice(5)) : undefined;
  if (ext) void activateExtension(windowId, ext, anchor, undefined, tabId);
}

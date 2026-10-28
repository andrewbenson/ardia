import { useEffect, useMemo, useRef, type RefObject } from "react";
import { NativeSidebarAddressBarView, setSidebarAddressBar, sidebarAddressBarAvailable, type ToolbarClick } from "@ardia/settings";
import { FadeLabel } from "@ardia/shell";
import { Pressable, StyleSheet, View, type ViewStyle } from "react-native";
import { useShortcutHint, withShortcut } from "../../lib/commandShortcuts";
import { layout, useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { useActiveTabId, useTabLive, useWindowId } from "../../store/hooks";
import { usePageProgress } from "../../store/pageProgress";
import { splitOf } from "../../store/splits";
import { extensionsFitting, ToolbarExtensions, useToolbarExtensionsWidth } from "../extensions/ToolbarExtensions";
import { useHistoryAvailability } from "../layout/history";
import { toolbarPalette, type ToolbarPalette } from "../layout/toolbarColors";
import { ToolbarButton, type ButtonHit } from "../layout/controls";
import { addressBarInSidebar, setUrlAnchor, SIDEBAR_FIELD } from "../layout/windowLayout";
import { useHover } from "../primitives";
import { GLYPH, HistoryButton, ReloadButton, UrlField, useToolbarTab } from "../Toolbar";
import { ARC_LIGHTS_CENTER, HEADER_TOOLS, navButtonsFitting, type HeaderButton } from "../layout/dockMotion";
import { useNativeToolbarModel } from "../NativeToolbar";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";

const BUTTON = layout.toolbarButton;
const { toggleX: TOGGLE_X, edge: EDGE } = HEADER_TOOLS;
const LIGHTS_Y = ARC_LIGHTS_CENTER[1];
const PLATE = 32;
const PLATE_RADIUS = 6;

export function SidebarHeaderTools({ width }: { width: number }) {
  return sidebarAddressBarAvailable() ? <NativeSidebarAddressBar width={width} /> : <ReactSidebarHeaderTools width={width} />;
}

function ReactSidebarHeaderTools({ width }: { width: number }) {
  const windowId = useWindowId();
  const tab = useToolbarTab(useActiveTabId());
  const palette = toolbarPalette(useTheme(), null);
  const toggle = useBrowser((s) => s.settings.showSidebarButton !== false);
  const sidebarHint = useShortcutHint("toggleSidebar");
  const { buttons, step } = navButtonsFitting(width, BUTTON, toggle);
  const shown = tab ? buttons : [];
  const last = width - EDGE - BUTTON / 2;
  const centres = shown.map((_, i) => last - (shown.length - 1 - i) * step);
  const at = toggle ? [TOGGLE_X, ...centres] : centres;
  const place = (center: number) => ({
    style: { position: "absolute" as const, top: LIGHTS_Y - PLATE / 2, left: center - PLATE / 2 },
    hit: { width: PLATE, height: PLATE, plateX: 0, plateY: 0, box: PLATE, radius: PLATE_RADIUS },
  });
  return (
    <>
      {toggle && (
        <ToolbarButton
          {...place(at[0]!)}
          palette={palette}
          icon="sidebar.left"
          size={GLYPH}
          onPress={() => useBrowser.getState().toggleSidebar(windowId)}
          tooltip={withShortcut("Auto-Hide Tabs", sidebarHint)}
        />
      )}
      {tab ? <NavigationButtons tab={tab} palette={palette} buttons={shown} slots={at.slice(toggle ? 1 : 0).map(place)} /> : null}
    </>
  );
}

const alreadyFocused = () => {};

function NavigationButtons({
  tab,
  palette,
  buttons,
  slots,
}: {
  tab: NonNullable<ReturnType<typeof useToolbarTab>>;
  palette: ToolbarPalette;
  buttons: HeaderButton[];
  slots: { style: ViewStyle; hit: ButtonHit }[];
}) {
  const loading = useTabLive(tab.id, (l) => l.isLoading);
  const history = useHistoryAvailability(tab.id);
  return (
    <>
      {buttons.map((b, i) =>
        b === "reload" ? (
          <ReloadButton key={b} {...slots[i]!} tab={tab} loading={loading} palette={palette} onFocus={alreadyFocused} />
        ) : (
          <HistoryButton
            key={b}
            {...slots[i]!}
            tabId={tab.id}
            windowId={tab.windowId}
            direction={b === "back" ? -1 : 1}
            disabled={b === "back" ? !history.back : !history.forward}
            palette={palette}
            onFocus={alreadyFocused}
          />
        ),
      )}
    </>
  );
}

export function SidebarAddressRow({ width }: { width: number }) {
  return sidebarAddressBarAvailable() ? null : <ReactSidebarAddressRow width={width} />;
}

function ReactSidebarAddressRow({ width }: { width: number }) {
  const windowId = useWindowId();
  const tab = useToolbarTab(useActiveTabId());
  const field = useRef<View>(null);
  const anchor = () =>
    field.current?.measureInWindow((x, y, width, height) => {
      if (width && addressBarInSidebar(useBrowser.getState(), windowId)) setUrlAnchor(windowId, { left: x, top: y, width, sidebar: { height } });
    });

  return (
    <View
      ref={field}
      onLayout={anchor}
      style={{ position: "absolute", left: layout.sidebarInset, right: layout.sidebarInset, top: SIDEBAR_FIELD.top, height: SIDEBAR_FIELD.height }}
    >
      {tab?.url ? <PageField tab={tab} windowId={windowId} width={width - 2 * layout.sidebarInset} /> : <EmptyField windowId={windowId} />}
    </View>
  );
}

const HOST_ROOM = 84;

function PageField({ tab, windowId, width }: { tab: NonNullable<ReturnType<typeof useToolbarTab>>; windowId: string; width: number }) {
  const palette = toolbarPalette(useTheme(), null);
  const loading = useTabLive(tab.id, (l) => l.isLoading);
  const loaded = usePageProgress(tab.id);
  const progress = loading ? loaded : null;
  const inSplit = useBrowser((s) => !!splitOf(s, tab.id));
  const limit = extensionsFitting(width - 10 - 3 - HOST_ROOM);
  const extensionsWidth = useToolbarExtensionsWidth(windowId, limit);
  return (
    <UrlField
      tab={tab}
      palette={palette}
      windowId={windowId}
      inSplit={inSplit}
      onFocus={alreadyFocused}
      sidebar={{
        height: SIDEBAR_FIELD.height,
        progress,
        accessory: extensionsWidth ? (
          <View style={{ width: extensionsWidth - 6, height: 28 }}>
            <ToolbarExtensions tabId={tab.id} windowId={windowId} palette={palette} top={0} right={0} limit={limit} />
          </View>
        ) : null,
      }}
    />
  );
}

function EmptyField({ windowId }: { windowId: string }) {
  const theme = useTheme();
  const { hovered, hoverProps } = useHover();
  const open = () => useBrowser.getState().openPanel(windowId, "");
  return (
    <View {...hoverProps}>
      <Pressable onPress={open}>
        <View
          style={{
            height: SIDEBAR_FIELD.height,
            borderRadius: SIDEBAR_FIELD.radius,
            borderWidth: StyleSheet.hairlineWidth * 2,
            borderColor: theme.pinnedRestingStroke,
            backgroundColor: hovered ? theme.tabHover : theme.pinnedResting,
            justifyContent: "center",
            paddingLeft: 10,
          }}
        >
          <FadeLabel text="Search or enter address" fontSize={13} color={theme.placeholder} fadeWidth={14} style={{ height: 18, marginLeft: -2 }} />
        </View>
      </Pressable>
    </View>
  );
}

type AddressBarHandlers = { onClick: (c: ToolbarClick) => unknown; onAnchors: (anchors: Record<string, [number, number, number, number]>) => void };

const addressBarHandlers = new Map<string, RefObject<AddressBarHandlers>>();

addNativeSettingsHandlers({
  "sidebar.addressClick": (windowId: string, click: ToolbarClick) => {
    void addressBarHandlers.get(windowId)?.current?.onClick(click);
  },
  "sidebar.addressAnchors": (windowId: string, anchors: Record<string, [number, number, number, number]>) => {
    addressBarHandlers.get(windowId)?.current?.onAnchors(anchors);
  },
});

const noFocusHandle = () => null;
const SIDEBAR_PLATE = { box: PLATE, radius: PLATE_RADIUS };
const SIDEBAR_GEOMETRY = (toggle: boolean) => ({ sidebarButton: toggle ? 0 : null, back: 0, forward: 0, reload: 0, urlLeft: 0 });

function NativeSidebarAddressBar({ width }: { width: number }) {
  const windowId = useWindowId();
  const tabId = useActiveTabId() ?? "";
  const theme = useTheme();
  const toggle = useBrowser((s) => s.settings.showSidebarButton !== false);
  const sidebarHint = useShortcutHint("toggleSidebar");
  const extensionLimit = extensionsFitting(width - 2 * layout.sidebarInset - 10 - 3 - HOST_ROOM);
  const geometry = useMemo(() => SIDEBAR_GEOMETRY(toggle), [toggle]);
  const model = useNativeToolbarModel({ tabId, geometry, windowId, inSplit: false, focused: true, sidebar: { extensionLimit } }, noFocusHandle);
  const palette = toolbarPalette(theme, null);
  const { state } = model;
  const page = !!model.tab?.url;
  const json = useMemo(
    () =>
      JSON.stringify({
        palette: state?.palette ?? palette,
        accent: theme.accent,
        look: { resting: theme.pinnedResting, stroke: theme.pinnedRestingStroke, hover: theme.tabHover, placeholder: theme.placeholder, prompt: "Search or enter address" },
        buttons: [
          ...(toggle ? [{ id: "sidebar", icon: "sidebar.left", size: GLYPH, ...SIDEBAR_PLATE, tooltip: withShortcut("Auto-Hide Tabs", sidebarHint) }] : []),
          ...(state ? state.left.filter((b) => b.id !== "sidebar").map((b) => ({ ...b, ...SIDEBAR_PLATE })) : []),
        ],
        url: page ? state?.url ?? null : null,
        extensions: page ? state?.extensions ?? [] : [],
        progress: state?.progress ?? null,
      }),
    [state, palette, theme, toggle, sidebarHint, page],
  );
  const handlers = useRef<AddressBarHandlers>({ onClick: () => undefined, onAnchors: () => undefined });
  handlers.current = {
    onClick: (c) => {
      if (c.id === "sidebar") return useBrowser.getState().toggleSidebar(windowId);
      if (c.id === "url" && !page) return c.kind === "press" ? useBrowser.getState().openPanel(windowId, "") : undefined;
      return model.onClick(c);
    },
    onAnchors: ({ field, ...extensions }) => {
      if (field && field[2] && addressBarInSidebar(useBrowser.getState(), windowId)) setUrlAnchor(windowId, { left: field[0], top: field[1], width: field[2], sidebar: { height: field[3] } });
      model.onAnchors(extensions);
    },
  };
  useEffect(() => {
    addressBarHandlers.set(windowId, handlers);
    return () => {
      if (addressBarHandlers.get(windowId) === handlers) addressBarHandlers.delete(windowId);
    };
  }, [windowId]);
  useEffect(() => setSidebarAddressBar(windowId, json), [windowId, json]);
  useEffect(() => () => setSidebarAddressBar(windowId, null), [windowId]);
  return <NativeSidebarAddressBarView windowId={windowId} style={StyleSheet.absoluteFill} />;
}

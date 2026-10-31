import { windowShellActive } from "@solara/settings";
import { Surface, Symbol, VisualEffect } from "@solara/shell";
import { memo, useEffect, useRef, useState } from "react";
import { Animated, Easing, Pressable, StyleSheet, Text, View } from "react-native";
import { hex, useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { defaultSearchEngine } from "../../store/settings";
import { useHover } from "../primitives";
import { useWindowId } from "../../store/hooks";
import { useNativePaneHandler, useNativePaneOverlay, usePageFrame, type PaneClick } from "../layout/nativePaneOverlays";
import { searchSelection, setPageSelection, usePageSelection, type ClickModifiers, type PageSelection } from "./selection";

const HEIGHT = 32;
const GAP = 6;
const SHOW_DELAY = 150;

export const SelectionPopover = memo(function SelectionPopover({ tabId, zoom, nativeAllowed = true }: { tabId: string; zoom: number; nativeAllowed?: boolean }) {
  const theme = useTheme();
  const windowId = useWindowId();
  const [inShell] = useState(() => nativeAllowed && windowShellActive(windowId));
  const page = usePageFrame();
  const engine = useBrowser((s) => defaultSearchEngine(s.settings).name);
  const enabled = useBrowser((s) => s.settings.showSelectionSearch);
  const selection = usePageSelection((s) => (enabled ? (s[tabId] ?? null) : null));
  const [shown, setShown] = useState<PageSelection | null>(null);
  const [area, setArea] = useState({ width: 0, height: 0 });
  useEffect(() => {
    if (!selection) return setShown(null);
    const timer = setTimeout(() => setShown(selection), SHOW_DELAY);
    return () => clearTimeout(timer);
  }, [selection]);
  useEffect(() => () => setPageSelection(tabId, null), [tabId]);
  const r = shown?.rect;
  useNativePaneOverlay(inShell, windowId, tabId, "selection", shown && r && page.frame ? {
    key: `${r.x},${r.y}`,
    top: r.y * zoom,
    bottom: (r.y + r.height) * zoom,
    center: (r.x + r.width / 2) * zoom,
    dark: !!theme.dark,
    icon: theme.icon,
    textPrimary: theme.textPrimary,
    tooltip: searchTooltip(engine, shown.text),
    label: `Search ${engine}`,
    frame: page.frame,
  } : null);
  useNativePaneHandler("selection", inShell, windowId, tabId, (click: PaneClick) => shown && searchSelection(tabId, shown.text, click));
  if (!selection && !shown) return null;
  if (inShell) return <View ref={page.ref} pointerEvents="none" collapsable={false} onLayout={page.onLayout} style={StyleSheet.absoluteFill} />;

  return (
    <View pointerEvents="box-none" style={StyleSheet.absoluteFill} onLayout={(e) => setArea(e.nativeEvent.layout)}>
      {shown && area.width > 0 && <Bar key={`${shown.rect.x},${shown.rect.y}`} tabId={tabId} selection={shown} zoom={zoom} area={area} />}
    </View>
  );
});

function Bar({ tabId, selection, zoom, area }: { tabId: string; selection: PageSelection; zoom: number; area: { width: number; height: number } }) {
  const theme = useTheme();
  const [width, setWidth] = useState(0);
  const appear = useRef(new Animated.Value(0)).current;
  useEffect(() => {
    Animated.timing(appear, { toValue: 1, duration: 150, easing: Easing.out(Easing.cubic), useNativeDriver: true }).start();
  }, []);
  const r = selection.rect;
  const top = r.y * zoom;
  const bottom = (r.y + r.height) * zoom;
  if (bottom < 0 || top > area.height) return null;
  const above = top - GAP - HEIGHT >= 4;
  const y = above ? top - GAP - HEIGHT : Math.min(bottom + GAP, area.height - HEIGHT - 4);
  const center = (r.x + r.width / 2) * zoom;
  const x = Math.max(8, Math.min(center - width / 2, area.width - width - 8));

  return (
    <Animated.View
      onLayout={(e) => setWidth(e.nativeEvent.layout.width)}
      style={{
        position: "absolute",
        left: x,
        top: y,
        opacity: width ? appear : 0,
        transformOrigin: above ? "center bottom" : "center top",
        transform: [
          { scale: appear.interpolate({ inputRange: [0, 1], outputRange: [0.94, 1] }) },
          { translateY: appear.interpolate({ inputRange: [0, 1], outputRange: [above ? 3 : -3, 0] }) },
        ],
      }}
    >
      <Surface
        fill={hex(theme.dark ? "rgba(38,36,37,0.94)" : "rgba(252,251,252,0.96)")}
        cornerRadius={10}
        borderColor={hex(theme.dark ? "rgba(255,255,255,0.14)" : "rgba(0,0,0,0.12)")}
        borderWidth={0.5}
        shadowColor="#000000"
        shadowOpacity={theme.dark ? 0.45 : 0.16}
        shadowRadius={14}
        shadowOffset={[0, 6]}
        style={{ height: HEIGHT, padding: 3, flexDirection: "row", alignItems: "center" }}
      >
        <VisualEffect material="menu" cornerRadius={10} style={StyleSheet.absoluteFill} />
        <View style={{ ...StyleSheet.absoluteFillObject, borderRadius: 10, backgroundColor: theme.dark ? "rgba(38,36,37,0.72)" : "rgba(252,251,252,0.7)" }} />
        <SearchButton tabId={tabId} text={selection.text} />
      </Surface>
    </Animated.View>
  );
}

function searchTooltip(engine: string, text: string) {
  const quoted = text.length > 40 ? `${text.slice(0, 40).trimEnd()}…` : text;
  return `Search ${engine} for “${quoted.replace(/\s+/g, " ")}”`;
}

function SearchButton({ tabId, text }: { tabId: string; text: string }) {
  const theme = useTheme();
  const engine = useBrowser((s) => defaultSearchEngine(s.settings).name);
  const { hovered, hoverProps } = useHover();
  return (
    <View {...hoverProps} tooltip={searchTooltip(engine, text)}>
      <Pressable accessibilityRole="button" accessibilityLabel={`Search ${engine}`} onPress={(e) => searchSelection(tabId, text, e.nativeEvent as unknown as ClickModifiers)}>
        {({ pressed }) => (
          <View
            style={{
              height: HEIGHT - 6,
              paddingLeft: 7,
              paddingRight: 9,
              borderRadius: 7,
              flexDirection: "row",
              alignItems: "center",
              gap: 5,
              backgroundColor: pressed || hovered ? (theme.dark ? `rgba(255,255,255,${pressed ? 0.12 : 0.07})` : `rgba(0,0,0,${pressed ? 0.1 : 0.06})`) : undefined,
            }}
          >
            <Symbol name="magnifyingglass" size={12} weight="medium" color={theme.icon} style={{ width: 16, height: 16 }} />
            <Text style={{ fontSize: 13, fontWeight: "500", color: theme.textPrimary }}>Search</Text>
          </View>
        )}
      </Pressable>
    </View>
  );
}

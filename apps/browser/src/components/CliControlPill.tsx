import { Surface, Symbol } from "@ardia/shell";
import { useEffect, useRef, useState } from "react";
import { Animated, Easing, Pressable, StyleSheet, Text, View, type ViewStyle } from "react-native";
import { cliCommand, cliProduct, stopCliControl, useCliIndicator } from "../lib/cliControl";
import { hex, useTheme } from "../lib/theme";
import { windowShellActive } from "@ardia/settings";
import { useWindowId } from "../store/hooks";
import { useNativePaneOverlay } from "./layout/nativePaneOverlays";
import { mediaTheme, nativeMedia, NativeMediaView } from "./media/nativeMedia";
import { useHover } from "./primitives";

const PILL_HEIGHT = 32;
const PILL_BOTTOM = 12;
const NATIVE_HIDE_MS = 250;

type FollowStyle = Animated.WithAnimatedValue<ViewStyle>;

export function CliControlPill({ tabId, style, nativeAllowed = true }: { tabId: string; style?: FollowStyle; nativeAllowed?: boolean }) {
  const windowId = useWindowId();
  const [inShell] = useState(() => nativeAllowed && windowShellActive(windowId));
  if (!nativeMedia("media.cliPill")) return <RNCliControlPill style={style} />;
  if (inShell) return <PaneCliControlPill windowId={windowId} tabId={tabId} />;
  return <NativeCliControlPill windowId={windowId} style={style} />;
}

function useCliPillState() {
  const shown = useCliIndicator((s) => s.shown);
  const theme = useTheme();
  return { shown, command: cliCommand(), product: cliProduct(), theme: mediaTheme(theme) };
}

function useNativePillPresence(shown: boolean) {
  const [mounted, setMounted] = useState(shown);
  const [revealed, setRevealed] = useState(shown);
  useEffect(() => {
    if (shown) {
      setMounted(true);
      const frame = requestAnimationFrame(() => setRevealed(true));
      return () => cancelAnimationFrame(frame);
    }
    setRevealed(false);
    const timer = setTimeout(() => setMounted(false), NATIVE_HIDE_MS);
    return () => clearTimeout(timer);
  }, [shown]);
  return { mounted: mounted || shown, shown: shown && revealed };
}

function PaneCliControlPill({ windowId, tabId }: { windowId: string; tabId: string }) {
  const state = useCliPillState();
  const presence = useNativePillPresence(state.shown);
  useNativePaneOverlay(presence.mounted, windowId, tabId, "cliPill", { ...state, shown: presence.shown });
  return null;
}

function NativeCliControlPill({ windowId, style }: { windowId: string; style?: FollowStyle }) {
  const state = useCliPillState();
  const presence = useNativePillPresence(state.shown);
  if (!presence.mounted) return null;
  return (
    <Animated.View pointerEvents="box-none" style={[StyleSheet.absoluteFill, style]}>
      <NativeMediaView kind="media.cliPill" windowId={windowId} state={{ ...state, shown: presence.shown }} />
    </Animated.View>
  );
}

function RNCliControlPill({ style }: { style?: FollowStyle }) {
  const shown = useCliIndicator((s) => s.shown);
  const [mounted, setMounted] = useState(shown);
  const [appearAtOnce, setAppearAtOnce] = useState(shown);
  useEffect(() => {
    if (shown) setMounted(true);
  }, [shown]);
  if (!mounted && !shown) return null;
  return (
    <Animated.View pointerEvents="box-none" style={[StyleSheet.absoluteFill, style]}>
      <ShownCliControlPill
        shown={shown}
        appearAtOnce={appearAtOnce}
        onHidden={() => {
          setMounted(false);
          setAppearAtOnce(false);
        }}
      />
    </Animated.View>
  );
}

function ShownCliControlPill({ shown, appearAtOnce, onHidden }: { shown: boolean; appearAtOnce: boolean; onHidden: () => void }) {
  const theme = useTheme();
  const appear = useRef(new Animated.Value(appearAtOnce ? 1 : 0)).current;
  useEffect(() => {
    const animation = Animated.timing(
      appear,
      shown
        ? { toValue: 1, duration: 160, easing: Easing.out(Easing.cubic), useNativeDriver: true }
        : { toValue: 0, duration: 200, easing: Easing.in(Easing.quad), useNativeDriver: true },
    );
    animation.start(({ finished }) => finished && !shown && onHidden());
    return () => animation.stop();
  }, [shown]);
  return (
    <View pointerEvents="box-none" style={{ position: "absolute", left: 12, right: 12, bottom: PILL_BOTTOM, alignItems: "center" }}>
      <Animated.View
        pointerEvents={shown ? "auto" : "none"}
        style={{
          maxWidth: "100%",
          opacity: appear,
          transform: [{ translateY: appear.interpolate({ inputRange: [0, 1], outputRange: [8, 0] }) }, { scale: appear.interpolate({ inputRange: [0, 1], outputRange: [0.96, 1] }) }],
        }}
      >
        <Surface
          fill={hex(theme.panel)}
          cornerRadius={PILL_HEIGHT / 2}
          borderColor={hex(theme.panelBorder)}
          borderWidth={0.5}
          shadowColor="#000000"
          shadowOpacity={theme.panelShadowOpacity}
          shadowRadius={14}
          shadowOffset={[0, 4]}
        >
          <View
            accessibilityRole="alert"
            accessibilityLabel={`The ${cliCommand()} command is controlling ${cliProduct()}`}
            style={{ height: PILL_HEIGHT, flexDirection: "row", alignItems: "center", gap: 8, paddingLeft: 6, paddingRight: 4 }}
          >
            <View style={{ width: 20, height: 20, borderRadius: 10, backgroundColor: theme.textPrimary, alignItems: "center", justifyContent: "center" }}>
              <Symbol name="terminal.fill" size={9} weight="bold" color={theme.dark ? "#000000" : "#FFFFFF"} style={{ width: 14, height: 14 }} />
            </View>
            <Text numberOfLines={1} style={{ flexShrink: 1, fontSize: 12, color: theme.textSecondary }}>
              <Text style={{ fontWeight: "600", color: theme.textPrimary }}>{cliCommand()}</Text>
              {` is controlling ${cliProduct()}`}
            </Text>
            <StopButton />
          </View>
        </Surface>
      </Animated.View>
    </View>
  );
}

function StopButton() {
  const theme = useTheme();
  const { hovered, hoverProps } = useHover();
  return (
    <View {...hoverProps}>
      <Pressable onPress={stopCliControl} accessibilityRole="button" accessibilityLabel="Stop">
        {({ pressed }) => (
          <View
            style={{
              height: PILL_HEIGHT - 8,
              paddingHorizontal: 10,
              borderRadius: (PILL_HEIGHT - 8) / 2,
              justifyContent: "center",
              backgroundColor: pressed ? theme.toolbarPressed : hovered ? theme.toolbarHover : theme.urlPill,
            }}
          >
            <Text numberOfLines={1} style={{ fontSize: 12, fontWeight: "500", color: theme.textPrimary }}>
              Stop
            </Text>
          </View>
        )}
      </Pressable>
    </View>
  );
}

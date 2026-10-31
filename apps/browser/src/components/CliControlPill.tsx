import { useEffect, useState } from "react";
import { Animated, StyleSheet, type ViewStyle } from "react-native";
import { cliCommand, cliProduct, useCliIndicator } from "../lib/cliControl";
import { useTheme } from "../lib/theme";
import { windowShellActive } from "@solara/settings";
import { useWindowId } from "../store/hooks";
import { useNativePaneOverlay } from "./layout/nativePaneOverlays";
import { mediaTheme, NativeMediaView } from "./media/nativeMedia";

const NATIVE_HIDE_MS = 250;

type FollowStyle = Animated.WithAnimatedValue<ViewStyle>;

export function CliControlPill({ tabId, style, nativeAllowed = true }: { tabId: string; style?: FollowStyle; nativeAllowed?: boolean }) {
  const windowId = useWindowId();
  const [inShell] = useState(() => nativeAllowed && windowShellActive(windowId));
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

import { nativeCliIndicatorShown, SolaraHostedView } from "@ardia/settings";
import { StyleSheet, type StyleProp, type ViewStyle } from "react-native";
import { toggleMute } from "../../lib/actions";
import { stopCliControl, useCliIndicator } from "../../lib/cliControl";
import type { Theme } from "../../lib/theme";
import type { Tab } from "../../store/types";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import { hasTrackControls, hostOf, mediaCommand, seekTo, skip, useMedia, type Session } from "./state";

export type NativeMediaKind = "media.cliPill" | "media.sidebarPlayer" | "media.hoverPlayer" | "media.shareBar" | "media.castPicker" | "media.sharePicker" | "littleSolara.bar";

const THEME_KEYS = [
  "panel",
  "panelBorder",
  "textPrimary",
  "textSecondary",
  "textTertiary",
  "placeholder",
  "icon",
  "accent",
  "rowHover",
  "toolbarHover",
  "toolbarPressed",
  "urlPill",
  "goButton",
  "goButtonText",
] as const;

export function mediaTheme(theme: Theme, extra?: Record<string, string>) {
  const colors: Record<string, string> = { ...extra };
  for (const key of THEME_KEYS) colors[key] = theme[key];
  return { dark: theme.dark, colors, panelShadowOpacity: theme.panelShadowOpacity };
}

export function NativeMediaView({ kind, windowId, state, style }: { kind: NativeMediaKind; windowId: string; state: unknown; style?: StyleProp<ViewStyle> }) {
  return <SolaraHostedView kind={kind} windowId={windowId} state={JSON.stringify(state)} pointerEvents="box-none" style={style ?? StyleSheet.absoluteFill} />;
}

export function playerState(session: Session, tab: Tab, artwork: string | null, theme: ReturnType<typeof mediaTheme>, subtitle = session.artist || hostOf(tab.url)) {
  return {
    tabId: tab.id,
    title: session.title || tab.title,
    subtitle,
    muted: tab.muted,
    playbackState: session.playbackState,
    position: session.position,
    timestamp: session.timestamp,
    playbackRate: session.playbackRate || 1,
    duration: session.duration ?? null,
    tracks: hasTrackControls(session),
    artwork,
    url: tab.url,
    favicon: tab.favicon,
    profileId: tab.profileId,
    theme,
  };
}

export function runPlayerAction(tabId: string, extra: Record<string, unknown>, backToTab: () => void) {
  const session = useMedia.getState().sessions[tabId];
  const seconds = typeof extra.seconds === "number" ? extra.seconds : 0;
  switch (extra.action) {
    case "backToTab":
      return backToTab();
    case "toggle":
      return mediaCommand(tabId, "toggle");
    case "previous":
      return mediaCommand(tabId, "previous");
    case "next":
      return mediaCommand(tabId, "next");
    case "skip":
      return session ? skip(tabId, session, seconds) : undefined;
    case "seek":
      return session ? seekTo(tabId, session, seconds) : undefined;
    case "toggleMute":
      return toggleMute(tabId);
    case "dismiss":
      return useMedia.setState((m) => ({ dismissed: { ...m.dismissed, [tabId]: true } }));
  }
}

type MediaActionHandler = (windowId: string, tabId: string, extra: Record<string, unknown>) => unknown;

const actions: Record<string, MediaActionHandler> = {
  cliStop: () => stopCliControl(),
  cliIndicator: (_windowId, _tabId, extra) => useCliIndicator.setState({ shown: extra.shown === true }),
};

const cliShownAtLoad = nativeCliIndicatorShown();
if (cliShownAtLoad !== null) useCliIndicator.setState({ shown: cliShownAtLoad });

export type PickerHandler = (extra: Record<string, unknown>) => void;
export type PickerHandlers = Record<string, PickerHandler[]>;

export function addPickerHandler(handlers: PickerHandlers, tabId: string, handler: PickerHandler) {
  (handlers[tabId] ??= []).push(handler);
  return () => {
    const left = (handlers[tabId] ?? []).filter((h) => h !== handler);
    if (left.length) handlers[tabId] = left;
    else delete handlers[tabId];
  };
}

export function callPickerHandler(handlers: PickerHandlers, tabId: string, extra: Record<string, unknown>) {
  handlers[tabId]?.at(-1)?.(extra);
}

export function addMediaActions(added: Record<string, MediaActionHandler>) {
  Object.assign(actions, added);
}


addNativeSettingsHandlers({
  "media.action": (windowId: string, name: string, tabId: string, extra: Record<string, unknown>) => actions[name]?.(windowId, tabId, extra ?? {}),
});

if (__DEV__) (globalThis as { acNativeMedia?: unknown }).acNativeMedia = { actions };

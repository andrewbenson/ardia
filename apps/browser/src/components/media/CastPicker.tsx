import { CastMode, preferredCastMode, startCasting, stopCasting, type CastDialog, type CastSink } from "@ardia/ardiacore";
import { openExternalURL, showMenu } from "@ardia/shell";
import { useEffect, useRef, useState } from "react";
import { windowShellActive } from "@ardia/settings";
import { useTheme, type Theme } from "../../lib/theme";
import { useNativePaneOverlay } from "../layout/nativePaneOverlays";
import { POPOVER_MARGIN } from "../layout/controls";
import { closeCastPicker, useCast } from "./cast";
import { PRODUCT } from "../../lib/productName";
import { useWindowId } from "../../store/hooks";
import { addMediaActions, addPickerHandler, callPickerHandler, mediaTheme, NativeMediaView, type PickerHandlers } from "./nativeMedia";

const WIDTH = 340;

const SINK_ICON: Record<number, string> = { 0: "tv", 1: "hifispeaker.2", 2: "hifispeaker", 6: "display", 7: "tv" };

const LOCAL_NETWORK_SETTINGS = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork";

const castHandlers: PickerHandlers = {};
addMediaActions({ castPicker: (_windowId, tabId, extra) => callPickerHandler(castHandlers, tabId, extra) });

const castModeFor = (sink: CastSink, screen: boolean) =>
  screen && sink.modes & CastMode.screen ? CastMode.screen : preferredCastMode(sink.modes & ~CastMode.screen) || preferredCastMode(sink.modes);

const pickSource = async (screen: boolean) => {
  const choice = await showMenu([
    { id: "tab", title: "Cast Tab", checked: !screen },
    { id: "screen", title: "Cast Screen", checked: screen },
  ]);
  return choice ? choice === "screen" : null;
};

export function CastPicker({ tabId, paneWidth, nativeAllowed = true }: { tabId: string; paneWidth: number; nativeAllowed?: boolean }) {
  const theme = useTheme();
  const windowId = useWindowId();
  const [inShell] = useState(() => nativeAllowed && windowShellActive(windowId));
  const dialog = useCast((c) => c.dialogs[tabId]);
  const [screen, setScreen] = useState(false);
  useEffect(() => setScreen(false), [dialog?.id]);
  const handler = useRef<(extra: Record<string, unknown>) => void>(() => {});
  useEffect(() => {
    return addPickerHandler(castHandlers, tabId, (extra) => handler.current(extra));
  }, [tabId]);
  const state = dialog ? castPickerState(tabId, dialog, screen, theme, paneWidth) : null;
  useNativePaneOverlay(inShell, windowId, tabId, "castPicker", state);
  if (!dialog || !state) return null;
  const close = () => closeCastPicker(tabId);
  const available = dialog.sinks.filter((s) => s.state !== "unavailable");
  handler.current = (extra) => {
    const sink = available.find((s) => s.id === extra.sinkId);
    switch (extra.action) {
      case "cast": {
        const mode = sink && castModeFor(sink, screen);
        return sink && mode ? void startCasting(dialog.id, sink.id, mode) : undefined;
      }
      case "stop":
        return sink ? void stopCasting(dialog.id, sink.routeId) : undefined;
      case "source":
        return void pickSource(screen).then((next) => next !== null && setScreen(next));
      case "link":
        return void openExternalURL(LOCAL_NETWORK_SETTINGS);
      case "done":
      case "dismiss":
        return close();
    }
  };
  if (inShell) return null;
  return <NativeMediaView key={dialog.id} kind="media.castPicker" windowId={windowId} state={state} />;
}

function castPickerState(tabId: string, dialog: CastDialog, screen: boolean, theme: Theme, paneWidth: number) {
  const available = dialog.sinks.filter((s) => s.state !== "unavailable");
  return {
    dialogId: dialog.id,
    tabId,
    title: screen ? "Cast screen" : dialog.header || "Cast tab",
    canScreen: dialog.sinks.some((s) => s.modes & CastMode.screen),
    rejected: !!dialog.permissionRejected,
    rejectedText: `${PRODUCT} needs Local Network access to find Cast devices.`,
    sinks: available.map((sink) => ({
      id: sink.id,
      name: sink.name,
      icon: SINK_ICON[sink.icon] ?? "tv",
      detail: sink.issue || sink.status || null,
      issue: !!sink.issue,
      active: sink.state === "connected" && !!sink.routeId,
      busy: sink.state === "connecting" || sink.state === "disconnecting",
    })),
    theme: mediaTheme(theme),
    popover: { width: Math.min(WIDTH, paneWidth - 24), top: POPOVER_MARGIN, right: POPOVER_MARGIN },
  };
}

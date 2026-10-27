import { CastMode, preferredCastMode, startCasting, stopCasting, type CastSink } from "@ardia/ardiacore";
import { openExternalURL, showMenu, Symbol } from "@ardia/shell";
import { useEffect, useRef, useState } from "react";
import { ActivityIndicator, Pressable, ScrollView, Text, View } from "react-native";
import { useTheme } from "../../lib/theme";
import { PANEL, PanelHeader, Popover, POPOVER_MARGIN, PopoverValue, PromptButton } from "../layout/controls";
import { useHover } from "../primitives";
import { closeCastPicker, useCast } from "./cast";
import { PRODUCT } from "../../lib/productName";
import { useWindowId } from "../../store/hooks";
import { addMediaActions, mediaTheme, nativeMedia, NativeMediaView } from "./nativeMedia";

const WIDTH = 340;

const SINK_ICON: Record<number, string> = { 0: "tv", 1: "hifispeaker.2", 2: "hifispeaker", 6: "display", 7: "tv" };

const LOCAL_NETWORK_SETTINGS = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork";
const NATIVE_HEIGHT_GUESS = 120;

const castHandlers: Record<string, (extra: Record<string, unknown>) => void> = {};
addMediaActions({ castPicker: (_windowId, tabId, extra) => castHandlers[tabId]?.(extra) });

const castModeFor = (sink: CastSink, screen: boolean) =>
  screen && sink.modes & CastMode.screen ? CastMode.screen : preferredCastMode(sink.modes & ~CastMode.screen) || preferredCastMode(sink.modes);

const pickSource = async (screen: boolean) => {
  const choice = await showMenu([
    { id: "tab", title: "Cast Tab", checked: !screen },
    { id: "screen", title: "Cast Screen", checked: screen },
  ]);
  return choice ? choice === "screen" : null;
};

export function CastPicker(props: { tabId: string; paneWidth: number }) {
  return nativeMedia("media.castPicker") ? <NativeCastPicker {...props} /> : <RNCastPicker {...props} />;
}

function NativeCastPicker({ tabId, paneWidth }: { tabId: string; paneWidth: number }) {
  const theme = useTheme();
  const windowId = useWindowId();
  const dialog = useCast((c) => c.dialogs[tabId]);
  const [screen, setScreen] = useState(false);
  const [height, setHeight] = useState(NATIVE_HEIGHT_GUESS);
  useEffect(() => setScreen(false), [dialog?.id]);
  const handler = useRef<(extra: Record<string, unknown>) => void>(() => {});
  useEffect(() => {
    castHandlers[tabId] = (extra) => handler.current(extra);
    return () => void delete castHandlers[tabId];
  }, [tabId]);
  if (!dialog) return null;
  const close = () => closeCastPicker(tabId);
  const available = dialog.sinks.filter((s) => s.state !== "unavailable");
  handler.current = (extra) => {
    const sink = available.find((s) => s.id === extra.sinkId);
    switch (extra.action) {
      case "height":
        return typeof extra.height === "number" && setHeight(extra.height);
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
        return close();
    }
  };
  const state = {
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
  };
  return (
    <Popover key={dialog.id} width={Math.min(WIDTH, paneWidth - 24)} top={POPOVER_MARGIN} right={POPOVER_MARGIN} onDismiss={close}>
      <View style={{ height }}>
        <NativeMediaView kind="media.castPicker" windowId={windowId} state={state} />
      </View>
    </Popover>
  );
}

function RNCastPicker({ tabId, paneWidth }: { tabId: string; paneWidth: number }) {
  const theme = useTheme();
  const dialog = useCast((c) => c.dialogs[tabId]);
  const [screen, setScreen] = useState(false);
  useEffect(() => setScreen(false), [dialog?.id]);
  if (!dialog) return null;
  const close = () => closeCastPicker(tabId);
  const available = dialog.sinks.filter((s) => s.state !== "unavailable");
  const canScreen = dialog.sinks.some((s) => s.modes & CastMode.screen);
  const width = Math.min(WIDTH, paneWidth - 24);
  const cast = (sink: CastSink) => {
    const mode = castModeFor(sink, screen);
    if (mode) void startCasting(dialog.id, sink.id, mode);
  };

  return (
    <Popover key={dialog.id} width={width} top={POPOVER_MARGIN} right={POPOVER_MARGIN} onDismiss={close}>
      <View style={{ paddingBottom: PANEL.inset }}>
        <PanelHeader
          icon={<Symbol name="tv.and.mediabox" size={14} color={theme.icon} style={{ width: PANEL.iconSlot, height: PANEL.iconSlot }} />}
          title={screen ? "Cast screen" : dialog.header || "Cast tab"}
          accessory={canScreen ? <SourceButton screen={screen} onChange={setScreen} /> : null}
        />

        {dialog.permissionRejected ? (
          <Message
            text={`${PRODUCT} needs Local Network access to find Cast devices.`}
            link="Open Local Network Settings"
            onLink={() => void openExternalURL(LOCAL_NETWORK_SETTINGS)}
          />
        ) : available.length ? (
          <ScrollView style={{ maxHeight: 280 }} contentContainerStyle={{ paddingHorizontal: PANEL.rowInset, gap: 2 }}>
            {available.map((sink) => (
              <SinkRow key={sink.id} sink={sink} onCast={() => cast(sink)} onStop={() => void stopCasting(dialog.id, sink.routeId)} />
            ))}
          </ScrollView>
        ) : (
          <View style={{ flexDirection: "row", alignItems: "center", gap: 8, paddingHorizontal: PANEL.inset, paddingTop: 4, paddingBottom: 4 }}>
            <ActivityIndicator size="small" style={{ transform: [{ scale: 0.6 }], width: 14, height: 14 }} />
            <Text style={{ flex: 1, fontSize: 12, color: theme.textSecondary }}>
              Looking for devices… Cast devices need to be on the same Wi‑Fi network as this Mac.
            </Text>
          </View>
        )}

        <View style={{ flexDirection: "row", justifyContent: "flex-end", paddingHorizontal: PANEL.inset, marginTop: 10 }}>
          <PromptButton title="Done" onPress={close} />
        </View>
      </View>
    </Popover>
  );
}

function SinkRow({ sink, onCast, onStop }: { sink: CastSink; onCast(): void; onStop(): void }) {
  const theme = useTheme();
  const { hovered, hoverProps } = useHover();
  const active = sink.state === "connected" && !!sink.routeId;
  const busy = sink.state === "connecting" || sink.state === "disconnecting";
  return (
    <View {...hoverProps}>
      <Pressable onPress={active || busy ? undefined : onCast}>
        <View style={{ minHeight: 42, borderRadius: PANEL.rowRadius, flexDirection: "row", alignItems: "center", gap: PANEL.iconGap, paddingHorizontal: PANEL.rowPadding, paddingVertical: 5, backgroundColor: hovered && !active ? theme.rowHover : undefined }}>
          <View style={{ width: 28, height: 28, borderRadius: 7, alignItems: "center", justifyContent: "center", backgroundColor: active ? theme.accent : theme.dark ? "rgba(255,255,255,0.08)" : "rgba(0,0,0,0.05)" }}>
            <Symbol name={SINK_ICON[sink.icon] ?? "tv"} size={13} color={active ? "#FFFFFF" : theme.icon} style={{ width: 20, height: 20 }} />
          </View>
          <View style={{ flex: 1 }}>
            <Text numberOfLines={1} style={{ fontSize: 13, color: theme.textPrimary }}>
              {sink.name}
            </Text>
            {sink.issue || sink.status ? (
              <Text numberOfLines={1} style={{ fontSize: 11.5, color: sink.issue ? "#FF453A" : theme.textSecondary }}>
                {sink.issue || sink.status}
              </Text>
            ) : null}
          </View>
          {busy ? <ActivityIndicator size="small" style={{ transform: [{ scale: 0.6 }], width: 16, height: 16 }} /> : null}
          {active ? <PromptButton title="Stop" onPress={onStop} /> : null}
        </View>
      </Pressable>
    </View>
  );
}

function SourceButton({ screen, onChange }: { screen: boolean; onChange: (screen: boolean) => void }) {
  const pick = async () => {
    const next = await pickSource(screen);
    if (next !== null) onChange(next);
  };
  return <PopoverValue title="Sources" chevron="chevron.down" tooltip="Source" onPress={() => void pick()} />;
}

function Message({ text, link, onLink }: { text: string; link: string; onLink: () => void }) {
  const theme = useTheme();
  const { hovered, hoverProps } = useHover();
  return (
    <View style={{ paddingHorizontal: PANEL.inset, paddingTop: 4, gap: 5 }}>
      <Text style={{ fontSize: 12.5, color: theme.textSecondary }}>{text}</Text>
      <View {...hoverProps}>
        <Pressable onPress={onLink}>
          <Text style={{ fontSize: 12, fontWeight: "500", color: theme.accent, textDecorationLine: hovered ? "underline" : "none" }}>{link}</Text>
        </Pressable>
      </View>
    </View>
  );
}

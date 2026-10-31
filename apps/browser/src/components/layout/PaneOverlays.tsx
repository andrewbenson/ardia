import { SolaraHostedView, windowShellActive } from "@solara/settings";
import { Surface, Symbol } from "@solara/shell";
import { memo, useState } from "react";
import { StyleSheet, Text, View } from "react-native";
import { hex, useTheme } from "../../lib/theme";
import { webviews } from "../../lib/webviews";
import { PromptButton } from "./controls";
import { patchPage, usePage } from "./pageState";
import { useNativeSadTab, usePageFrame } from "./nativePaneOverlays";
import { useWindowId } from "../../store/hooks";

export function StatusBubble({ tabId, windowId }: { tabId: string; windowId: string }) {
  const dark = useTheme().dark;
  const text = usePage(tabId, (p) => p.status);
  const state = JSON.stringify({ text, dark });
  return <SolaraHostedView kind="statusBubble" windowId={windowId} state={state} pointerEvents="none" style={StyleSheet.absoluteFill} />;
}

export const SadTab = memo(function SadTab({ tabId, nativeAllowed = true }: { tabId: string; nativeAllowed?: boolean }) {
  const theme = useTheme();
  const windowId = useWindowId();
  const [native] = useState(() => nativeAllowed && windowShellActive(windowId));
  const crashed = usePage(tabId, (p) => !!p.crashed);
  const unresponsive = usePage(tabId, (p) => p.unresponsive);
  const mode = crashed ? "crashed" : unresponsive ? "unresponsive" : null;
  const { frame, ref, onLayout } = usePageFrame();
  useNativeSadTab(native, windowId, tabId, mode, frame, theme);
  if (native) return mode ? <View ref={ref} pointerEvents="none" collapsable={false} onLayout={onLayout} style={StyleSheet.absoluteFill} /> : null;
  if (crashed) {
    return (
      <View style={[StyleSheet.absoluteFill, { backgroundColor: theme.dark ? "#1C1A1B" : "#F6F5F6", alignItems: "center", justifyContent: "center", padding: 24 }]}>
        <Symbol name="exclamationmark.triangle" size={30} weight="light" color={theme.textSecondary} style={{ width: 44, height: 40, marginBottom: 14 }} />
        <Text style={{ fontSize: 17, fontWeight: "600", color: theme.textPrimary, marginBottom: 6 }}>This tab needs to reload</Text>
        <Text style={{ fontSize: 13, color: theme.textSecondary, textAlign: "center", maxWidth: 340, marginBottom: 18 }}>
          Something went wrong with this tab. Reloading often fixes it.
        </Text>
        <PromptButton
          title="Reload"
          primary
          onPress={() => {
            patchPage(tabId, { crashed: null });
            void webviews.get(tabId)?.reload();
          }}
        />
      </View>
    );
  }
  if (!unresponsive) return null;
  return (
    <View style={[StyleSheet.absoluteFill, { alignItems: "center", justifyContent: "center", backgroundColor: theme.dark ? "rgba(0,0,0,0.35)" : "rgba(0,0,0,0.12)" }]}>
      <Surface
        fill={hex(theme.panel)}
        cornerRadius={14}
        borderColor={hex(theme.panelBorder)}
        borderWidth={0.5}
        shadowColor="#000000"
        shadowOpacity={theme.panelShadowOpacity}
        shadowRadius={20}
        shadowOffset={[0, 8]}
        style={{ width: 320, padding: 18, gap: 6 }}
      >
        <Text style={{ fontSize: 14, fontWeight: "600", color: theme.textPrimary }}>Page Unresponsive</Text>
        <Text style={{ fontSize: 12, color: theme.textSecondary, marginBottom: 10 }}>You can wait for it to become responsive or exit the page.</Text>
        <View style={{ flexDirection: "row", justifyContent: "flex-end", gap: 8 }}>
          <PromptButton
            title="Exit Page"
            onPress={() => {
              patchPage(tabId, { unresponsive: false });
              void webviews.get(tabId)?.resolveUnresponsive(true);
            }}
          />
          <PromptButton
            title="Wait"
            primary
            onPress={() => {
              patchPage(tabId, { unresponsive: false });
              void webviews.get(tabId)?.resolveUnresponsive(false);
            }}
          />
        </View>
      </Surface>
    </View>
  );
});

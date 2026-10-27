import { Surface } from "@ardia/shell";
import { View } from "react-native";
import { hex, layout, useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { clickTab } from "../sidebar/actions";
import { cardHoverProps, dismissHover } from "../sidebar/hover";
import { hoverCardOrigin } from "../sidebar/hoverMotion";
import { measureRow, setSidebarUi, type Anchor } from "../sidebar/state";
import { useSidebarWidth } from "../sidebar/tokens";
import { MINI_PLAYER_HEIGHT, MINI_PLAYER_WIDTH, MiniPlayer } from "./MiniPlayer";
import { useArtwork } from "./artwork";
import { addMediaActions, mediaTheme, nativeMedia, NativeMediaView, playerState, runPlayerAction } from "./nativeMedia";
import { useMedia, useSession } from "./state";
import { useTab } from "../../store/hooks";
import { useMediaTokens } from "./tokens";

export function useShowsMiniPlayer(tabId: string | undefined): boolean {
  const pinned = useBrowser((s) => !!tabId && !!s.tabs[tabId]?.pinned && s.settings.sidebarMediaControls);
  const hasSession = useMedia((s) => {
    const session = tabId ? s.sessions[tabId] : undefined;
    return !!session && session.controllable && session.playbackState !== "none" && !!(session.title || session.artwork);
  });
  return pinned && hasSession;
}

export function usePlayerEdge(windowId: string, anchor: Anchor | undefined): number {
  const sidebarWidth = useSidebarWidth(windowId);
  return anchor ? Math.max(anchor.x + anchor.width, sidebarWidth - layout.sidebarInset) : 0;
}

export function HoverPlayer(props: { tabId: string; windowId: string; anchor: Anchor }) {
  return nativeMedia("media.hoverPlayer") ? <NativeHoverPlayer {...props} /> : <RNHoverPlayer {...props} />;
}

addMediaActions({
  hoverPlayer: (windowId, tabId, extra) =>
    runPlayerAction(tabId, extra, () => {
      dismissHover();
      clickTab(windowId, tabId);
    }),
});

function NativeHoverPlayer({ tabId, windowId, anchor }: { tabId: string; windowId: string; anchor: Anchor }) {
  const theme = useTheme();
  const edge = usePlayerEdge(windowId, anchor);
  const session = useSession(tabId);
  const tab = useTab(tabId);
  const artwork = useArtwork(tabId, session?.artwork);
  if (!session || !tab) return null;
  return (
    <View {...cardHoverProps} style={{ position: "absolute", ...hoverCardOrigin(anchor, edge), width: MINI_PLAYER_WIDTH, height: MINI_PLAYER_HEIGHT }}>
      <NativeMediaView kind="media.hoverPlayer" windowId={windowId} state={playerState(session, tab, artwork, mediaTheme(theme))} />
    </View>
  );
}

function RNHoverPlayer({ tabId, windowId, anchor }: { tabId: string; windowId: string; anchor: Anchor }) {
  const theme = useTheme();
  const tokens = useMediaTokens();
  const edge = usePlayerEdge(windowId, anchor);
  return (
    <Surface
      {...cardHoverProps}
      fill={tokens.background}
      cornerRadius={12}
      borderColor={hex(tokens.border)}
      borderWidth={0.5}
      shadowColor="#000000"
      shadowOpacity={theme.panelShadowOpacity * 0.8}
      shadowRadius={16}
      shadowOffset={[0, 6]}
      style={{ position: "absolute", ...hoverCardOrigin(anchor, edge), width: MINI_PLAYER_WIDTH, height: MINI_PLAYER_HEIGHT }}
    >
      <MiniPlayer
        tabId={tabId}
        onBackToTab={() => {
          dismissHover();
          clickTab(windowId, tabId);
        }}
      />
    </Surface>
  );
}

if (__DEV__) {
  (globalThis as { acMediaHover?: unknown }).acMediaHover = async (windowId: string, tabId: string | null) => {
    if (!tabId) return setSidebarUi({ hover: null });
    const anchor = await measureRow(windowId, tabId);
    if (anchor) setSidebarUi({ hover: { windowId, kind: "tab", id: tabId, anchor } });
    return anchor;
  };
}

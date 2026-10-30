import { View } from "react-native";
import { layout, useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { clickTab } from "../sidebar/actions";
import { cardHoverProps, dismissHover } from "../sidebar/hover";
import { hoverCardOrigin } from "../sidebar/hoverMotion";
import { measureRow, setSidebarUi, type Anchor } from "../sidebar/state";
import { useSidebarWidth } from "../sidebar/tokens";
import { useArtwork } from "./artwork";
import { addMediaActions, mediaTheme, NativeMediaView, playerState, runPlayerAction } from "./nativeMedia";
import { useMedia, useSession } from "./state";
import { useTab } from "../../store/hooks";
const MINI_PLAYER_WIDTH = 320;
const MINI_PLAYER_HEIGHT = 76;

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

addMediaActions({
  hoverPlayer: (windowId, tabId, extra) =>
    runPlayerAction(tabId, extra, () => {
      dismissHover();
      clickTab(windowId, tabId);
    }),
});

export function HoverPlayer({ tabId, windowId, anchor }: { tabId: string; windowId: string; anchor: Anchor }) {
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

if (__DEV__) {
  (globalThis as { acMediaHover?: unknown }).acMediaHover = async (windowId: string, tabId: string | null) => {
    if (!tabId) return setSidebarUi({ hover: null });
    const anchor = await measureRow(windowId, tabId);
    if (anchor) setSidebarUi({ hover: { windowId, kind: "tab", id: tabId, anchor } });
    return anchor;
  };
}

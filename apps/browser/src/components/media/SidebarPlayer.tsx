import { useShallow } from "zustand/react/shallow";
import { useRef } from "react";
import { switchToTab } from "../../lib/actions";
import { hex, useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { useTab, useWindowId } from "../../store/hooks";
import { useSidebarTokens } from "../sidebar/tokens";
import { useArtwork } from "./artwork";
import { isTabShown, playerTabFor, useMedia, useSession } from "./state";
import { addMediaActions, mediaTheme, NativeMediaView, playerState, runPlayerAction } from "./nativeMedia";

export const SIDEBAR_PLAYER_HEIGHT = 74 + 8;

const NO_IDS: string[] = [];

export function useSidebarPlayerTab(windowId: string, profileId: string): string | undefined {
  const sessions = useMedia(useShallow((m) => Object.keys(m.sessions)));
  const hidden = useBrowser(
    useShallow((s) => {
      const w = s.windows[windowId];
      if (!sessions.length || !w || !s.settings.sidebarMediaControls) return NO_IDS;
      const ids = sessions.filter((id) => s.tabs[id]?.windowId === windowId && s.tabs[id]!.profileId === profileId && !isTabShown(s, id, profileId));
      return ids.length > 1 ? ids.sort((a, b) => w.tabIds.indexOf(a) - w.tabIds.indexOf(b)) : ids;
    }),
  );
  const shown = useRef<string | undefined>(undefined);
  shown.current = useMedia((m) => playerTabFor(m, hidden, shown.current));
  return shown.current;
}

addMediaActions({ sidebarPlayer: (_windowId, tabId, extra) => runPlayerAction(tabId, extra, () => switchToTab(tabId)) });

export function SidebarPlayer({ tabId }: { tabId: string }) {
  const theme = useTheme();
  const tokens = useSidebarTokens();
  const windowId = useWindowId();
  const session = useSession(tabId);
  const tab = useTab(tabId);
  const artwork = useArtwork(tabId, session?.artwork);
  if (!session || !tab) return null;
  const look = mediaTheme(theme, { groupFill: hex(tokens.groupFill), groupStroke: hex(tokens.groupStroke) });
  return <NativeMediaView kind="media.sidebarPlayer" windowId={windowId} state={playerState(session, tab, artwork, look)} style={{ height: SIDEBAR_PLAYER_HEIGHT - 8 }} />;
}

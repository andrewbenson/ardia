import { NativePage, type NativePageEvent } from "@ardia/settings";
import { confirm } from "@ardia/shell";
import { useEffect, useState } from "react";
import { StyleSheet } from "react-native";
import { useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { engineProfile, profileFor } from "../../store/model";
import { openUrl } from "../bookmarks/actions";
import { clearDataFor, useClearDataRequest, type ClearRange } from "./ClearDataDialog";
import { pageThemeState } from "./nativePageTheme";

type OpenMode = Parameters<typeof openUrl>[2];

export function NativeHistoryPage({ tabId, profileId, initialQuery }: { tabId: string; profileId: string; initialQuery: string }) {
  const theme = useTheme();
  const windowId = useBrowser((s) => s.tabs[tabId]?.windowId ?? "");
  const historyEngine = useBrowser(() => engineProfile(profileId));
  const profileName = useBrowser((s) => (s.profileOrder.length > 1 ? profileFor(s, profileId).name : null));
  const [selectionReset, setSelectionReset] = useState(0);
  const [clearRequest, setClearRequest] = useState(0);
  const [clearDone, setClearDone] = useState(0);

  const request = useClearDataRequest((r) => r.windowId);
  const activeHere = useBrowser((s) => s.windows[windowId]?.activeTabIds[s.windows[windowId]!.profileId] === tabId);
  useEffect(() => {
    if (request === windowId && activeHere) {
      setClearRequest((n) => n + 1);
      useClearDataRequest.getState().request(null);
    }
  }, [request, activeHere]);

  const state = JSON.stringify({ ...pageThemeState(theme), profileId, engineProfile: historyEngine, profileName, initialQuery, selectionReset, clearRequest, clearDone });

  const onEvent = async (e: NativePageEvent) => {
    if (e.kind === "open") return openUrl(String(e.url), windowId, e.mode as OpenMode);
    if (e.kind === "remove") return useBrowser.getState().removeHistory(profileId, e.urls as string[]);
    if (e.kind === "deleteSelected") {
      const { confirmed } = await confirm({
        title: "Remove selected items?",
        message: "Are you sure you want to delete these pages from your history?",
        confirmTitle: "Remove",
        destructive: true,
        windowId,
      });
      if (!confirmed) return;
      useBrowser.getState().removeHistory(profileId, e.urls as string[]);
      setSelectionReset((n) => n + 1);
      return;
    }
    if (e.kind === "clearData") {
      await clearDataFor(profileId, e.range as ClearRange, !!e.history, !!e.siteData);
      setClearDone((n) => n + 1);
    }
  };
  return <NativePage kind="history" state={state} style={StyleSheet.absoluteFill} onPageEvent={(e) => void onEvent(e.nativeEvent)} />;
}

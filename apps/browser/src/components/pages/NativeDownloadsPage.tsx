import { cancelDownload, keepDownload, pauseDownload, resumeDownload } from "@ardia/ardiacore";
import { NativePage, type NativePageEvent } from "@ardia/settings";
import { openFile, revealFile } from "@ardia/shell";
import { StyleSheet } from "react-native";
import { useShallow } from "zustand/react/shallow";
import { useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { downloadsIn } from "../../store/ui";
import { openUrl } from "../bookmarks/actions";
import { downloadMenu } from "../Downloads";
import { pageThemeState } from "./nativePageTheme";

export function NativeDownloadsPage({ tabId }: { tabId: string }) {
  const theme = useTheme();
  const windowId = useBrowser((s) => s.tabs[tabId]?.windowId ?? "");
  const downloads = useBrowser(useShallow((s) => downloadsIn(s, windowId)));
  const state = JSON.stringify({
    ...pageThemeState(theme),
    downloads: downloads.map((d) => ({ id: d.id, url: d.url, filename: d.filename, path: d.path, state: d.state, received: d.received, total: d.total, speed: d.speed, paused: !!d.paused, dangerous: !!d.dangerous })),
  });
  const onEvent = (e: NativePageEvent) => {
    const s = useBrowser.getState();
    if (e.kind === "clearAll") return s.clearDownloads(windowId);
    const d = s.downloads.find((x) => x.id === e.id);
    if (!d) return;
    if (e.kind === "open") void openFile(d.path);
    else if (e.kind === "reveal") void revealFile(d.path);
    else if (e.kind === "pause") void pauseDownload(d.id);
    else if (e.kind === "resume") void resumeDownload(d.id);
    else if (e.kind === "keep") void keepDownload(d.id);
    else if (e.kind === "cancel") void cancelDownload(d.id);
    else if (e.kind === "menu") void downloadMenu(d, windowId);
    else if (e.kind === "remove") s.removeDownload(d.id);
    else if (e.kind === "source") openUrl(d.url, windowId, "foreground");
  };
  return <NativePage kind="downloads" state={state} style={StyleSheet.absoluteFill} onPageEvent={(e) => onEvent(e.nativeEvent)} />;
}

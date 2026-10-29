import { NativePage, type NativePageEvent } from "@ardia/settings";
import { useEffect, useMemo, useState } from "react";
import { StyleSheet } from "react-native";
import { addFolderToSidebar, makesGroup, restorableArcHolder, restoreArcFolders } from "../../lib/bookmarkGroups";
import { useTheme } from "../../lib/theme";
import type { RemovedBookmarks } from "../../store/bookmarks";
import { useBrowser } from "../../store/browser";
import { engineProfile } from "../../store/model";
import type { BookmarkNode } from "../../store/types";
import { openFolder, openUrl } from "../bookmarks/actions";
import { editBookmark } from "../bookmarks/edit";
import { openImport } from "../settings/windows";
import { pageThemeState } from "./nativePageTheme";

type OpenMode = Parameters<typeof openUrl>[2];
type Bookmarks = ReturnType<typeof useBrowser.getState>["bookmarks"];

function profileNodes(b: Bookmarks, roots: { bar: string; other: string } | undefined) {
  const folders: string[] = [];
  const bookmarkIcons: Record<string, string> = {};
  const walk = (id: string, depth: number) => {
    const node: BookmarkNode | undefined = b.nodes[id];
    if (!node || depth > 64) return;
    if (node.kind === "folder") {
      folders.push(node.id);
      node.children.forEach((c) => walk(c, depth + 1));
    } else if (node.favicon) bookmarkIcons[node.id] = node.favicon;
  };
  if (roots) {
    walk(roots.bar, 0);
    walk(roots.other, 0);
  }
  return { folders, bookmarkIcons };
}

export function NativeBookmarksPage({ tabId, profileId }: { tabId: string; profileId: string }) {
  const theme = useTheme();
  const windowId = useBrowser((s) => s.tabs[tabId]?.windowId ?? "");
  const bookmarks = useBrowser((s) => s.bookmarks);
  const roots = bookmarks.roots[profileId];
  const [undo, setUndo] = useState<{ removed: RemovedBookmarks; count: number } | null>(null);
  useEffect(() => {
    if (!undo) return;
    const timer = setTimeout(() => setUndo(null), 8000);
    return () => clearTimeout(timer);
  }, [undo]);

  const actionFlags = useMemo(() => {
    const { folders, bookmarkIcons } = profileNodes(bookmarks, roots);
    const s = { bookmarks };
    const groupable = folders.filter((id) => makesGroup(s, id));
    const arcRestorable = folders.filter((id) => restorableArcHolder(useBrowser.getState(), id));
    return { groupable, arcRestorable, bookmarkIcons };
  }, [bookmarks, roots]);
  const state = JSON.stringify({ ...pageThemeState(theme), profileId, engineProfile: engineProfile(profileId), undoCount: undo?.count ?? null, ...actionFlags });

  const onEvent = (e: NativePageEvent) => {
    const s = useBrowser.getState();
    const id = String(e.id ?? "");
    if (e.kind === "open") openUrl(String(e.url), windowId, e.mode as OpenMode);
    else if (e.kind === "openAll") void openFolder(id, windowId, e.newWindow ? "window" : "tabs");
    else if (e.kind === "edit") editBookmark(id, windowId, { profileId });
    else if (e.kind === "addGroup") addFolderToSidebar(id, windowId);
    else if (e.kind === "restoreArc") restoreArcFolders(id, windowId);
    else if (e.kind === "delete") {
      const removed = s.removeBookmarks(e.ids as string[]);
      setUndo({ removed, count: removed.places.length });
    } else if (e.kind === "undo") {
      if (undo) s.restoreBookmarks(undo.removed);
      setUndo(null);
    } else if (e.kind === "move") {
      const moving = e.ids as string[];
      if (typeof e.into === "string") return moving.forEach((m) => s.moveBookmark(m, e.into as string));
      const listed = e.listed as string[];
      let index = e.index as number;
      for (const m of moving) {
        const from = listed.indexOf(m);
        if (from >= 0 && from < (e.index as number)) index--;
      }
      moving.forEach((m, i) => useBrowser.getState().moveBookmark(m, String(e.parentId), index + i));
    } else if (e.kind === "addBookmark") editBookmark(null, windowId, { profileId, parentId: (e.parentId as string | null) ?? undefined });
    else if (e.kind === "addFolder") editBookmark(null, windowId, { profileId, parentId: (e.parentId as string | null) ?? undefined, folder: true });
    else if (e.kind === "import") openImport();
  };
  return <NativePage kind="bookmarks" state={state} style={StyleSheet.absoluteFill} onPageEvent={(e) => onEvent(e.nativeEvent)} />;
}

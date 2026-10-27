import { NativePage, type NativePageEvent } from "@ardia/settings";
import { useEffect, useMemo, useState } from "react";
import { StyleSheet } from "react-native";
import { addFolderToSidebar, makesGroup, restorableArcHolder, restoreArcFolders } from "../../lib/bookmarkGroups";
import { useTheme } from "../../lib/theme";
import type { RemovedBookmarks } from "../../store/bookmarks";
import { useBrowser } from "../../store/browser";
import type { BookmarkNode } from "../../store/types";
import { openFolder, openUrl } from "../bookmarks/actions";
import { editBookmark } from "../bookmarks/edit";
import { openImport } from "../settings/windows";
import { pageThemeState } from "./nativePageTheme";

type OpenMode = Parameters<typeof openUrl>[2];
type Bookmarks = ReturnType<typeof useBrowser.getState>["bookmarks"];

function profileNodes(b: Bookmarks, roots: { bar: string; other: string } | undefined) {
  const out: Record<string, unknown>[] = [];
  const folders: string[] = [];
  const walk = (id: string, depth: number) => {
    const node: BookmarkNode | undefined = b.nodes[id];
    if (!node || depth > 64) return;
    if (node.kind === "folder") {
      folders.push(node.id);
      out.push({ id: node.id, kind: "folder", parentId: node.parentId ?? null, title: node.title, children: node.children });
      node.children.forEach((c) => walk(c, depth + 1));
    } else out.push({ id: node.id, kind: "url", parentId: node.parentId, title: node.title, url: node.url, favicon: node.favicon });
  };
  if (roots) {
    walk(roots.bar, 0);
    walk(roots.other, 0);
  }
  return { nodes: out, folders };
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

  const tree = useMemo(() => {
    const { nodes, folders } = profileNodes(bookmarks, roots);
    const s = { bookmarks };
    const groupable = folders.filter((id) => makesGroup(s, id));
    const arcRestorable = folders.filter((id) => restorableArcHolder(useBrowser.getState(), id));
    return JSON.stringify({ nodes, roots: roots ?? null, groupable, arcRestorable });
  }, [bookmarks, roots]);
  const rest = JSON.stringify({ ...pageThemeState(theme), profileId, undoCount: undo?.count ?? null });
  const state = `${tree.slice(0, -1)},${rest.slice(1)}`;

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

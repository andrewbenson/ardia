import { prompt } from "@solara/shell";
import { layout } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { useWindowId } from "../../store/hooks";
import { useBookmarkDialog, type BookmarkDialogState } from "./actions";
import { NativeBookmarkDialog } from "./NativeBookmarkForms";
import { SIDEBAR_HEADER_WITH_FIELD } from "../layout/windowLayout";

export function BookmarkDialog() {
  const windowId = useWindowId();
  const open = useBookmarkDialog((d) => (d.open?.windowId === windowId ? d.open : null));
  if (!open) return null;
  const key = open.kind === "page" ? open.bookmarkId : "all";
  return <NativeBookmarkDialog key={key} state={open} />;
}

export function finishBookmarkDialog(state: BookmarkDialogState, name: string, folderId: string | null) {
  const s = useBrowser.getState();
  const close = () => useBookmarkDialog.getState().set(null);
  if (state.kind === "page") {
    const bookmark = s.bookmarks.nodes[state.bookmarkId];
    if (!bookmark) return close();
    if (name.trim() && name !== bookmark.title) s.updateBookmark(state.bookmarkId, { title: name.trim() });
    if (folderId && folderId !== bookmark.parentId) s.moveBookmark(state.bookmarkId, folderId);
  } else {
    const title = name.trim() || "Tabs";
    s.addBookmarkTree(state.profileId, [{ title, children: state.tabs.map((t) => ({ title: t.title, url: t.url })) }], folderId ?? undefined);
  }
  close();
}

export function removeDialogBookmark(state: BookmarkDialogState) {
  if (state.kind === "page") useBrowser.getState().removeBookmark(state.bookmarkId);
  useBookmarkDialog.getState().set(null);
}

export async function newDialogFolder(state: BookmarkDialogState, profileId: string | null, folderId: string | null) {
  const title = await prompt({ title: "New Folder", placeholder: "Folder name", confirmTitle: "Create", windowId: state.windowId });
  if (!title || !profileId) return null;
  return useBrowser.getState().addBookmarkFolder({ profileId, title, parentId: folderId ?? undefined });
}

export function bookmarkDialogPlacement(addressBar: boolean) {
  return addressBar ? { top: SIDEBAR_HEADER_WITH_FIELD + 4, left: layout.sidebarInset } : { top: layout.cardTop + layout.toolbarHeight - 2, right: layout.cardInset + 10 };
}

export function profileOfNode(id: string): string | null {
  const b = useBrowser.getState().bookmarks;
  let node = b.nodes[id];
  for (let i = 0; node?.parentId && i < 64; i++) node = b.nodes[node.parentId];
  if (!node) return null;
  return Object.entries(b.roots).find(([, r]) => r.bar === node!.id || r.other === node!.id)?.[0] ?? null;
}

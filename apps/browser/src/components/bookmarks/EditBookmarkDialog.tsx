import { resolveInput } from "@solara/core";
import { useBrowser } from "../../store/browser";
import { useWindowId } from "../../store/hooks";
import { searchUrlPrefix } from "../../store/settings";
import { useBookmarkEditor, type EditorState } from "./edit";
import { NativeBookmarkEditor } from "./NativeBookmarkForms";

export function EditBookmarkDialog() {
  const windowId = useWindowId();
  const open = useBookmarkEditor((e) => (e.open?.windowId === windowId ? e.open : null));
  if (!open) return null;
  const key = `${open.bookmarkId}:${open.folder}`;
  return <NativeBookmarkEditor key={key} state={open} />;
}

export const resolvedBookmarkUrl = (url: string) => (url.trim() ? resolveInput(url, searchUrlPrefix(useBrowser.getState().settings)) : "");

export function saveBookmarkEditor(state: EditorState, title: string, url: string, parentId: string | null) {
  const s = useBrowser.getState();
  const node = s.bookmarks.nodes[state.bookmarkId ?? ""];
  const resolvedUrl = resolvedBookmarkUrl(url);
  if (state.folder ? !title.trim() : !resolvedUrl) return;
  if (node) {
    s.updateBookmark(node.id, state.folder ? { title: title.trim() } : { title: title.trim(), url: resolvedUrl });
    if (parentId && parentId !== node.parentId) s.moveBookmark(node.id, parentId);
  } else if (state.folder) {
    s.addBookmarkFolder({ profileId: state.profileId, title: title.trim(), parentId: parentId ?? undefined, index: state.index });
  } else {
    s.addBookmark({ profileId: state.profileId, url: resolvedUrl, title: title.trim() || resolvedUrl, parentId: parentId ?? undefined, index: state.index });
  }
  useBookmarkEditor.getState().set(null);
}


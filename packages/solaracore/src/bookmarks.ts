import { engineCall, onEngineEvent } from "./engine";

export type EngineBookmark = { id: string; k: "u" | "f"; t: string; u?: string; a: number; key?: string; c?: EngineBookmark[] };

export type BookmarkOp =
  | { op: "add"; id: string; k: "u" | "f"; t: string; u?: string; a: number; key?: string; parent: string; index?: number; ifAbsent?: boolean }
  | { op: "move"; id: string; parent: string; index: number }
  | { op: "update"; id: string; t?: string; u?: string }
  | { op: "remove"; id: string };

export const bookmarkTree = (profile: string) => engineCall<{ bar: EngineBookmark; other: EngineBookmark }>("ac_bookmarks_tree", profile);

export const watchBookmarks = (profile: string) => engineCall("ac_bookmarks_watch", profile);

export const onBookmarksChanged = (listener: (profile: string) => void) =>
  onEngineEvent("bookmarks.changed", (p) => listener(p.profile));

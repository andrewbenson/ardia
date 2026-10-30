import { bookmarksByUrl } from "../../store/bookmarks";
import type { Bookmarks } from "../../store/types";

type BookmarkRow = { url: string; title: string; favicon: string | null };
const bookmarkCache = new WeakMap<Bookmarks, Map<string, BookmarkRow[]>>();

export function profileBookmarks(b: Bookmarks, profileId: string): BookmarkRow[] {
  let perProfile = bookmarkCache.get(b);
  if (!perProfile) bookmarkCache.set(b, (perProfile = new Map()));
  let rows = perProfile.get(profileId);
  if (!rows) {
    rows = [];
    for (const [url, ids] of bookmarksByUrl(b, profileId)) {
      const node = b.nodes[ids[0]!];
      if (node?.kind === "url") rows.push({ url, title: node.title, favicon: node.favicon });
    }
    perProfile.set(profileId, rows);
  }
  return rows;
}

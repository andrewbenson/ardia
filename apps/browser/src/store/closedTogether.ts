import { storeTransaction, useBrowser } from "./browser";

const store = () => useBrowser.getState();
let lastClosedTogether: string[] | null = null;

export function closeTogether(ids: string[]) {
  const before = new Set(store().closedTabs.map((c) => c.id));
  store().closeTabs(ids, { lastClosesWindow: true });
  const closed = store().closedTabs.filter((c) => !before.has(c.id)).map((c) => c.id);
  lastClosedTogether = closed.length > 1 ? closed : null;
}

export function reopenClosedTogether(windowId: string): boolean {
  const ids = lastClosedTogether;
  lastClosedTogether = null;
  if (!ids) return false;
  const s = store();
  const entries = s.closedTabs.filter((c) => ids.includes(c.id));
  const newest = Math.max(...[...s.closedTabs, ...s.closedWindows, ...s.closedGroups].map((c) => c.closedAt));
  if (entries.length < 2 || s.closedTabs.slice(-entries.length).some((c) => !ids.includes(c.id)) || entries.some((c) => c.closedAt < newest)) return false;
  storeTransaction(() => {
    for (const entry of entries.sort((a, b) => a.index - b.index)) store().restoreClosed(entry.id, windowId);
  });
  return true;
}

import type { BrowserWindow, SplitView, Tab, TabGroup } from "../store/types";

export type CloseSnapshot = {
  window: BrowserWindow;
  tabs: Tab[];
  groups: TabGroup[];
  splits: SplitView[];
  browsers: Record<number, string>;
  pooled: boolean;
  closedAt: number;
};

export const closeSnapshots = new Map<string, CloseSnapshot>();

export function hasPendingCloseSnapshot(windowId: string) {
  return closeSnapshots.has(windowId);
}

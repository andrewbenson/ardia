import { publishSettingsTopic } from "@solara/settings";
import { closeTab } from "../../lib/actions";
import { manualRefresh, openLiveItem } from "../../live/engine";
import { live, setExpandedStack, setLive, updateFolder, useLive } from "../../live/store";
import { useBrowser } from "../../store/browser";
import { viewTabIds } from "../../store/model";
import { openSettings } from "../settings/windows";
import { openLiveFolderMenu, openLiveItemMenu, openLiveStackMenu } from "./liveMenus";

type LiveState = ReturnType<typeof useLive.getState>;

function replica(s: LiveState): string {
  return JSON.stringify({
    folders: s.folders,
    folderOrder: s.folderOrder,
    items: s.items,
    unread: s.unread,
    hidden: s.hidden,
    completed: s.completed,
    completing: s.completing,
    status: s.status,
    expandedStacks: s.expandedStacks,
    showAll: s.showAll,
    meetingGroups: s.meetingGroups,
  });
}

let published = false;

export function publishNativeLive(): void {
  if (published) return;
  published = true;
  let last = "";
  let queued = false;
  const publish = () => {
    queued = false;
    const json = replica(useLive.getState());
    if (json === last) return;
    last = json;
    publishSettingsTopic("sidebar.live", json);
  };
  publish();
  useLive.subscribe((s, prev) => {
    if (queued) return;
    if (
      s.folders === prev.folders &&
      s.folderOrder === prev.folderOrder &&
      s.items === prev.items &&
      s.unread === prev.unread &&
      s.hidden === prev.hidden &&
      s.completed === prev.completed &&
      s.completing === prev.completing &&
      s.status === prev.status &&
      s.expandedStacks === prev.expandedStacks &&
      s.showAll === prev.showAll &&
      s.meetingGroups === prev.meetingGroups
    ) {
      return;
    }
    queued = true;
    queueMicrotask(publish);
  });
}

export function runNativeLive(windowId: string, folderId: string, action: string, itemId: string | null, meta: boolean) {
  const s = live();
  const folder = s.folders[folderId];
  if (!folder) return;
  const item = itemId ? (s.items[folderId]?.find((i) => i.id === itemId) ?? null) : null;
  switch (action) {
    case "toggle":
      return updateFolder(folderId, { collapsed: !folder.collapsed });
    case "refresh":
      return void manualRefresh(folderId);
    case "settings":
      return void openSettings("liveFolders");
    case "folderMenu":
      return void openLiveFolderMenu(windowId, folderId);
    case "open":
      return item ? openLiveItem(windowId, folderId, item, { background: meta }) : undefined;
    case "itemMenu":
      return item ? void openLiveItemMenu(windowId, folderId, item, itemId ? liveTab(windowId, folder.profileId, folderId, itemId) : null) : undefined;
    case "close":
      return itemId ? void closeTab(itemId) : undefined;
    case "stack":
      return itemId ? setExpandedStack(itemId, s.expandedStacks[itemId] === false) : undefined;
    case "stackMenu":
      return itemId ? void openLiveStackMenu(folderId, itemId) : undefined;
    case "more":
      return itemId ? setLive((l) => ({ showAll: { ...l.showAll, [`${folderId}:${itemId}`]: true } })) : undefined;
    case "openCompleted": {
      const done = s.completed[folderId]?.find((c) => c.item.id === itemId);
      return done ? openLiveItem(windowId, folderId, done.item) : undefined;
    }
  }
}

function liveTab(windowId: string, profileId: string, folderId: string, itemId: string): string | null {
  const b = useBrowser.getState();
  return viewTabIds(b, windowId, profileId).find((id) => b.tabs[id]?.liveItem?.itemId === itemId && b.tabs[id]?.liveItem?.folderId === folderId) ?? null;
}

import { cleanUrl } from "@solara/core";
import { sharePage, sharePageVia, type ShareAnchor } from "@solara/shell";
import type { Tab } from "../../store/types";

export const canShare = (tab: Pick<Tab, "url"> | undefined) => /^https?:/i.test(tab?.url ?? "");

export async function shareTab(tab: Pick<Tab, "url" | "title" | "customTitle"> | undefined, windowId: string, via?: string | null, anchor?: ShareAnchor) {
  if (!tab || !canShare(tab)) return;
  const url = cleanUrl(tab.url);
  const title = tab.customTitle || tab.title || null;
  return via ? sharePageVia(via, url, title, windowId) : sharePage(url, title, windowId, anchor);
}

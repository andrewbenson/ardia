import { tabPoolAvailable, windowPagesPoolActive, windowPaneRootsActive, windowShellActive } from "@ardia/settings";

export const pagesPooledIn = (windowId: string) =>
  windowShellActive(windowId) && windowPaneRootsActive(windowId) && windowPagesPoolActive() && tabPoolAvailable();

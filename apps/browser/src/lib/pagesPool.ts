import { hostedKinds, tabPoolAvailable, windowPagesPoolActive, windowPaneRootsActive, windowShellActive } from "@ardia/settings";

export const pagesPooledIn = (windowId: string) =>
  windowShellActive(windowId) && windowPaneRootsActive(windowId) && windowPagesPoolActive() && tabPoolAvailable();

export const panePromptsNativeIn = (windowId: string) => pagesPooledIn(windowId) && hostedKinds().includes("panePrompts");

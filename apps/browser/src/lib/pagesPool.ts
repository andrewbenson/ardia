import { tabPoolAvailable, windowPagesPoolActive, windowShellActive } from "@ardia/settings";

export const pagesPooledIn = (windowId: string) => windowShellActive(windowId) && windowPagesPoolActive() && tabPoolAvailable();

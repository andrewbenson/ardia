import { focusWindow } from "@ardia/shell";
import type { SettingsHandler } from "@ardia/settings";
import { deleteLiveFolder } from "../../../live/engine";
import { connectGoogleDrive } from "../../../live/googleAuth";
import { useBrowser } from "../../../store/browser";

function browserWindow(): string | null {
  const s = useBrowser.getState();
  return s.ui.focusOrder.find((id) => s.windows[id] && !s.windows[id]!.incognito) ?? s.windowOrder.find((id) => !s.windows[id]!.incognito) ?? null;
}

function openInBrowser(url: string) {
  const windowId = browserWindow();
  if (!windowId) return;
  useBrowser.getState().newTab(windowId, { url });
  void focusWindow(windowId);
}

export const liveHandlers: Record<string, SettingsHandler> = {
  "liveFolders.deleteFolder": (id: string) => deleteLiveFolder(id),
  "liveFolders.connectGoogleDrive": async (clientId: string, clientSecret: string) => {
    const windowId = browserWindow();
    if (!windowId) throw new Error("Open a browser window first");
    void focusWindow(windowId);
    await connectGoogleDrive(windowId, clientId, clientSecret);
  },
  "liveFolders.openInBrowser": (url: string) => openInBrowser(url),
};

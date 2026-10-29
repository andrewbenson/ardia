import { onLiveAuthRequest, resolveLiveAuth, liveCommand } from "@ardia/settings";
import { useBrowser } from "../store/browser";

let started = false;

export function startGoogleAuth() {
  if (started) return;
  started = true;
  onLiveAuthRequest(({ requestId, url, redirectPrefix }) => {
    const s = useBrowser.getState();
    const windowId = s.ui.focusOrder.find((id) => s.windows[id] && !s.windows[id]!.incognito) ?? s.windowOrder.find((id) => !s.windows[id]!.incognito);
    if (!windowId) {
      void resolveLiveAuth(requestId, null, "Open a browser window first");
      return;
    }
    const tabId = s.newTab(windowId, { url });
    const stop = useBrowser.subscribe((state, prev) => {
      if (state.tabs === prev.tabs) return;
      const tab = state.tabs[tabId];
      if (!tab) {
        stop();
        void resolveLiveAuth(requestId, null, "Sign-in was cancelled");
        return;
      }
      if (!tab.url.startsWith(redirectPrefix)) return;
      stop();
      useBrowser.getState().closeTab(tabId);
      void resolveLiveAuth(requestId, tab.url, null);
    });
  });
}

export const connectGoogleDrive = async (_windowId: string, clientId: string, clientSecret: string): Promise<void> => {
  await liveCommand("connectGoogleDrive", { clientId, clientSecret });
};

import { nativeAppIntegrationCommand } from "@ardia/settings";
import {
  isDefaultBrowser,
  onCommand,
  onNotificationResponse,
  readDocument,
  saveDocument,
  setAsDefaultBrowser,
  setScriptLoading,
  systemInfo,
  type CommandEvent,
} from "@ardia/shell";
import { maybeStartOnboarding, openVideoTour, startOnboarding, startToolTour } from "../components/onboarding";
import { onboardingCompletedAt, useOnboarding } from "../components/onboarding/state";
import { trackAppVersion } from "../components/ntp/releaseNotes";
import { useBrowser } from "../store/browser";
import { focus, switchToTab } from "./actions";
import { afterFirstWindow } from "./afterFirstWindow";
import { offerDefaultBrowserAgain } from "./defaultBrowserOffer";
import { openReleaseNotesAfterUpdate, openReleaseNotesPage } from "./releaseNotesPage";
import { handleWebNotificationResponse } from "./webNotifications";

export function startAppIntegration() {
  onCommand(runAppCommand);
  onNotificationResponse((response) => {
    if (handleWebNotificationResponse(response) || response.action !== "click") return;
    const s = useBrowser.getState();
    const { tabId, windowId } = response;
    if (tabId && s.tabs[tabId]) switchToTab(tabId);
    else if (windowId && s.windows[windowId]) focus(windowId);
  });
  startScriptLoading();
  const updated = trackAppVersion();
  maybeStartOnboarding();
  if (updated) openReleaseNotesAfterUpdate();
  afterFirstWindow(() => {
    void offerDefaultBrowserAgain({
      read: readDocument,
      save: saveDocument,
      testInstance: systemInfo().isolatedInstance !== false,
      onboarding: !onboardingCompletedAt() || useOnboarding.getState().windowId !== null,
      isDefault: isDefaultBrowser,
      setDefault: setAsDefaultBrowser,
    }).catch((error) => console.warn("[defaultBrowserOffer]", error));
  });
}

function runAppCommand({ command, windowId }: CommandEvent) {
  switch (command) {
    case "showOnboarding":
      return startOnboarding(windowId);
    case "toolTour":
      return void startToolTour(windowId);
    case "videoTour":
      return openVideoTour(windowId);
    case "releaseNotes":
      return openReleaseNotesPage(windowId);
  }
}

export async function sendFeedback(windowId?: string | null) {
  await nativeAppIntegrationCommand("sendFeedback", windowId);
}

function startScriptLoading() {
  let lastJson = "";
  const push = () => {
    const s = useBrowser.getState();
    const ids = Object.keys(s.live).filter((id) => s.live[id]?.isLoading);
    const json = JSON.stringify(ids);
    if (json === lastJson) return;
    lastJson = json;
    void setScriptLoading(ids);
  };
  let timer: ReturnType<typeof setTimeout> | undefined;
  useBrowser.subscribe((s, prev) => {
    if (s.live === prev.live) return;
    timer ??= setTimeout(() => {
      timer = undefined;
      push();
    }, 100);
  });
  push();
}

import { onExtensionsChanged } from "@ardia/ardiacore";
import { publishSettingsTopic, type SettingsHandler } from "@ardia/settings";
import { useBrowser } from "../../../store/browser";
import { resolveWindowId } from "../../../store/model";
import { addFromWebStore, closeExtensionPopup, closeSidePanelsOf, refreshExtensionsAfterChange, useExtensions } from "../../extensions/state";
import { SETTINGS_WINDOW_ID } from "../windows";

function openInNewTab(url: string) {
  const windowId = resolveWindowId(useBrowser.getState());
  if (windowId) useBrowser.getState().newTab(windowId, { url });
}

function closeSurfaces(id: string) {
  if (useExtensions.getState().popup?.extensionId === id) closeExtensionPopup();
  closeSidePanelsOf(id);
}

export const extensionsHandlers: Record<string, SettingsHandler> = {
  "extensions.refresh": (profile: string) => void refreshExtensionsAfterChange(profile),
  "extensions.closeSurfaces": (id: string) => closeSurfaces(id),
  "extensions.openWebStoreDetail": (url: string, profile: string) => addFromWebStore(SETTINGS_WINDOW_ID, url, profile),
  "extensions.openInNewTab": (url: string) => openInNewTab(url),
};

let publishing = false;

export function publishExtensions(): void {
  if (publishing) return;
  publishing = true;
  onExtensionsChanged((change) => publishSettingsTopic("extensions.changed", { profile: change.profile, id: change.id, event: change.event }));
}

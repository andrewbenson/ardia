import {
  inspectUnpackedExtension,
  installExtension,
  onExtensionsChanged,
  reloadExtension,
  uninstallExtension,
  type ExtensionPackage,
  type InstalledExtension,
} from "@ardia/ardiacore";
import { publishSettingsTopic, type SettingsHandler } from "@ardia/settings";
import { useBrowser } from "../../../store/browser";
import { resolveWindowId } from "../../../store/model";
import { addFromWebStore, closeExtensionPopup, closeSidePanelsOf, configure, refreshExtensions, setEnabled, useExtensions } from "../../extensions/state";
import { SETTINGS_WINDOW_ID } from "../windows";

type ConfigureOptions = { pinned?: boolean; incognito?: boolean; siteAccess?: "allSites" | "specificSites" | "onClick" };

const extensionTopic = (ext: InstalledExtension) => ({
  id: ext.id,
  name: ext.name,
  version: ext.version,
  description: ext.description,
  enabled: ext.enabled,
  state: ext.state,
  icon: ext.icon,
  permissions: ext.permissions,
  siteAccess: ext.siteAccess,
  optionsUrl: ext.optionsUrl,
  pinned: ext.pinned,
  incognito: ext.incognito,
  mayModify: ext.mayModify,
  errors: ext.errors,
  path: ext.path,
  fromWebStore: ext.fromWebStore,
  webStoreUrl: ext.webStoreUrl,
});

const packageTopic = (pkg: ExtensionPackage) => ({
  name: pkg.name,
  version: pkg.version,
  icon: pkg.icon,
  permissions: pkg.permissions,
  hostPermissions: pkg.hostPermissions,
  path: pkg.path,
});

function openInNewTab(url: string) {
  const windowId = resolveWindowId(useBrowser.getState());
  if (windowId) useBrowser.getState().newTab(windowId, { url });
}

function closeSurfaces(id: string) {
  if (useExtensions.getState().popup?.extensionId === id) closeExtensionPopup();
  closeSidePanelsOf(id);
}

export const extensionsHandlers: Record<string, SettingsHandler> = {
  "extensions.list": (profile: string) => refreshExtensions(profile).then((list) => list.map(extensionTopic)),
  "extensions.setEnabled": (id: string, enabled: boolean, profile: string) => setEnabled(profile, id, enabled),
  "extensions.uninstall": (id: string, profile: string) => uninstallExtension(id, profile).finally(() => refreshExtensions(profile)),
  "extensions.reload": (id: string, profile: string) => reloadExtension(id, profile).finally(() => refreshExtensions(profile)),
  "extensions.configure": (id: string, profile: string, options: ConfigureOptions) => configure(profile, id, options),
  "extensions.inspectUnpacked": (path: string) => inspectUnpackedExtension(path).then(packageTopic),
  "extensions.install": async (path: string, profile: string) => {
    await installExtension({ path }, profile);
    await refreshExtensions(profile);
  },
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

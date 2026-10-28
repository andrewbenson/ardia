import {
  getPasskeyAccess,
  listComponents,
  requestPasskeyAccess,
  WIDEVINE_COMPONENT_ID,
  type PageEngine,
} from "@ardia/ardiacore";
import { engineHost } from "@ardia/core";
import { appIcons, currentAppIcon, isDefaultBrowser, launchAtLoginStatus, setAppIcon, setAsDefaultBrowser, setLaunchAtLogin, systemInfo } from "@ardia/shell";
import { nativeSettingsAvailable, publishSettingsTopic, serveNativeSettings, type SettingsHandler } from "@ardia/settings";
import { openUrls } from "../../lib/actions";
import { installCliInBackground, useCli } from "../../lib/cliControl";
import { setWebsiteEngine } from "../../lib/engines";
import { faviconUri } from "../../lib/favicons";
import { useBrowser } from "../../store/browser";
import { engineProfile } from "../../store/model";
import { controllingSearchExtension, defaultSearchEngine, searchEngines, type Settings } from "../../store/settings";
import { SHARING_COPY } from "../../telemetry/copy";
import { trackSettingsSection } from "../../telemetry/track";
import { setEnabled } from "../extensions/state";
import { extensionsProfileId } from "../extensions/store";
import { openInternalPage } from "../pages/urls";
import { hasDeveloperModeChanges, resetDeveloperModeSites } from "../site/developerMode";
import { autofillHandlers } from "./native/autofill";
import { extensionsHandlers, publishExtensions } from "./native/extensions";
import { importHandlers, publishImport } from "./native/import";
import { liveHandlers, publishLive } from "./native/live";
import { onboardingHandlers, publishOnboarding } from "./native/onboarding";
import { passwordsHandlers, publishPasswords } from "./native/passwords";
import { privacyHandlers, publishPrivacy } from "./native/privacy";
import { profilesHandlers, publishProfiles } from "./native/profiles";
import { shortcutsHandlers } from "./native/shortcuts";
import { publishSync, syncHandlers } from "./native/sync";
import { openImport, openSettings, type SettingsPane } from "./windows";

const handlers: Record<string, SettingsHandler> = {};
const publishers: (() => void)[] = [];
let started = false;

export function addNativeSettingsHandlers(added: Record<string, SettingsHandler>, publish?: () => void) {
  Object.assign(handlers, added);
  if (!publish) return;
  publishers.push(publish);
  if (started) publish();
}

function chooseTabLayout(layout: "sidebar" | "top") {
  const s = useBrowser.getState();
  s.updateSettings({ tabLayout: layout });
  for (const w of Object.values(s.windows)) {
    if ((w.tabLayout ?? s.settings.tabLayout) !== layout) useBrowser.getState().toggleTabLayout(w.id);
  }
  useBrowser.getState().updateSettings({ tabLayout: layout });
}

function manageExtensionsOf(profile: string) {
  const profileId = useBrowser.getState().profileOrder.find((id) => engineProfile(id) === profile);
  openSettings("extensions", extensionsProfileId(profileId));
}

const coreHandlers: Record<string, SettingsHandler> = {
  "settings.paneShown": (pane: SettingsPane) => trackSettingsSection(pane),
  "favicon.uri": (url: string, profileId: string | null) => faviconUri(url, profileId ?? undefined),
  "app.openInternalPage": (page: Parameters<typeof openInternalPage>[0]) => openInternalPage(page),
  "app.openUrls": (urls: string[]) => openUrls(urls),

  "general.loginItemStatus": () => launchAtLoginStatus().catch(() => "notRegistered"),
  "general.setLaunchAtLogin": (on: boolean) => setLaunchAtLogin(on).catch(() => {}),
  "general.isDefaultBrowser": () => isDefaultBrowser().catch(() => false),
  "general.setAsDefaultBrowser": () => setAsDefaultBrowser().catch(() => false),
  "general.openImport": () => openImport(),

  "tabs.chooseLayout": (layout: "sidebar" | "top") => chooseTabLayout(layout),

  "appearance.appIcons": (size: number) =>
    Promise.all([appIcons(size), currentAppIcon()]).then(([icons, current]) => ({ icons, current }), () => ({ icons: [], current: null })),
  "appearance.setAppIcon": (id: string) => setAppIcon(id),

  "search.setEngine": (id: string) => useBrowser.getState().setSearchEngine(id),
  "search.add": (input: { name: string; keyword: string; url: string }) => {
    const added = useBrowser.getState().addCustomEngine(input);
    return "error" in added ? added.error : null;
  },
  "search.update": (id: string, input: { name: string; keyword: string; url: string }) => useBrowser.getState().updateCustomEngine(id, input),
  "search.remove": (id: string) => useBrowser.getState().removeCustomEngine(id),
  "search.manageExtensions": (profile: string) => manageExtensionsOf(profile),
  "search.disableExtension": (profile: string, extensionId: string) => setEnabled(profile, extensionId, false),

  "engines.setWebsiteEngine": (site: string, engine: PageEngine | null) => setWebsiteEngine(site, engine),
  "engines.passkeyAccess": () => getPasskeyAccess().catch(() => null),
  "engines.requestPasskeyAccess": () => requestPasskeyAccess().catch(() => null),

  "advanced.widevineVersion": () =>
    listComponents().then(
      (list) => list.find((c) => c.id === WIDEVINE_COMPONENT_ID)?.version ?? null,
      () => null,
    ),
  "advanced.installCli": () => installCliInBackground("settings"),
  "advanced.resetDeveloperModeSites": () => resetDeveloperModeSites(),
};

function engineTopic(settings: Settings) {
  const controlling = controllingSearchExtension(settings);
  return {
    engines: searchEngines(settings).map((e) => ({
      id: e.id,
      name: e.name,
      keyword: e.keyword,
      url: e.url,
      host: engineHost(e),
      custom: !!e.custom,
      extension: e.extension ? { name: e.extension.name ?? "" } : null,
    })),
    selectedId: defaultSearchEngine(settings).id,
    controlling: controlling ? { extensionId: controlling.extensionId, extensionName: controlling.extensionName ?? "", profile: controlling.profile } : null,
  };
}

function cliTopic() {
  const cli = useCli.getState();
  return {
    server: cli.server ? { state: cli.server.state, reason: cli.server.reason ?? null, connections: cli.server.connections ?? null } : null,
    installing: !!cli.installing,
    step: cli.step ?? null,
    installedVersion: cli.installedVersion ?? null,
    binPath: cli.binPath ?? null,
    error: cli.error ?? null,
  };
}

function updateChecksNote() {
  return systemInfo().switchesURL ? `${SHARING_COPY.updateChecks} ${SHARING_COPY.switchFile}` : null;
}

export function startNativeSettings(): boolean {
  if (started) return true;
  if (!nativeSettingsAvailable()) return false;
  started = true;
  Object.assign(
    handlers,
    coreHandlers,
    privacyHandlers,
    passwordsHandlers,
    autofillHandlers,
    extensionsHandlers,
    shortcutsHandlers,
    profilesHandlers,
    syncHandlers,
    liveHandlers,
    importHandlers,
    onboardingHandlers,
  );
  serveNativeSettings(handlers);
  const publishSettings = (settings: Settings) => {
    publishSettingsTopic("search.engines", engineTopic(settings));
    publishSettingsTopic("advanced.developerModeChanged", hasDeveloperModeChanges(settings));
  };
  let focusProfile: string | null | undefined;
  const publishFocus = () => {
    const profile = extensionsProfileId(null);
    if (profile === focusProfile) return;
    focusProfile = profile;
    publishSettingsTopic("extensions.defaultProfile", profile);
  };
  publishSettings(useBrowser.getState().settings);
  publishFocus();
  publishSettingsTopic("advanced.cli", cliTopic());
  publishSettingsTopic("about.updateChecksNote", updateChecksNote());
  useBrowser.subscribe((s, prev) => {
    if (s.settings !== prev.settings) publishSettings(s.settings);
    if (s.ui.focusedWindowId !== prev.ui.focusedWindowId || s.windows !== prev.windows) publishFocus();
  });
  useCli.subscribe(() => publishSettingsTopic("advanced.cli", cliTopic()));
  for (const publish of [publishPrivacy, publishPasswords, publishExtensions, publishProfiles, publishSync, publishLive, publishImport, publishOnboarding, ...publishers]) publish();
  return true;
}

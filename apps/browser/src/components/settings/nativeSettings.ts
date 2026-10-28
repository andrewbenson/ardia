import { systemInfo } from "@ardia/shell";
import { nativeSettingsAvailable, publishSettingsTopic, serveNativeSettings, type SettingsHandler } from "@ardia/settings";
import { openUrls } from "../../lib/actions";
import { installCliInBackground, useCli } from "../../lib/cliControl";
import { faviconUri } from "../../lib/favicons";
import { useBrowser } from "../../store/browser";
import { engineProfile } from "../../store/model";
import { SHARING_COPY } from "../../telemetry/copy";
import { trackSettingsSection } from "../../telemetry/track";
import { setEnabled } from "../extensions/state";
import { extensionsProfileId } from "../extensions/store";
import { openInternalPage } from "../pages/urls";
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

  "general.openImport": () => openImport(),

  "tabs.chooseLayout": (layout: "sidebar" | "top") => chooseTabLayout(layout),

  "search.manageExtensions": (profile: string) => manageExtensionsOf(profile),
  "search.disableExtension": (profile: string, extensionId: string) => setEnabled(profile, extensionId, false),

  "advanced.installCli": () => installCliInBackground("settings"),
};

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
  let focusProfile: string | null | undefined;
  const publishFocus = () => {
    const profile = extensionsProfileId(null);
    if (profile === focusProfile) return;
    focusProfile = profile;
    publishSettingsTopic("extensions.defaultProfile", profile);
  };
  publishFocus();
  publishSettingsTopic("advanced.cli", cliTopic());
  publishSettingsTopic("about.updateChecksNote", updateChecksNote());
  useBrowser.subscribe((s, prev) => {
    if (s.ui.focusedWindowId !== prev.ui.focusedWindowId || s.windows !== prev.windows) publishFocus();
  });
  useCli.subscribe(() => publishSettingsTopic("advanced.cli", cliTopic()));
  for (const publish of [publishPrivacy, publishPasswords, publishExtensions, publishProfiles, publishSync, publishLive, publishImport, publishOnboarding, ...publishers]) publish();
  return true;
}

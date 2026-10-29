import {
  clearSiteData,
  getContentBlocker,
  getExternalAppAllowances,
  getSiteSettings,
  getSiteSettingsOrigins,
  getZoomLevels,
  onContentBlockerChange,
  removeExternalAppAllowance,
  resetSiteSettings,
  setContentBlockerAllowed,
  setContentBlockerEnabled,
  setFilterListEnabled,
  setSiteSetting,
  setZoom,
  type SiteSettingType,
  type SiteSettingValue,
} from "@ardia/ardiacore";
import { publishSettingsTopic, type SettingsHandler } from "@ardia/settings";

export const privacyHandlers: Record<string, SettingsHandler> = {
  "privacy.contentBlocker": () => getContentBlocker().catch(() => null),
  "privacy.setContentBlockerEnabled": (enabled: boolean) => setContentBlockerEnabled(enabled),
  "privacy.setFilterListEnabled": (id: string, enabled: boolean) => setFilterListEnabled(id, enabled),
  "privacy.setContentBlockerAllowed": (host: string, allowed: boolean) => setContentBlockerAllowed(host, allowed),
  "privacy.siteSettingsOrigins": (profile: string) => getSiteSettingsOrigins(profile).catch((): string[] => []),
  "privacy.siteSettings": (profile: string, origin: string) => getSiteSettings(profile, origin).catch(() => null),
  "privacy.setSiteSetting": (profile: string, origin: string, type: SiteSettingType, value: SiteSettingValue) =>
    setSiteSetting(profile, origin, type, value),
  "privacy.resetSiteSettings": (profile: string, origin: string) => resetSiteSettings(profile, origin),
  "privacy.clearSiteData": (profile: string, origin: string) => clearSiteData(profile, origin),
  "privacy.externalAppAllowances": (profile: string) => getExternalAppAllowances(profile).catch(() => []),
  "privacy.removeExternalAppAllowance": (profile: string, origin: string, scheme: string) => removeExternalAppAllowance(profile, origin, scheme),
  "privacy.zoomLevels": (profile: string) => getZoomLevels(profile).catch((): Record<string, number> => ({})),
  "privacy.setZoom": (profile: string, host: string, zoom: number) => setZoom(profile, host, zoom),
};

let started = false;

export function publishPrivacy(): void {
  if (started) return;
  started = true;
  let changes = 0;
  publishSettingsTopic("privacy.contentBlockerChanged", changes);
  onContentBlockerChange(() => void publishSettingsTopic("privacy.contentBlockerChanged", ++changes));
}

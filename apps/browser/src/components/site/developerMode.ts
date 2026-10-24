import { setDeveloperHosts } from "@ardia/ardiacore";
import { canToggleDeveloperMode, isDeveloperMode, withDeveloperMode } from "../../lib/developerMode";
import { useBrowser } from "../../store/browser";
import { useSettings } from "../../store/hooks";
import { isIncognitoProfile } from "../../store/model";
import type { Settings } from "../../store/settings";
import { patchPage, pageOf } from "../layout/pageState";

const NO_SITES: string[] = [];

export const developerSites = (settings: Pick<Settings, "developerModeSites">): string[] =>
  Array.isArray(settings.developerModeSites) ? settings.developerModeSites.filter((h) => typeof h === "string") : NO_SITES;

export const inDeveloperMode = (url: string | undefined): boolean =>
  !!url && isDeveloperMode(url, { sites: developerSites(useBrowser.getState().settings) });

export function useDeveloperMode(url: string | undefined): boolean {
  const sites = useSettings((s) => s.developerModeSites);
  return !!url && isDeveloperMode(url, { sites: Array.isArray(sites) ? sites : NO_SITES });
}

export function canToggleDeveloperModeFor(tabId: string | undefined): boolean {
  const tab = tabId ? useBrowser.getState().tabs[tabId] : undefined;
  return !!tab && !isIncognitoProfile(tab.profileId) && canToggleDeveloperMode(tab.url);
}

export function setDeveloperModeFor(tabId: string, on: boolean) {
  const s = useBrowser.getState();
  const tab = s.tabs[tabId];
  if (!tab || !canToggleDeveloperModeFor(tabId)) return;
  s.updateSettings({ developerModeSites: withDeveloperMode(developerSites(s.settings), tab.url, on) });
}

export function toggleDeveloperModeFor(tabId: string | undefined) {
  const tab = tabId ? useBrowser.getState().tabs[tabId] : undefined;
  if (tab) setDeveloperModeFor(tab.id, !inDeveloperMode(tab.url));
}

export function resetDeveloperModeSites() {
  useBrowser.getState().updateSettings({ developerModeSites: [] });
}

export function noteConsoleCounts(tabId: string, data: unknown) {
  if (!data || typeof data !== "object") return;
  const { errors, warnings } = data as { errors?: unknown; warnings?: unknown };
  if (typeof errors !== "number" || typeof warnings !== "number") return;
  const current = pageOf(tabId).console;
  if (current && current.errors === errors && current.warnings === warnings) return;
  patchPage(tabId, { console: { errors, warnings } });
}

let started = false;

export function startDeveloperMode() {
  if (started) return;
  started = true;
  let sent: string[] | null = null;
  const sync = () => {
    const sites = developerSites(useBrowser.getState().settings);
    if (sent && sent.length === sites.length && sent.every((h, i) => h === sites[i])) return;
    sent = sites;
    void setDeveloperHosts(sites);
  };
  sync();
  useBrowser.subscribe(sync);
}

import { clearBrowsingData, listExtensions, type BrowsingDataType } from "@ardia/ardiacore";
import { publishSettingsTopic, type SettingsHandler } from "@ardia/settings";
import { pruneProfileFavicons } from "../../../lib/favicons";
import { sanitizeTheme } from "../../../lib/profileTheme";
import { useBrowser, type BrowserState } from "../../../store/browser";
import type { Profile, ProfileColor } from "../../../store/types";
import { adoptProfileTheme } from "../../../sync/engine";
import { arcThemeChoices } from "../ThemeEditor";

type ProfilePatch = Partial<Pick<Profile, "name" | "color" | "icon" | "theme">>;

export const profilesHandlers: Record<string, SettingsHandler> = {
  "profiles.create": (name: string, color: ProfileColor, shareWith: string | null) =>
    useBrowser.getState().createProfile({ name, color, shareWith }),
  "profiles.update": (id: string, patch: ProfilePatch) => useBrowser.getState().updateProfile(id, patch),
  "profiles.delete": (id: string) => useBrowser.getState().deleteProfile(id),
  "profiles.reorder": (ids: string[]) => useBrowser.getState().reorderProfiles(ids),
  "profiles.clearHistory": (profileId: string, since: number | null) => useBrowser.getState().clearHistory(profileId, since ?? undefined),
  "profiles.pruneFavicons": (profileId: string) => pruneProfileFavicons(profileId),
  "profiles.clearBrowsingData": (profile: string, kinds: BrowsingDataType[], since: number | null) =>
    clearBrowsingData(profile, kinds, since ?? undefined).catch(() => {}),
  "profiles.extensionsKeptOnDelete": () =>
    listExtensions("").then(
      (list) => list.filter((e) => e.mayModify).map((e) => e.name),
      () => null,
    ),
  "profiles.adoptTheme": (id: string) => adoptProfileTheme(id),
  "profiles.arcThemeChoices": () =>
    arcThemeChoices().then(
      (choices) =>
        choices.flatMap((c) => {
          const theme = sanitizeTheme(c.theme);
          return theme ? [{ id: c.id, name: c.name, emoji: c.emoji ?? null, theme }] : [];
        }),
      () => [],
    ),
};

function listTopic(s: BrowserState) {
  return {
    profiles: s.profileOrder.flatMap((id) => {
      const p = s.profiles[id];
      return p ? [{ id: p.id, name: p.name, color: p.color, icon: p.icon ?? null, dataId: p.dataId ?? null, theme: p.theme ? sanitizeTheme(p.theme) : null }] : [];
    }),
  };
}

const bookmarkCounts = new WeakMap<BrowserState["bookmarks"], Map<string, number>>();

function bookmarkCount(s: BrowserState, profileId: string): number {
  let byRoot = bookmarkCounts.get(s.bookmarks);
  if (!byRoot) bookmarkCounts.set(s.bookmarks, (byRoot = new Map()));
  const roots = s.bookmarks.roots[profileId];
  if (!roots) return 0;
  const key = `${roots.bar}:${roots.other}`;
  const known = byRoot.get(key);
  if (known !== undefined) return known;
  let count = 0;
  const walk = (id: string) => {
    const n = s.bookmarks.nodes[id];
    if (n?.kind === "url") count++;
    if (n?.kind === "folder") n.children.forEach(walk);
  };
  [roots.bar, roots.other].forEach(walk);
  byRoot.set(key, count);
  return count;
}

function statsTopic(s: BrowserState) {
  return Object.fromEntries(s.profileOrder.map((id) => [id, { historyPages: (s.history[id] ?? []).length, bookmarks: bookmarkCount(s, id) }]));
}

export function publishProfiles(): void {
  let lastStats = "";
  const publishStats = (s: BrowserState) => {
    const stats = statsTopic(s);
    const json = JSON.stringify(stats);
    if (json === lastStats) return;
    lastStats = json;
    publishSettingsTopic("profiles.stats", stats);
  };
  const initial = useBrowser.getState();
  publishSettingsTopic("profiles.list", listTopic(initial));
  publishSettingsTopic("profiles.appDark", initial.ui.appDark);
  publishStats(initial);
  useBrowser.subscribe((s, prev) => {
    if (s.profiles !== prev.profiles || s.profileOrder !== prev.profileOrder) publishSettingsTopic("profiles.list", listTopic(s));
    if (s.ui.appDark !== prev.ui.appDark) publishSettingsTopic("profiles.appDark", s.ui.appDark);
    if (s.history !== prev.history || s.bookmarks !== prev.bookmarks || s.profileOrder !== prev.profileOrder) publishStats(s);
  });
}

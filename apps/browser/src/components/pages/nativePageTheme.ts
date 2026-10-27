import type { Theme } from "../../lib/theme";

const KEYS = ["textPrimary", "textSecondary", "textTertiary", "placeholder", "selection", "rowHover", "toolbarHover", "toolbarPressed", "icon", "iconDisabled", "accent", "panel", "panelBorder"] as const;

export function pageThemeState(theme: Theme) {
  const tokens: Record<string, string> = {};
  for (const key of KEYS) {
    const value = (theme as unknown as Record<string, unknown>)[key];
    if (typeof value === "string") tokens[key] = value;
  }
  return { dark: !!theme.dark, theme: tokens, panelShadowOpacity: theme.panelShadowOpacity };
}

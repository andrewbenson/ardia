import { menuShortcuts } from "@solara/shell";
import type { SettingsHandler } from "@solara/settings";
import { setMenuBarShortcuts } from "../../../lib/commandShortcuts";

export const shortcutsHandlers: Record<string, SettingsHandler> = {
  "shortcuts.menuShortcuts": () =>
    menuShortcuts().then(
      (items) => (setMenuBarShortcuts(items), items),
      () => [],
    ),
};

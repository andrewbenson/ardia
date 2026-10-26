import { menuShortcuts } from "@ardia/shell";
import type { SettingsHandler } from "@ardia/settings";
import { setMenuBarShortcuts } from "../../../lib/commandShortcuts";

export const shortcutsHandlers: Record<string, SettingsHandler> = {
  "shortcuts.menuShortcuts": () =>
    menuShortcuts().then(
      (items) => (setMenuBarShortcuts(items), items),
      () => [],
    ),
};

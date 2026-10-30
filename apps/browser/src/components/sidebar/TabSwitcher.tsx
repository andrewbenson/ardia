import { useNativeTabSwitcher } from "./nativeTabPickers";
import { useSidebarUi } from "./state";

export function TabSwitcher({ windowId }: { windowId: string }) {
  const ids = useSidebarUi((u) => (u.switcher?.windowId === windowId && u.switcher.visible ? u.switcher.ids : null));
  const index = useSidebarUi((u) => (u.switcher?.windowId === windowId && u.switcher.visible ? u.switcher.index : -1));
  useNativeTabSwitcher(windowId, ids ? { ids, index } : null);
  return null;
}

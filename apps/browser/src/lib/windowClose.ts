import { confirm, onWindowEvent } from "@ardia/shell";
import { useBrowser } from "../store/browser";
import { tabsClosingWithWindow } from "../store/model";
import { closeWindowDialog } from "./closeWindowDialog";
import { isSmall } from "../store/small";
import { closeLittleArdia } from "../components/littleArdia/actions";

const MIN_TABS = 2;

export function startWindowCloseGuard() {
  const pending = new Set<string>();
  onWindowEvent((e) => {
    if (e.type !== "closeRequest" || pending.has(e.id)) return;
    pending.add(e.id);
    void requestClose(e.id).finally(() => pending.delete(e.id));
  });
}

async function requestClose(windowId: string) {
  const s = useBrowser.getState();
  const w = s.windows[windowId];
  if (!w) return;
  if (isSmall(s, windowId)) return closeLittleArdia(windowId);
  const count = closingTabs(windowId).length;
  if (s.settings.warnBeforeClosingWindow && count >= MIN_TABS) {
    const { confirmed, suppressed } = await confirm({ ...closeWindowDialog(windowId), suppression: "Don’t ask me again", windowId });
    if (suppressed) useBrowser.getState().updateSettings({ warnBeforeClosingWindow: false });
    if (!confirmed) return;
  }
  if (useBrowser.getState().windows[windowId]) useBrowser.getState().closeWindow(windowId);
}

const closingTabs = (windowId: string) => tabsClosingWithWindow(useBrowser.getState(), windowId);

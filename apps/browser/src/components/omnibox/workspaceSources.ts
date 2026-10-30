import type { newTabSources, NewTabSourceStatus } from "@ardia/settings";
import type { BrowserState, useBrowser } from "../../store/browser";
import { bookmarkProfileId, engineProfile } from "../../store/model";

type Store = Pick<typeof useBrowser, "getState" | "subscribe">;
type Sources = Pick<typeof newTabSources, "setTabs" | "setEngineProfile" | "onSourceStatus">;

export const queryTabRows = (state: Pick<BrowserState, "tabs">, profileId: string) => Object.values(state.tabs)
  .filter((tab) => tab.profileId === profileId)
  .map((tab) => ({ id: tab.id, url: tab.url, title: tab.title, favicon: tab.favicon ?? null }));

export function startWorkspaceSources(windowId: string, profileId: string, store: Store, sources: Sources): () => void {
  let status: NewTabSourceStatus = { mode: "js-feed", ready: true, epoch: 0 };
  let active = true;
  let tabs: unknown = null;
  let firstSnapshot = true;
  let historyEngine: string | undefined;
  let bookmarkEngine: string | undefined;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const nativeReady = () => status.mode === "native-store" && status.ready;
  const check = () => {
    if (!active || nativeReady()) return;
    const state = store.getState();
    const window = state.windows[windowId];
    if (!window) {
      clearTimeout(timer);
      return;
    }
    const engine = engineProfile(profileId);
    const bookmark = engineProfile(bookmarkProfileId(state, window));
    if (historyEngine !== engine || bookmarkEngine !== bookmark) {
      historyEngine = engine;
      bookmarkEngine = bookmark;
      void sources.setEngineProfile(profileId, engine, bookmark, status.epoch);
    }
    if (state.tabs === tabs) return;
    tabs = state.tabs;
    clearTimeout(timer);
    const epoch = status.epoch;
    if (firstSnapshot) {
      firstSnapshot = false;
      void sources.setTabs(profileId, queryTabRows(state, profileId), epoch);
      return;
    }
    timer = setTimeout(() => {
      if (!active || nativeReady() || status.epoch !== epoch) return;
      const latest = store.getState();
      if (!latest.windows[windowId]) return;
      void sources.setTabs(profileId, queryTabRows(latest, profileId), epoch);
    }, 50);
  };
  const offStatus = sources.onSourceStatus((next) => {
    status = next;
    clearTimeout(timer);
    tabs = null;
    firstSnapshot = true;
    historyEngine = undefined;
    bookmarkEngine = undefined;
    check();
  });
  const offStore = store.subscribe(check);
  check();
  return () => {
    active = false;
    offStatus();
    offStore();
    clearTimeout(timer);
  };
}

import type { WebViewHandle } from "@solara/solaracore";

export const webviews = new Map<string, WebViewHandle>();

const mounts = new Map<string, object>();

export const webviewMount = (tabId: string) => mounts.get(tabId);

export function webviewRef(tabId: string) {
  let mine: WebViewHandle | null = null;
  const mount = {};
  return (handle: WebViewHandle | null) => {
    if (handle) {
      mine = handle;
      webviews.set(tabId, handle);
      mounts.set(tabId, mount);
    } else if (mine && webviews.get(tabId) === mine) {
      webviews.delete(tabId);
      mounts.delete(tabId);
    }
  };
}

const issued = new Map<string, number>();

export const noteIssued = (tabId: string, seq: number) => void issued.set(tabId, seq);

export const issuedSeq = (tabId: string) => issued.get(tabId);

const pooled = new Set<string>();

export const notePooledPage = (tabId: string, on: boolean) => void (on ? pooled.add(tabId) : pooled.delete(tabId));

export const isPooledPage = (tabId: string) => pooled.has(tabId);

import { importWebKitCookies, webKitCookieStoreKey, type WebViewHandle } from "@ardia/ardiacore";
import { launchEnvironment } from "@ardia/shell";
import { useBrowser } from "../store/browser";
import { tabEngine } from "../store/engines";
import { engineProfile } from "../store/model";
import { carriableCookies, cookieAddresses } from "./signInCookies";
import { webviews } from "./webviews";

const CARRY_DEADLINE_MS = 1500;

let carryOn: boolean | undefined;

export const signInCarryOn = () => (carryOn ??= launchEnvironment("ARDIA_WEBKIT_SIGN_IN") === "on");

function stillChromiumPage(tabId: string, profile: string, web: WebViewHandle) {
  const s = useBrowser.getState();
  const t = s.tabs[tabId];
  return !!t && engineProfile(t.profileId) === profile && webviews.get(tabId) === web && tabEngine(s, tabId) === "chromium";
}

async function copyCookies(tabId: string, url: string): Promise<number> {
  const t = useBrowser.getState().tabs[tabId];
  const web = webviews.get(tabId);
  const urls = cookieAddresses(url);
  if (!t || !web || !urls.length) return 0;
  const profile = engineProfile(t.profileId);
  if (!stillChromiumPage(tabId, profile, web)) return 0;
  const storeKey = await webKitCookieStoreKey(profile);
  if (storeKey == null || !stillChromiumPage(tabId, profile, web)) return 0;
  const cookies = carriableCookies(await web.pageCookies(urls), Date.now() / 1000);
  if (!cookies.length || !stillChromiumPage(tabId, profile, web)) return 0;
  return importWebKitCookies(profile, storeKey, cookies);
}

export function carrySignInToWebKit(tabId: string, url: string): Promise<number> {
  if (!signInCarryOn()) return Promise.resolve(0);
  return Promise.race([
    copyCookies(tabId, url).catch(() => 0),
    new Promise<number>((resolve) => setTimeout(() => resolve(0), CARRY_DEADLINE_MS)),
  ]);
}

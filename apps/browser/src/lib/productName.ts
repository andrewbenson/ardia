import { setAppScheme } from "@solara/core";
import { systemInfo, type SystemInfo } from "@solara/shell";

export const DEFAULT_PRODUCT = "Solara";

function readInfo(): Partial<SystemInfo> {
  try {
    return systemInfo() ?? {};
  } catch {
    return {};
  }
}

function urlOf(url: string | null | undefined): URL | null {
  try {
    return url?.trim() ? new URL(url) : null;
  } catch {
    return null;
  }
}

const info = readInfo();
const feed = urlOf(info.updateFeedURL);
const switches = urlOf(info.switchesURL);

export const PRODUCT = info.appName?.trim() || DEFAULT_PRODUCT;

export const APP_SCHEME = setAppScheme(PRODUCT);

export const SERVICES = {
  updateHost: feed?.host || null,
  switchFile: switches?.host ? `${switches.host}${switches.pathname === "/" ? "" : switches.pathname}` : null,
};

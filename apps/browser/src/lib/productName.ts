import { setAppScheme } from "@ardia/core";
import { systemInfo, type SystemInfo } from "@ardia/shell";

export const DEFAULT_PRODUCT = "Ardia";

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
const telemetry = urlOf(info.telemetryURL);
const feed = urlOf(info.updateFeedURL);
const switches = urlOf(info.switchesURL);

export const PRODUCT = info.appName?.trim() || DEFAULT_PRODUCT;

export const APP_SCHEME = setAppScheme(PRODUCT);

export const SERVICES = {
  telemetryHost: telemetry?.host || null,
  updateHost: feed?.host || null,
  switchFile: switches?.host ? `${switches.host}${switches.pathname === "/" ? "" : switches.pathname}` : null,
};

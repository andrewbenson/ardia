import { requireOptionalNativeModule } from "expo-modules-core";

type WindowShellModule = {
  active(windowId: string): boolean;
  pagesPool?(): boolean;
  paneRoots?(windowId: string): boolean;
  setBackdrop(windowId: string, json: string): Promise<void>;
  describe(windowId: string): Promise<string>;
};

const native = requireOptionalNativeModule<WindowShellModule>("SolaraWindowShell");

export function windowShellActive(windowId: string): boolean {
  try {
    return native?.active(windowId) ?? false;
  } catch {
    return false;
  }
}

export function windowPagesPoolActive(): boolean {
  try {
    return native?.pagesPool?.() ?? false;
  } catch {
    return false;
  }
}

export function windowPaneRootsActive(windowId: string): boolean {
  try {
    return native?.paneRoots?.(windowId) ?? false;
  } catch {
    return false;
  }
}

export function setWindowShellBackdrop(windowId: string, json: string) {
  return native?.setBackdrop(windowId, json) ?? Promise.resolve();
}

export async function describeWindowShell(windowId: string): Promise<Record<string, unknown> | null> {
  return native ? (JSON.parse(await native.describe(windowId)) as Record<string, unknown> | null) : null;
}

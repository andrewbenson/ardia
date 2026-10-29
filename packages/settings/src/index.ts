import { requireOptionalNativeModule, type EventSubscription } from "expo-modules-core";

type SettingsCall = { id: number; name: string; args: string };

type NativeSettingsModule = {
  available(): boolean;
  servicesActive?(): boolean;
  appServicesActive?(): boolean;
  installCli?(reason: string): Promise<Record<string, unknown>>;
  navigate(pane: string | null, profileId: string | null, detail: string | null): Promise<void>;
  focusSearch(): Promise<void>;
  startHistoryCatalog?(profiles: string[]): Promise<void>;
  devHistorySnapshot?(profile: string): Promise<{ count: number; ready: boolean; floor: number | "-Infinity"; revision: number }>;
  devBookmarksSnapshot?(profile: string): Promise<{ count: number; ready: boolean; revision: number }>;
  devFaviconLookup?(page: string, engineProfile: string): Promise<{ bytes: number; source: string }>;
  bookmarkWriteComplete?(profile: string): Promise<void>;
  reply(id: number, resultJSON: string | null, error: string | null): Promise<void>;
  publish(topic: string, json: string): Promise<void>;
  addListener(event: "onSettingsCall", listener: (call: SettingsCall) => void): EventSubscription;
};

const native = requireOptionalNativeModule<NativeSettingsModule>("SolaraSettings");

export function nativeSettingsAvailable(): boolean {
  if (!native) return false;
  try {
    return native.available();
  } catch {
    return false;
  }
}

export function nativeServicesActive(): boolean {
  try {
    return native?.servicesActive?.() ?? false;
  } catch {
    return false;
  }
}

export const nativeInstallCli = (reason: string) =>
  native?.installCli ? native.installCli(reason) : Promise.reject(new Error("native services are off"));

export function nativeAppServicesActive(): boolean {
  try {
    return native?.appServicesActive?.() ?? false;
  } catch {
    return false;
  }
}

export const navigateNativeSettings = (pane: string | null, profileId: string | null, detail: string | null = null) =>
  native?.navigate(pane, profileId, detail).catch(() => {});

export const focusNativeSettingsSearch = () => native?.focusSearch().catch(() => {});

export const startNativeHistoryCatalog = (profiles: string[]) => native?.startHistoryCatalog?.(profiles).catch(() => {});

export const devNativeHistorySnapshot = (profile: string) => native?.devHistorySnapshot?.(profile);

export const devNativeBookmarksSnapshot = (profile: string) => native?.devBookmarksSnapshot?.(profile);

export const devFaviconLookup = (page: string, engineProfile: string) => native?.devFaviconLookup?.(page, engineProfile);

export const nativeBookmarkWriteComplete = (profile: string) => native?.bookmarkWriteComplete?.(profile).catch(() => {});

export const publishSettingsTopic = (topic: string, value: unknown) =>
  native?.publish(topic, JSON.stringify(value ?? null)).catch(() => {});

export type SettingsHandler = (...args: never[]) => unknown;

export function serveNativeSettings(handlers: Record<string, SettingsHandler>): EventSubscription | null {
  if (!native) return null;
  return native.addListener("onSettingsCall", ({ id, name, args }) => {
    const handler = handlers[name];
    if (!handler) return void native.reply(id, null, `no Settings handler for ${name}`).catch(() => {});
    let parsed: never[];
    try {
      parsed = JSON.parse(args) as never[];
    } catch {
      return void native.reply(id, null, `bad arguments for ${name}`).catch(() => {});
    }
    Promise.resolve()
      .then(() => handler(...parsed))
      .then(
        (result) => native.reply(id, result === undefined ? null : JSON.stringify(result), null),
        (error: unknown) => native.reply(id, null, error instanceof Error ? error.message : String(error)),
      )
      .catch(() => {});
  });
}
export * from "./newTab";
export * from "./hosted";
export * from "./omnibox";
export * from "./toolbar";
export * from "./findBar";
export * from "./downloads";
export * from "./prompt";
export * from "./sitePanel";
export * from "./windowShell";
export * from "./tabPool";
export * from "./profilePager";
export * from "./littleSolara";
export * from "./cliIndicator";
export * from "./topStrip";
export * from "./pages";

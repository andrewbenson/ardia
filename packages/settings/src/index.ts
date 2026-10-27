import { requireOptionalNativeModule, type EventSubscription } from "expo-modules-core";

type SettingsCall = { id: number; name: string; args: string };

type NativeSettingsModule = {
  available(): boolean;
  navigate(pane: string | null, profileId: string | null, detail: string | null): Promise<void>;
  focusSearch(): Promise<void>;
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

export const navigateNativeSettings = (pane: string | null, profileId: string | null, detail: string | null = null) =>
  native?.navigate(pane, profileId, detail).catch(() => {});

export const focusNativeSettingsSearch = () => native?.focusSearch().catch(() => {});

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

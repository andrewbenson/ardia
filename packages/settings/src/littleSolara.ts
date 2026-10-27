import { requireOptionalNativeModule } from "expo-modules-core";

type LittleSolaraModule = {
  littleActive(windowId: string): boolean;
  setLittleBar(windowId: string, json: string): Promise<void>;
  setLittleBackdrop(windowId: string, json: string): Promise<void>;
  describeLittle(windowId: string): Promise<string>;
};

const native = requireOptionalNativeModule<LittleSolaraModule>("SolaraMedia");

export function littleSolaraShellActive(windowId: string): boolean {
  try {
    return native?.littleActive?.(windowId) ?? false;
  } catch {
    return false;
  }
}

export function setLittleSolaraBar(windowId: string, json: string) {
  return native?.setLittleBar?.(windowId, json) ?? Promise.resolve();
}

export function setLittleSolaraBackdrop(windowId: string, json: string) {
  return native?.setLittleBackdrop?.(windowId, json) ?? Promise.resolve();
}

export async function describeLittleSolaraShell(windowId: string): Promise<Record<string, unknown> | null> {
  return native?.describeLittle ? (JSON.parse(await native.describeLittle(windowId)) as Record<string, unknown> | null) : null;
}

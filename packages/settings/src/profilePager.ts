import { requireOptionalNativeModule, type EventSubscription } from "expo-modules-core";

type ProfilePagerModule = {
  active(windowId: string): boolean;
  setLooks(json: string): Promise<void>;
  describe(windowId: string): Promise<string>;
  addListener(name: "onPagerPosition", listener: (event: { windowId: string; position: number }) => void): EventSubscription;
};

const native = requireOptionalNativeModule<ProfilePagerModule>("SolaraProfilePager");

export function profilePagerNative(windowId: string): boolean {
  try {
    return native?.active(windowId) ?? false;
  } catch {
    return false;
  }
}

export function setProfilePagerLooks(json: string) {
  return native?.setLooks(json) ?? Promise.resolve();
}

export function onProfilePagerPosition(listener: (windowId: string, position: number) => void): () => void {
  const subscription = native?.addListener("onPagerPosition", (e) => listener(e.windowId, e.position));
  return () => subscription?.remove();
}

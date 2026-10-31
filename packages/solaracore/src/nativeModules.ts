import { requireNativeModule, requireOptionalNativeModule } from "expo-modules-core";
import type { NativeChromeUI } from "./chromeUI";
import type { NativeExtensions } from "./extensions";
import type { CefNative } from "./native";
import type { SwipeModule } from "./swipe";
import type { WebKitNative } from "./webkit";

export type SolaraCoreNativeModules = {
  SolaraCEF: CefNative;
  SolaraExtensions: NativeExtensions;
  SolaraChromeUI: NativeChromeUI;
  SolaraSwipe: SwipeModule;
};

export type SolaraCoreOptionalNativeModules = {
  SolaraWebKit: WebKitNative;
};

export const nativeModule = <Name extends keyof SolaraCoreNativeModules>(name: Name) => requireNativeModule<SolaraCoreNativeModules[Name]>(name);

export const optionalNativeModule = <Name extends keyof SolaraCoreOptionalNativeModules>(name: Name) =>
  requireOptionalNativeModule<SolaraCoreOptionalNativeModules[Name]>(name);

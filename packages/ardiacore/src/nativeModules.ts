import { requireNativeModule, requireOptionalNativeModule } from "expo-modules-core";
import type { NativeChromeUI } from "./chromeUI";
import type { NativeExtensions } from "./extensions";
import type { CefNative } from "./native";
import type { SwipeModule } from "./swipe";
import type { WebKitNative } from "./webkit";

export type ArdiaCoreNativeModules = {
  ArdiaCEF: CefNative;
  ArdiaExtensions: NativeExtensions;
  ArdiaChromeUI: NativeChromeUI;
  ArdiaSwipe: SwipeModule;
};

export type ArdiaCoreOptionalNativeModules = {
  ArdiaWebKit: WebKitNative;
};

export const nativeModule = <Name extends keyof ArdiaCoreNativeModules>(name: Name) => requireNativeModule<ArdiaCoreNativeModules[Name]>(name);

export const optionalNativeModule = <Name extends keyof ArdiaCoreOptionalNativeModules>(name: Name) =>
  requireOptionalNativeModule<ArdiaCoreOptionalNativeModules[Name]>(name);

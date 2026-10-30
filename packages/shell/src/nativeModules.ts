import { requireNativeModule, requireOptionalNativeModule } from "expo-modules-core";
import type { AppModule } from "./app";
import type { CliNative } from "./cli";
import type { DockSelectionNative, GlassEffectNative, HairlineNative, InlineCompletionNative, PopoverBubbleNative, ShellNative, TranslationModule } from "./index";
import type { CalendarNative, KeychainNative } from "./live";
import type { FileDropNative, MagnifyAreaNative, SystemNative } from "./system";

export type ShellNativeModules = {
  ArdiaShell: ShellNative;
  ArdiaApp: AppModule;
  ArdiaSystem: SystemNative;
  ArdiaCalendar: CalendarNative;
  ArdiaKeychain: KeychainNative;
  ArdiaGlassEffect: GlassEffectNative;
  ArdiaDockSelection: DockSelectionNative;
  ArdiaInlineCompletion: InlineCompletionNative;
  ArdiaTranslate: TranslationModule;
};

export type ShellOptionalNativeModules = {
  ArdiaPopoverBubble: PopoverBubbleNative;
  ArdiaHairline: HairlineNative;
  ArdiaMagnifyArea: MagnifyAreaNative;
  ArdiaFileDrop: FileDropNative;
  ArdiaCli: CliNative;
};

export const nativeModule = <Name extends keyof ShellNativeModules>(name: Name) => requireNativeModule<ShellNativeModules[Name]>(name);

export const optionalNativeModule = <Name extends keyof ShellOptionalNativeModules>(name: Name) =>
  requireOptionalNativeModule<ShellOptionalNativeModules[Name]>(name);

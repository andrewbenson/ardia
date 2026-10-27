import { requireNativeViewManager } from "expo-modules-core";
import type { ComponentType } from "react";
import type { NativeSyntheticEvent, ViewProps } from "react-native";

export type NativePromptEvent = { kind: "button" | "choice"; id: string } | { kind: "toggle"; value: boolean } | { kind: "close" };

export type NativePromptProps = ViewProps & {
  state: string;
  onPromptEvent?(e: NativeSyntheticEvent<NativePromptEvent>): void;
  onPromptHeight?(e: NativeSyntheticEvent<{ height: number }>): void;
};

let View: ComponentType<NativePromptProps> | null = null;

export function NativePromptView(props: NativePromptProps) {
  View ??= requireNativeViewManager<NativePromptProps>("SolaraPrompt") as ComponentType<NativePromptProps>;
  return <View {...props} />;
}

export type NativeDeviceChooserEvent = { kind: "select" | "choose"; index: number } | { kind: "cancel" | "refresh" | "openSettings" };

export type NativeDeviceChooserProps = ViewProps & {
  state: string;
  onChooserEvent?(e: NativeSyntheticEvent<NativeDeviceChooserEvent>): void;
  onChooserHeight?(e: NativeSyntheticEvent<{ height: number }>): void;
};

let ChooserView: ComponentType<NativeDeviceChooserProps> | null = null;

export function NativeDeviceChooserView(props: NativeDeviceChooserProps) {
  ChooserView ??= requireNativeViewManager<NativeDeviceChooserProps>("SolaraDeviceChooser") as ComponentType<NativeDeviceChooserProps>;
  return <ChooserView {...props} />;
}

import { requireNativeViewManager, requireOptionalNativeModule } from "expo-modules-core";
import type { ComponentType } from "react";
import type { NativeSyntheticEvent, ViewProps } from "react-native";

export type ToolbarClick = { id: string; kind: "press" | "menu" | "middle"; meta: boolean; alt: boolean; shift: boolean };

export type NativeToolbarProps = ViewProps & {
  state: string;
  onToolbarClick?(e: NativeSyntheticEvent<ToolbarClick>): void;
};

const native = requireOptionalNativeModule<{ available(): boolean }>("SolaraToolbar");

let availability: boolean | null = null;

export function nativeToolbarAvailable(): boolean {
  if (availability !== null) return availability;
  try {
    availability = !!native?.available();
  } catch {
    availability = false;
  }
  return availability;
}

let View: ComponentType<NativeToolbarProps> | null = null;

export function NativeToolbarView(props: NativeToolbarProps) {
  View ??= requireNativeViewManager<NativeToolbarProps>("SolaraToolbar") as ComponentType<NativeToolbarProps>;
  return <View {...props} />;
}

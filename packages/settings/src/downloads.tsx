import { requireNativeViewManager } from "expo-modules-core";
import type { ComponentType } from "react";
import type { NativeSyntheticEvent, ViewProps } from "react-native";

export type NativeDownloadsEvent = { kind: "open" | "reveal" | "pause" | "resume" | "cancel" | "menu" | "clear" | "viewAll"; id: string | null };

export type NativeDownloadsProps = ViewProps & {
  state: string;
  onDownloadsEvent?(e: NativeSyntheticEvent<NativeDownloadsEvent>): void;
  onDownloadsHeight?(e: NativeSyntheticEvent<{ height: number }>): void;
};

let View: ComponentType<NativeDownloadsProps> | null = null;

export function NativeDownloadsView(props: NativeDownloadsProps) {
  View ??= requireNativeViewManager<NativeDownloadsProps>("SolaraDownloads") as ComponentType<NativeDownloadsProps>;
  return <View {...props} />;
}

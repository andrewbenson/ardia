import { requireNativeViewManager } from "expo-modules-core";
import type { ComponentType } from "react";
import type { NativeSyntheticEvent, ViewProps } from "react-native";

export type NativeFindEvent =
  | { kind: "query"; text: string }
  | { kind: "step"; backwards: boolean }
  | { kind: "close" }
  | { kind: "replacement"; text: string }
  | { kind: "replace"; all: boolean }
  | { kind: "focused" };

export type NativeFindBarProps = ViewProps & { state: string; onFindEvent?(e: NativeSyntheticEvent<NativeFindEvent>): void };

let View: ComponentType<NativeFindBarProps> | null = null;

export function NativeFindBarView(props: NativeFindBarProps) {
  View ??= requireNativeViewManager<NativeFindBarProps>("SolaraFindBar") as ComponentType<NativeFindBarProps>;
  return <View {...props} />;
}

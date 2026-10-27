import { requireNativeViewManager } from "expo-modules-core";
import type { ComponentType } from "react";
import type { NativeSyntheticEvent, ViewProps } from "react-native";

export type NativeSitePanelEvent =
  | { kind: "press"; id: string; rect: [number, number, number, number]; clickAt: number }
  | { kind: "menu"; id: string; rect: [number, number, number, number] }
  | { kind: "toggle"; id: string; value: boolean }
  | { kind: "zoom"; id: string; step: number };

export type NativeSitePanelProps = ViewProps & {
  state: string;
  onSitePanelEvent?(e: NativeSyntheticEvent<NativeSitePanelEvent>): void;
  onSitePanelHeight?(e: NativeSyntheticEvent<{ height: number }>): void;
};

let View: ComponentType<NativeSitePanelProps> | null = null;

export function NativeSitePanelView(props: NativeSitePanelProps) {
  View ??= requireNativeViewManager<NativeSitePanelProps>("SolaraSitePanel") as ComponentType<NativeSitePanelProps>;
  return <View {...props} />;
}

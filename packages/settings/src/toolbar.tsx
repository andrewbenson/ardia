import { requireNativeViewManager, requireOptionalNativeModule } from "expo-modules-core";
import type { ComponentType } from "react";
import type { NativeSyntheticEvent, ViewProps } from "react-native";

export type ToolbarClick = { id: string; kind: "press" | "menu" | "middle" | "submit" | "cancel" | "blur" | "focus"; meta: boolean; alt: boolean; shift: boolean; text: string | null };

export type NativeToolbarProps = ViewProps & {
  state: string;
  onToolbarClick?(e: NativeSyntheticEvent<ToolbarClick>): void;
  onToolbarAnchors?(e: NativeSyntheticEvent<{ anchors: Record<string, [number, number, number, number]> }>): void;
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

type SidebarAddressBarModule = { available(): boolean; set(windowId: string, json: string | null): Promise<void>; sample(windowId: string): Promise<string | null> };

const sidebarAddressBar = requireOptionalNativeModule<SidebarAddressBarModule>("SolaraSidebarAddressBar");

let sidebarAddressAvailability: boolean | null = null;

export function sidebarAddressBarAvailable(): boolean {
  if (sidebarAddressAvailability !== null) return sidebarAddressAvailability;
  try {
    sidebarAddressAvailability = !!sidebarAddressBar?.available();
  } catch {
    sidebarAddressAvailability = false;
  }
  return sidebarAddressAvailability;
}

export function setSidebarAddressBar(windowId: string, json: string | null): void {
  void sidebarAddressBar?.set(windowId, json);
}

export async function sampleSidebarAddressBar(windowId: string): Promise<unknown> {
  const json = await sidebarAddressBar?.sample(windowId);
  return json ? JSON.parse(json) : null;
}

let SidebarAddressHost: ComponentType<ViewProps & { windowId: string }> | null = null;

export function NativeSidebarAddressBarView(props: ViewProps & { windowId: string }) {
  SidebarAddressHost ??= requireNativeViewManager<ViewProps & { windowId: string }>("SolaraSidebarAddressBar") as ComponentType<ViewProps & { windowId: string }>;
  return <SidebarAddressHost {...props} />;
}

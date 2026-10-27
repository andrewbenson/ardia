import { requireNativeViewManager, requireOptionalNativeModule } from "expo-modules-core";
import type { ComponentType } from "react";
import type { ViewProps } from "react-native";

export type HostedViewProps = ViewProps & { kind: string; windowId: string; active?: boolean; state?: string };

type HostedModule = {
  kinds(): string[];
  devHost(kind: string, windowId: string, on: boolean): Promise<Record<string, string>>;
  sidebarRowFrame(windowId: string, key: string): Promise<{ x: number; y: number; width: number; height: number } | null>;
};

const native = requireOptionalNativeModule<HostedModule>("SolaraHosted");

export function hostedKinds(): string[] {
  try {
    return native?.kinds() ?? [];
  } catch {
    return [];
  }
}

export function sidebarRowFrame(windowId: string, key: string) {
  return native?.sidebarRowFrame(windowId, key) ?? Promise.resolve(null);
}

let View: ComponentType<HostedViewProps> | null = null;

export function SolaraHostedView(props: HostedViewProps) {
  View ??= requireNativeViewManager<HostedViewProps>("SolaraHosted") as ComponentType<HostedViewProps>;
  return <View {...props} />;
}

import { requireNativeViewManager, requireOptionalNativeModule } from "expo-modules-core";
import { forwardRef, type ComponentType, type Ref } from "react";
import type { NativeSyntheticEvent, ViewProps } from "react-native";

export type NativePageKind = "downloads" | "history" | "bookmarks" | "bookmarkForm";
export type NativePageEvent = { kind: string } & Record<string, unknown>;

export type NativePageProps = ViewProps & {
  kind: NativePageKind;
  state: string;
  onPageEvent?(e: NativeSyntheticEvent<NativePageEvent>): void;
};

export type NativePageHandle = { focusSearch(): Promise<void> };

const native = requireOptionalNativeModule<{ available(): boolean }>("SolaraPages");

let availability: boolean | null = null;

export function nativePagesAvailable(): boolean {
  if (availability !== null) return availability;
  try {
    availability = !!native?.available();
  } catch {
    availability = false;
  }
  return availability;
}

let View: ComponentType<NativePageProps & { ref?: Ref<NativePageHandle> }> | null = null;

export const NativePage = forwardRef<NativePageHandle, NativePageProps>(function NativePage(props, ref) {
  View ??= requireNativeViewManager<NativePageProps>("SolaraPages") as unknown as ComponentType<NativePageProps & { ref?: Ref<NativePageHandle> }>;
  return <View ref={ref} {...props} />;
});

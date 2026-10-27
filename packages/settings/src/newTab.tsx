import { requireNativeViewManager, requireOptionalNativeModule } from "expo-modules-core";
import { forwardRef, type ComponentType, type Ref } from "react";
import type { NativeSyntheticEvent, ViewProps } from "react-native";

export type NewTabDisposition = "current" | "newTab" | "newWindow";
export type NewTabJourneyMark = "committed" | "focused" | "keystroke" | "suggestions" | "navigate";
export type NewTabMenuChoice = "cut" | "copy" | "paste" | "selectAll";
export type NativeSuggestion = { kind: string } & Record<string, unknown>;

type Event<T> = NativeSyntheticEvent<T>;

export type NativeNewTabProps = ViewProps & {
  windowId: string;
  tabId: string;
  profileId: string;
  incognito: boolean;
  onboarding: boolean;
  playIntro: boolean;
  panelOpen: boolean;
  under: number;
  dark: boolean;
  theme: Record<string, string>;
  marks: { sun: string; back: string; front: string };
  driven?: boolean;
  offline?: boolean;
  onDriverState?(e: Event<{ json: string }>): void;
  onOpen?(e: Event<{ url: string; disposition: NewTabDisposition }>): void;
  onSwitch?(e: Event<{ tabId: string; url: string; disposition: NewTabDisposition }>): void;
  onAction?(e: Event<{ id: string }>): void;
  onExtension?(e: Event<{ suggestion: NativeSuggestion }>): void;
  onRemoveHistory?(e: Event<{ url: string }>): void;
  onChosen?(e: Event<{ suggestion: NativeSuggestion | null }>): void;
  onOpenChip?(e: Event<Record<string, never>>): void;
  onDictate?(e: Event<Record<string, never>>): void;
  onContextMenu?(e: Event<{ hasSelection: boolean; hasValue: boolean }>): void;
  onJourney?(e: Event<{ mark: NewTabJourneyMark }>): void;
  onLatency?(e: Event<{ ms: number }>): void;
  onBarLayout?(e: Event<{ height: number; headingHeight: number }>): void;
};

export type NativeNewTabHandle = {
  focus(): Promise<void>;
  applyMenu(choice: NewTabMenuChoice): Promise<void>;
  type(text: string): Promise<void>;
  clear(): Promise<void>;
  key(key: string, mods?: { metaKey?: boolean; altKey?: boolean; shiftKey?: boolean; ctrlKey?: boolean }): Promise<void>;
  select(start: number, end: number): Promise<void>;
  submit(): Promise<void>;
  driverState(): Promise<string>;
  measure(): Promise<{ x: number; y: number; width: number; height: number }>;
};

type NewTabModule = {
  available(): boolean;
  setTabs(profileId: string, json: string): Promise<void>;
  setHistory(profileId: string, rev: number, json: string): Promise<void>;
  patchHistory(profileId: string, base: number, rev: number, json: string): Promise<boolean>;
  setBookmarks(profileId: string, json: string): Promise<void>;
  setActions(windowId: string, json: string): Promise<void>;
  setExtensions(windowId: string, json: string): Promise<void>;
  forgetWindow(windowId: string): Promise<void>;
};

const native = requireOptionalNativeModule<NewTabModule>("SolaraNewTab");

let availability: boolean | null = null;

export function nativeNewTabAvailable(): boolean {
  if (availability !== null) return availability;
  try {
    availability = !!native?.available();
  } catch {
    availability = false;
  }
  return availability;
}

let View: ComponentType<NativeNewTabProps & { ref?: Ref<NativeNewTabHandle> }> | null = null;

export const NativeNewTab = forwardRef<NativeNewTabHandle, NativeNewTabProps>(function NativeNewTab(props, ref) {
  View ??= requireNativeViewManager<NativeNewTabProps>("SolaraNewTab") as unknown as ComponentType<NativeNewTabProps & { ref?: Ref<NativeNewTabHandle> }>;
  return <View ref={ref} {...props} />;
});

const ignore = () => {};

export const newTabSources = {
  setTabs: (profileId: string, rows: unknown[]) => native?.setTabs(profileId, JSON.stringify(rows)).catch(ignore),
  setHistory: (profileId: string, rev: number, rows: unknown[]) => native?.setHistory(profileId, rev, JSON.stringify(rows)).catch(ignore),
  patchHistory: (profileId: string, base: number, rev: number, patch: { removed: string[]; inserts: [number, unknown][] }) =>
    native?.patchHistory(profileId, base, rev, JSON.stringify(patch)).catch(() => false) ?? Promise.resolve(false),
  setBookmarks: (profileId: string, rows: unknown[]) => native?.setBookmarks(profileId, JSON.stringify(rows)).catch(ignore),
  setActions: (windowId: string, rows: unknown[]) => native?.setActions(windowId, JSON.stringify(rows)).catch(ignore),
  setExtensions: (windowId: string, rows: unknown[]) => native?.setExtensions(windowId, JSON.stringify(rows)).catch(ignore),
  forgetWindow: (windowId: string) => native?.forgetWindow(windowId).catch(ignore),
};

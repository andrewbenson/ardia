import { useSyncExternalStore } from "react";
import type { Animated, ViewStyle } from "react-native";

type StatusStyle = Animated.WithAnimatedValue<ViewStyle> | undefined;
type Owned<T> = { owner: object; value: T };

const statusStyles = new Map<string, Owned<StatusStyle>>();
const overCard = new Map<string, Owned<string | undefined>>();
const drawn = new Map<string, Set<object>>();
const listeners = new Set<() => void>();
const changed = () => {
  for (const listener of listeners) listener();
};
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const shiftOf = (style: StatusStyle) => (style as { transform?: { translateY?: unknown }[] } | undefined)?.transform?.[0]?.translateY;

function publish<T>(map: Map<string, Owned<T>>, key: string, owner: object, value: T, same: (a: T, b: T) => boolean) {
  const was = map.get(key);
  if (was && was.owner === owner && same(was.value, value)) return;
  map.set(key, { owner, value });
  changed();
}

function drop<T>(map: Map<string, Owned<T>>, key: string, owner: object) {
  if (map.get(key)?.owner !== owner) return;
  map.delete(key);
  changed();
}

export function publishPaneStatusStyle(tabId: string, owner: object, style: StatusStyle) {
  publish(statusStyles, tabId, owner, style, (a, b) => shiftOf(a) === shiftOf(b));
}

export function dropPaneStatusStyle(tabId: string, owner: object) {
  drop(statusStyles, tabId, owner);
}

export function publishPopoversOverCard(windowId: string, owner: object, tabId: string | undefined) {
  publish(overCard, windowId, owner, tabId, (a, b) => a === b);
}

export function dropPopoversOverCard(windowId: string, owner: object) {
  drop(overCard, windowId, owner);
}

export function markPaneRootDrawn(tabId: string, owner: object, isDrawn: boolean) {
  const owners = drawn.get(tabId) ?? new Set<object>();
  if (owners.has(owner) === isDrawn) return;
  if (isDrawn) owners.add(owner);
  else owners.delete(owner);
  if (owners.size) drawn.set(tabId, owners);
  else drawn.delete(tabId);
  changed();
}

export const paneStatusStyle = (tabId: string) => statusStyles.get(tabId)?.value;

export const popoversOverCard = (windowId: string) => overCard.get(windowId)?.value;

export const paneRootDrawn = (tabId: string) => !!drawn.get(tabId)?.size;

export const usePaneStatusStyle = (tabId: string) => useSyncExternalStore(subscribe, () => paneStatusStyle(tabId));

export const usePopoversOverCard = (windowId: string) => useSyncExternalStore(subscribe, () => popoversOverCard(windowId));

export const usePaneRootDrawn = (tabId: string) => useSyncExternalStore(subscribe, () => paneRootDrawn(tabId));

import type { View } from "react-native";
import { focusNativeSettingsSearch } from "@ardia/settings";
import { create } from "zustand";

type SearchUi = {
  query: string;
  selected: number;
  focusRequest: number;
  reveal: { id: string; at: number } | null;
  flash: { id: string; at: number } | null;
};

export const useSettingsSearch = create<SearchUi>(() => ({ query: "", selected: 0, focusRequest: 0, reveal: null, flash: null }));

export const setSettingsQuery = (query: string) => useSettingsSearch.setState({ query });

export const focusSettingsSearch = () => void focusNativeSettingsSearch();

export const flashSetting = (id: string) => useSettingsSearch.setState({ reveal: null, flash: { id, at: Date.now() } });

const anchors = new Map<string, View>();

export const anchorView = (id: string) => anchors.get(id);

export function registerAnchor(id: string, view: View) {
  anchors.set(id, view);
  return () => {
    if (anchors.get(id) === view) anchors.delete(id);
  };
}

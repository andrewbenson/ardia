import { publishSettingsTopic } from "@ardia/settings";
import { useEffect } from "react";
import { hex, useTheme } from "../../lib/theme";
import { useLive } from "../../live/store";
import { useBrowser } from "../../store/browser";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import { setIcon } from "./actions";
import { setSidebarUi, useSidebarUi } from "./state";
import { NO_GROUP_ICON_INK } from "./TabIcon";
import { useSidebarTokens } from "./tokens";

const EMOJI: [string, string][] = [
  ["⭐️", "star favorite"], ["🔥", "fire hot"], ["❤️", "heart love"], ["✅", "check done"], ["📌", "pin"], ["🚀", "rocket launch ship"],
  ["💡", "idea bulb"], ["📝", "note memo write"], ["📚", "books read study"], ["📖", "book read"], ["🎓", "school graduate"], ["💼", "work briefcase"],
  ["🏠", "home house"], ["🛒", "shopping cart"], ["💰", "money"], ["💳", "card pay"], ["📈", "chart growth stocks"], ["📊", "chart data"],
  ["🗓️", "calendar date"], ["⏰", "alarm time"], ["📧", "email mail"], ["💬", "chat message"], ["📞", "phone call"], ["🎥", "video camera"],
  ["🎵", "music song"], ["🎧", "headphones music"], ["🎮", "game play"], ["🎨", "art design paint"], ["📷", "photo camera"], ["🎬", "movie film"],
  ["📺", "tv watch"], ["🍿", "popcorn movie"], ["✈️", "travel plane"], ["🗺️", "map travel"], ["🏖️", "beach holiday"], ["🌍", "world earth globe"],
  ["🍕", "pizza food"], ["🍔", "burger food"], ["☕️", "coffee"], ["🍷", "wine"], ["🍎", "apple fruit"], ["🥗", "salad food healthy"],
  ["🏋️", "gym fitness"], ["⚽️", "football soccer sport"], ["🏀", "basketball sport"], ["🚴", "bike cycling"], ["🧘", "yoga calm"], ["💊", "health pill"],
  ["🐶", "dog pet"], ["🐱", "cat pet"], ["🦊", "fox"], ["🐼", "panda"], ["🦄", "unicorn"], ["🐙", "octopus github"],
  ["🌱", "plant grow"], ["🌸", "flower blossom"], ["🌈", "rainbow"], ["☀️", "sun"], ["🌙", "moon night"], ["❄️", "snow cold"],
  ["⚡️", "lightning fast"], ["💎", "gem diamond"], ["🎁", "gift present"], ["🎉", "party celebrate"], ["🏆", "trophy win"], ["🎯", "target goal"],
  ["🧠", "brain think"], ["👀", "eyes look"], ["🤖", "robot ai bot"], ["👾", "alien game"], ["💻", "laptop computer code"], ["🖥️", "desktop computer"],
  ["⌨️", "keyboard type"], ["🛠️", "tools build"], ["⚙️", "settings gear"], ["🔧", "wrench fix"], ["🧪", "test lab science"], ["🔬", "science research"],
  ["🐛", "bug"], ["🔒", "lock secure"], ["🔑", "key"], ["🧩", "puzzle extension"], ["📦", "package box"], ["🗂️", "folder files"],
  ["📁", "folder"], ["🗃️", "archive"], ["📰", "news paper"], ["🔗", "link"], ["🔍", "search find"], ["🧭", "compass explore"],
  ["🏷️", "tag label"], ["💭", "thought"], ["❓", "question"], ["❗️", "important"], ["⚠️", "warning"], ["🚧", "construction wip"],
  ["🟥", "red square"], ["🟧", "orange square"], ["🟨", "yellow square"], ["🟩", "green square"], ["🟦", "blue square"], ["🟪", "purple square"],
  ["🔴", "red circle"], ["🟠", "orange circle"], ["🟡", "yellow circle"], ["🟢", "green circle"], ["🔵", "blue circle"], ["🟣", "purple circle"],
];

const SYMBOLS = [
  "star", "heart", "bookmark", "flag", "pin", "bolt", "flame", "leaf", "globe", "house", "briefcase", "cart", "bag", "creditcard",
  "dollarsign.circle", "chart.bar", "chart.line.uptrend.xyaxis", "calendar", "clock", "alarm", "envelope", "bubble.left", "phone", "video",
  "music.note", "headphones", "gamecontroller", "paintbrush", "camera", "film", "tv", "airplane", "map", "car", "fork.knife", "cup.and.saucer",
  "figure.run", "sportscourt", "pawprint", "tree", "sun.max", "moon", "cloud", "snowflake", "sparkles", "gift", "trophy", "target", "brain",
  "eye", "laptopcomputer", "desktopcomputer", "keyboard", "hammer", "wrench.and.screwdriver", "gearshape", "testtube.2", "ant", "lock",
  "key", "puzzlepiece", "shippingbox", "folder", "archivebox", "newspaper", "link", "magnifyingglass", "safari", "tag", "lightbulb",
  "questionmark.circle", "exclamationmark.triangle", "book", "graduationcap", "doc.text", "list.bullet", "checkmark.circle", "person.2",
];

const NATIVE_TOPIC = "sidebar.iconPicker";
const nativePickers: Record<string, object> = {};

function publishNative(windowId: string, state: object | null) {
  if (state) nativePickers[windowId] = state;
  else if (nativePickers[windowId]) delete nativePickers[windowId];
  else return;
  publishSettingsTopic(NATIVE_TOPIC, { windows: nativePickers });
}

addNativeSettingsHandlers({
  [NATIVE_TOPIC]: (windowId: string, id: string, event: string, extra?: { icon?: string | null }) => {
    const picker = useSidebarUi.getState().iconPicker;
    if (!picker || picker.windowId !== windowId || picker.id !== id) return;
    if (event === "choose") setIcon(picker, extra?.icon ?? null);
    if (event === "choose" || event === "close") setSidebarUi({ iconPicker: null });
  },
});

export function IconPicker({ windowId, sidebarWidth }: { windowId: string; sidebarWidth: number }) {
  const picker = useSidebarUi((u) => (u.iconPicker?.windowId === windowId ? u.iconPicker : null));
  return <NativeIconPicker windowId={windowId} picker={picker} sidebarWidth={sidebarWidth} />;
}

type Picker = NonNullable<ReturnType<typeof useSidebarUi.getState>["iconPicker"]>;

function useCurrentIcon(picker: Picker | null) {
  const liveIcon = useLive((s) => (picker?.kind === "live" ? s.folders[picker.id.split("|")[1] ?? ""]?.icon : null));
  return useBrowser((s) => (!picker ? null : picker.kind === "tab" ? s.tabs[picker.id]?.customIcon : picker.kind === "live" ? liveIcon : s.groups[picker.id]?.icon) ?? null);
}

function NativeIconPicker({ windowId, picker, sidebarWidth }: { windowId: string; picker: Picker | null; sidebarWidth: number }) {
  const theme = useTheme();
  const tokens = useSidebarTokens();
  const current = useCurrentIcon(picker);
  const state = picker
    ? {
        id: picker.id,
        kind: picker.kind,
        current,
        anchor: picker.anchor ? [picker.anchor.x, picker.anchor.y, picker.anchor.width, picker.anchor.height] : null,
        sidebarWidth,
        dark: theme.dark,
        shadowOpacity: theme.panelShadowOpacity,
        theme: {
          panel: hex(theme.panel),
          panelBorder: hex(theme.panelBorder),
          urlPill: theme.urlPill,
          textPrimary: theme.textPrimary,
          textSecondary: theme.textSecondary,
          textTertiary: theme.textTertiary,
          placeholder: theme.placeholder,
          icon: theme.icon,
          pickerCellHover: tokens.pickerCellHover,
          noGroupIconInk: theme.dark ? NO_GROUP_ICON_INK.dark : NO_GROUP_ICON_INK.light,
        },
        emoji: EMOJI,
        symbols: SYMBOLS,
      }
    : null;
  const key = state && JSON.stringify(state);
  useEffect(() => publishNative(windowId, state), [windowId, key]);
  useEffect(() => () => publishNative(windowId, null), [windowId]);
  return null;
}

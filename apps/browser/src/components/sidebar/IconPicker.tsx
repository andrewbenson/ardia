import { hostedKinds, publishSettingsTopic, windowShellActive } from "@ardia/settings";
import { Surface, Symbol } from "@ardia/shell";
import { useEffect, useMemo, useState } from "react";
import { Pressable, ScrollView, Text, TextInput, View } from "react-native";
import { hex, useTheme } from "../../lib/theme";
import { useLive } from "../../live/store";
import { useBrowser } from "../../store/browser";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import { setIcon } from "./actions";
import { setSidebarUi, useSidebarUi } from "./state";
import { NO_GROUP_ICON, NO_GROUP_ICON_INK, SYMBOL_PREFIX } from "./TabIcon";
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

const COLUMNS = 8;
const CELL = 30;
const WIDTH = COLUMNS * CELL + 16;

const NATIVE_TOPIC = "sidebar.iconPicker";
const nativePickers: Record<string, object> = {};

const nativeIconPicker = (windowId: string) => hostedKinds().includes(NATIVE_TOPIC) && windowShellActive(windowId);

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
  if (nativeIconPicker(windowId)) return <NativeIconPicker windowId={windowId} picker={picker} sidebarWidth={sidebarWidth} />;
  return picker ? <PickerPanel key={picker.id} picker={picker} sidebarWidth={sidebarWidth} /> : null;
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

function PickerPanel({ picker, sidebarWidth }: { picker: Picker; sidebarWidth: number }) {
  const theme = useTheme();
  const tokens = useSidebarTokens();
  const current = useCurrentIcon(picker);
  const [tab, setTab] = useState<"emoji" | "symbols">(current?.startsWith(SYMBOL_PREFIX) ? "symbols" : "emoji");
  const [query, setQuery] = useState("");
  const items = useMemo(() => {
    const q = query.trim().toLowerCase();
    return tab === "emoji"
      ? EMOJI.filter(([, words]) => !q || words.includes(q)).map(([e]) => e)
      : SYMBOLS.filter((name) => !q || name.includes(q)).map((name) => SYMBOL_PREFIX + name);
  }, [tab, query]);
  const close = () => setSidebarUi({ iconPicker: null });
  const choose = (icon: string | null) => {
    setIcon(picker, icon);
    close();
  };
  const top = Math.max(8, (picker.anchor?.y ?? 60) - 8);
  const left = picker.anchor ? Math.max(8, Math.min(sidebarWidth + 6, picker.anchor.x + picker.anchor.width + 6)) : sidebarWidth + 6;

  return (
    <>
      <Pressable onPress={close} style={{ position: "absolute", left: 0, top: 0, right: 0, bottom: 0 }} />
      <Surface
        fill={hex(theme.panel)}
        cornerRadius={14}
        borderColor={hex(theme.panelBorder)}
        borderWidth={0.5}
        shadowColor="#000000"
        shadowOpacity={theme.panelShadowOpacity}
        shadowRadius={20}
        shadowOffset={[0, 8]}
        style={{ position: "absolute", top, left, width: WIDTH, padding: 8, gap: 8 }}
      >
        <View style={{ flexDirection: "row", alignItems: "center", gap: 6 }}>
          <View style={{ flex: 1, height: 26, borderRadius: 8, backgroundColor: theme.urlPill, flexDirection: "row", alignItems: "center", paddingHorizontal: 7 }}>
            <Symbol name="magnifyingglass" size={11} color={theme.textSecondary} style={{ width: 14, height: 14 }} />
            <TextInput
              autoFocus
              value={query}
              onChangeText={setQuery}
              placeholder={tab === "emoji" ? "Search emoji" : "Search icons"}
              placeholderTextColor={theme.placeholder}
              enableFocusRing={false}
              keyDownEvents={[{ key: "Escape" }]}
              onKeyDown={(e) => e.nativeEvent.key === "Escape" && close()}
              onSubmitEditing={() => items[0] && choose(items[0])}
              style={{ flex: 1, fontSize: 12, marginLeft: 5, color: theme.textPrimary, paddingVertical: 0 }}
            />
          </View>
          {(["emoji", "symbols"] as const).map((t) => (
            <Pressable key={t} onPress={() => setTab(t)}>
              <View style={{ width: 28, height: 26, borderRadius: 8, alignItems: "center", justifyContent: "center", backgroundColor: tab === t ? tokens.pickerCellHover : undefined }}>
                <Symbol name={t === "emoji" ? "face.smiling" : "star.square.on.square"} size={13} color={theme.icon} style={{ width: 16, height: 16 }} />
              </View>
            </Pressable>
          ))}
        </View>
        <ScrollView style={{ maxHeight: CELL * 6 }} showsVerticalScrollIndicator={false}>
          <View style={{ flexDirection: "row", flexWrap: "wrap" }}>
            {items.map((icon) => (
              <Cell key={icon} icon={icon} selected={icon === current} onPress={() => choose(icon)} />
            ))}
            {items.length === 0 ? <Text style={{ padding: 8, fontSize: 12, color: theme.textTertiary }}>No matches</Text> : null}
          </View>
        </ScrollView>
        {picker.kind === "group" || current ? (
          <View style={{ flexDirection: "row", gap: 6 }}>
            {picker.kind === "group" ? (
              <FooterButton label="No Icon" selected={current === NO_GROUP_ICON} onPress={() => choose(NO_GROUP_ICON)}>
                <Symbol name="square.stack.fill" size={11} weight="medium" color={theme.dark ? NO_GROUP_ICON_INK.dark : NO_GROUP_ICON_INK.light} style={{ width: 14, height: 14 }} />
              </FooterButton>
            ) : null}
            {current ? <FooterButton label="Reset Icon" selected={false} onPress={() => choose(null)} /> : null}
          </View>
        ) : null}
      </Surface>
    </>
  );
}

function FooterButton({ label, selected, onPress, children }: { label: string; selected: boolean; onPress(): void; children?: React.ReactNode }) {
  const theme = useTheme();
  const tokens = useSidebarTokens();
  return (
    <Pressable onPress={onPress} accessibilityRole="button" accessibilityLabel={label} accessibilityState={{ selected }} style={{ flex: 1 }}>
      {({ pressed }) => (
        <View
          style={{
            height: 26,
            borderRadius: 8,
            flexDirection: "row",
            gap: 5,
            alignItems: "center",
            justifyContent: "center",
            backgroundColor: pressed || selected ? tokens.pickerCellHover : theme.urlPill,
          }}
        >
          {children}
          <Text style={{ fontSize: 12, color: theme.textPrimary }}>{label}</Text>
        </View>
      )}
    </Pressable>
  );
}

function Cell({ icon, selected, onPress }: { icon: string; selected: boolean; onPress(): void }) {
  const theme = useTheme();
  const tokens = useSidebarTokens();
  const [hovered, setHovered] = useState(false);
  return (
    <Pressable onPress={onPress}>
      <View
        onMouseEnter={() => setHovered(true)}
        onMouseLeave={() => setHovered(false)}
        style={{
          width: CELL,
          height: CELL,
          borderRadius: 8,
          alignItems: "center",
          justifyContent: "center",
          backgroundColor: hovered || selected ? tokens.pickerCellHover : undefined,
        }}
      >
        {icon.startsWith(SYMBOL_PREFIX) ? (
          <Symbol name={icon.slice(SYMBOL_PREFIX.length)} size={15} color={theme.icon} style={{ width: 20, height: 20 }} />
        ) : (
          <Text style={{ fontSize: 18 }}>{icon}</Text>
        )}
      </View>
    </Pressable>
  );
}

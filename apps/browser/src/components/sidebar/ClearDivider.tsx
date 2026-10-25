import { Symbol } from "@ardia/shell";
import { memo, useEffect, useRef, useState } from "react";
import { Animated, Easing, Pressable, Text, View } from "react-native";
import { useTheme } from "../../lib/theme";
import { useHover } from "../primitives";
import { closeAllTabs } from "./menus";
import { tidyPins } from "./tidyPinsUi";

const CLEAR_DIVIDER_HEIGHT = 16;
const PADDING = 9;
const FADE_IN_MS = 120;
const FADE_OUT_MS = 160;

type DividerProps = { windowId: string; profileId: string; spaced: boolean; clear: boolean; tidy: boolean };

export const ClearDivider = memo(function ClearDivider({ windowId, profileId, spaced, clear, tidy }: DividerProps) {
  const theme = useTheme();
  const { hovered: rowHovered, hoverProps: rowHoverProps } = useHover();
  const { hovered: buttonsHovered, hoverProps: buttonsHoverProps } = useHover();
  const shown = rowHovered || buttonsHovered;
  const [buttonsWidth, setButtonsWidth] = useState(0);
  const reveal = useRef(new Animated.Value(0)).current;
  useEffect(() => {
    Animated.timing(reveal, {
      toValue: shown ? 1 : 0,
      duration: shown ? FADE_IN_MS : FADE_OUT_MS,
      easing: Easing.out(Easing.quad),
      useNativeDriver: false,
    }).start();
  }, [reveal, shown]);
  const lineInset = reveal.interpolate({ inputRange: [0, 1], outputRange: [0, buttonsWidth] });
  return (
    <View
      {...rowHoverProps}
      style={{ height: CLEAR_DIVIDER_HEIGHT, marginTop: spaced ? 7 : 0, flexDirection: "row", alignItems: "center", paddingLeft: PADDING, paddingRight: PADDING }}
    >
      <Animated.View style={{ flex: 1, height: 1, marginRight: lineInset, backgroundColor: theme.divider }} />
      <Animated.View
        {...buttonsHoverProps}
        onLayout={(e) => setButtonsWidth(e.nativeEvent.layout.width)}
        style={{ position: "absolute", right: PADDING, top: 0, bottom: 0, flexDirection: "row", alignItems: "center", opacity: reveal }}
      >
        {tidy ? <DividerButton title="Tidy" symbol="sparkles" iconWidth={10} label="Tidy pinned tabs" onPress={() => tidyPins(windowId, profileId)} /> : null}
        {tidy && clear ? <View style={{ width: 1, height: 9, marginLeft: 8, backgroundColor: theme.divider }} /> : null}
        {clear ? <DividerButton title="Clear" symbol="arrow.down" iconWidth={8} label="Clear unpinned tabs" onPress={() => closeAllTabs(windowId)} /> : null}
      </Animated.View>
    </View>
  );
});

function DividerButton({ title, symbol, iconWidth, label, onPress }: { title: string; symbol: string; iconWidth: number; label: string; onPress: () => void }) {
  const theme = useTheme();
  const { hovered, hoverProps } = useHover();
  return (
    <View {...hoverProps}>
      <Pressable tooltip={label} accessibilityRole="button" accessibilityLabel={label} onAccessibilityTap={onPress} onPress={onPress}>
        {({ pressed }) => {
          const color = pressed ? theme.textSecondary : hovered ? theme.textPrimary : theme.textTertiary;
          return (
            <View style={{ height: CLEAR_DIVIDER_HEIGHT, flexDirection: "row", alignItems: "center", paddingLeft: 8 }}>
              <Symbol name={symbol} size={9} weight="semibold" color={color} style={{ width: iconWidth, height: 11, marginRight: 3 }} />
              <Text style={{ fontSize: 10, fontWeight: "500", color }}>{title}</Text>
            </View>
          );
        }}
      </Pressable>
    </View>
  );
}

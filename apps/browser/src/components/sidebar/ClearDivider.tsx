import { Symbol } from "@ardia/shell";
import { memo, useEffect, useRef } from "react";
import { Animated, Easing, Pressable, Text, View } from "react-native";
import { useTheme } from "../../lib/theme";
import { useHover } from "../primitives";
import { closeAllTabs } from "./menus";

const CLEAR_DIVIDER_HEIGHT = 16;
const FADE_IN_MS = 120;
const FADE_OUT_MS = 160;

export const ClearDivider = memo(function ClearDivider({ windowId, spaced }: { windowId: string; spaced: boolean }) {
  const theme = useTheme();
  const { hovered: rowHovered, hoverProps: rowHoverProps } = useHover();
  const { hovered, hoverProps } = useHover();
  const shown = rowHovered || hovered;
  const opacity = useRef(new Animated.Value(0)).current;
  useEffect(() => {
    Animated.timing(opacity, {
      toValue: shown ? 1 : 0,
      duration: shown ? FADE_IN_MS : FADE_OUT_MS,
      easing: Easing.out(Easing.quad),
      useNativeDriver: true,
    }).start();
  }, [opacity, shown]);
  const clear = () => closeAllTabs(windowId);
  return (
    <View
      {...rowHoverProps}
      style={{ height: CLEAR_DIVIDER_HEIGHT, marginTop: spaced ? 7 : 0, flexDirection: "row", alignItems: "center", paddingLeft: 9, paddingRight: 9 }}
    >
      <View style={{ flex: 1, height: 1, backgroundColor: theme.divider }} />
      <Animated.View {...hoverProps} style={{ opacity }}>
        <Pressable tooltip="Clear unpinned tabs" accessibilityRole="button" accessibilityLabel="Clear unpinned tabs" onAccessibilityTap={clear} onPress={clear}>
          {({ pressed }) => {
            const color = hovered && !pressed ? theme.textPrimary : theme.textSecondary;
            return (
              <View style={{ height: CLEAR_DIVIDER_HEIGHT, flexDirection: "row", alignItems: "center", paddingLeft: 8 }}>
                <Symbol name="arrow.down" size={9} weight="bold" color={color} style={{ width: 8, height: 11, marginRight: 3 }} />
                <Text style={{ fontSize: 10, fontWeight: "600", color }}>Clear</Text>
              </View>
            );
          }}
        </Pressable>
      </Animated.View>
    </View>
  );
});

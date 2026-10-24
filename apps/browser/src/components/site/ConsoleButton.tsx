import { Symbol } from "@ardia/shell";
import { memo } from "react";
import { Pressable, Text, View } from "react-native";
import { webviews } from "../../lib/webviews";
import { useHover } from "../primitives";
import { usePage } from "../layout/pageState";
import type { ToolbarPalette } from "../layout/toolbarColors";

const ERROR = "#FF5F57";
const WARNING = "#F2B33D";

const plural = (n: number, one: string) => `${n} ${one}${n === 1 ? "" : "s"}`;

export const ConsoleButton = memo(function ConsoleButton({ tabId, palette, onFocus }: { tabId: string; palette: ToolbarPalette; onFocus: () => void }) {
  const errors = usePage(tabId, (p) => p.console?.errors ?? 0);
  const warnings = usePage(tabId, (p) => p.console?.warnings ?? 0);
  const { hovered, hoverProps } = useHover();
  const tooltip = errors || warnings ? `${[errors && plural(errors, "error"), warnings && plural(warnings, "warning")].filter(Boolean).join(", ")} · Open Console` : "Open Console";
  const count = (n: number, icon: string, color: string) =>
    n > 0 ? (
      <View style={{ flexDirection: "row", alignItems: "center", gap: 3 }}>
        <Symbol name={icon} size={11} weight="semibold" color={color} style={{ width: 13, height: 13 }} />
        <Text style={{ fontSize: 12, fontWeight: "500", fontVariant: ["tabular-nums"], color: palette.text }}>{n > 999 ? "999+" : String(n)}</Text>
      </View>
    ) : null;
  return (
    <Pressable
      {...hoverProps}
      accessibilityLabel={tooltip}
      tooltip={tooltip}
      onPress={() => {
        onFocus();
        void webviews.get(tabId)?.showDevTools("console");
      }}
    >
      {({ pressed }) => (
        <View
          style={{
            height: 24,
            minWidth: 24,
            paddingHorizontal: errors || warnings ? 6 : 0,
            borderRadius: 6,
            flexDirection: "row",
            alignItems: "center",
            justifyContent: "center",
            gap: 6,
            backgroundColor: pressed ? palette.pressed : hovered ? palette.hover : undefined,
          }}
        >
          {errors || warnings ? (
            <>
              {count(errors, "xmark.octagon.fill", ERROR)}
              {count(warnings, "exclamationmark.triangle.fill", WARNING)}
            </>
          ) : (
            <Symbol name="terminal" size={13} color={palette.icon} style={{ width: 18, height: 18 }} />
          )}
        </View>
      )}
    </Pressable>
  );
});

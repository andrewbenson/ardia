import { Symbol } from "@ardia/shell";
import { useState } from "react";
import { Text, View } from "react-native";
import { useTheme } from "../../lib/theme";
import { headingTop } from "./newTabLayout";

export const INCOGNITO_ICON = "eyeglasses";

export function IncognitoHeading({ left, barTop, width, onHeight }: { left: number; barTop: number; width: number; onHeight: (height: number) => void }) {
  const theme = useTheme();
  const [height, setHeight] = useState(0);
  return (
    <View
      pointerEvents="none"
      onLayout={(e) => {
        setHeight(e.nativeEvent.layout.height);
        onHeight(e.nativeEvent.layout.height);
      }}
      style={{ position: "absolute", left, top: headingTop(barTop, height), width, alignItems: "center", gap: 6, opacity: height ? 1 : 0 }}
    >
      <View style={{ flexDirection: "row", alignItems: "center", gap: 10 }}>
        <Symbol name={INCOGNITO_ICON} size={24} weight="medium" color={theme.textPrimary} style={{ width: 32, height: 28 }} />
        <Text accessibilityRole="header" numberOfLines={1} style={{ fontSize: 30, fontWeight: "700", letterSpacing: -0.4, color: theme.textPrimary }}>
          Incognito
        </Text>
      </View>
      <Text style={{ fontSize: 13, lineHeight: 18, color: theme.textSecondary, textAlign: "center", maxWidth: 460 }}>
        Pages you visit here aren't saved to your history. Cookies and site data are deleted when you close all Incognito windows.
      </Text>
    </View>
  );
}

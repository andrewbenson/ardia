import { View } from "react-native";
import { useTheme } from "../../lib/theme";

function onboardingColors(dark: boolean) {
  return dark
    ? {
        background: "#000000",
        overlay: "rgba(0,0,0,0.6)",
        card: "#161616",
        cardBorder: "rgba(254,255,255,0.3)",
        title: "#FEFFFF",
        subtitle: "rgba(254,255,255,0.6)",
        body: "rgba(255,255,255,0.55)",
        footnote: "rgba(255,255,255,0.5)",
        steps: "rgba(255,255,255,0.3)",
        row: "rgba(255,255,255,0.08)",
        rowBorder: "rgba(255,255,255,0.16)",
        rowSubtitle: "rgba(255,255,255,0.6)",
        primary: "rgba(255,255,255,0.85)",
        primaryHover: "rgba(255,255,255,0.9)",
        primaryText: "#000000",
        button: "rgba(255,255,255,0.08)",
        buttonHover: "rgba(255,255,255,0.1)",
        buttonText: "#FFFFFF",
        outlinedHover: "rgba(255,255,255,0.03)",
        noThanksBorder: "rgba(254,255,255,0.2)",
        noThanksText: "rgba(254,255,255,0.5)",
        iconContainer: "rgba(255,255,255,0.15)",
        separator: "rgba(254,255,255,0.1)",
        preview: "rgba(255,255,255,0.04)",
        previewBorder: "rgba(255,255,255,0.1)",
        progressTrack: "rgba(255,255,255,0.12)",
        progressFill: "#FDD023",
        checkbox: "rgba(255,255,255,0.1)",
        checkboxBorder: "rgba(255,255,255,0.25)",
        checkboxOn: "#FEFFFF",
        checkmark: "#000000",
      }
    : {
        background: "#FEFFFF",
        overlay: "rgba(254,255,255,0.6)",
        card: "#FFFFFF",
        cardBorder: "rgba(0,0,0,0.08)",
        title: "#000000",
        subtitle: "rgba(0,0,0,0.53)",
        body: "rgba(0,0,0,0.55)",
        footnote: "rgba(0,0,0,0.5)",
        steps: "rgba(0,0,0,0.3)",
        row: "rgba(0,0,0,0.015)",
        rowBorder: "rgba(0,0,0,0.08)",
        rowSubtitle: "rgba(0,0,0,0.6)",
        primary: "rgba(0,0,0,0.85)",
        primaryHover: "rgba(0,0,0,0.9)",
        primaryText: "#FEFFFF",
        button: "rgba(0,0,0,0.08)",
        buttonHover: "rgba(0,0,0,0.1)",
        buttonText: "#000000",
        outlinedHover: "rgba(0,0,0,0.03)",
        noThanksBorder: "rgba(0,0,0,0.1)",
        noThanksText: "rgba(0,0,0,0.5)",
        iconContainer: "rgba(0,0,0,0.03)",
        separator: "rgba(0,0,0,0.1)",
        preview: "rgba(0,0,0,0.025)",
        previewBorder: "rgba(0,0,0,0.07)",
        progressTrack: "rgba(0,0,0,0.08)",
        progressFill: "#FDD023",
        checkbox: "#FFFFFF",
        checkboxBorder: "rgba(0,0,0,0.2)",
        checkboxOn: "#000000",
        checkmark: "#FFFFFF",
      };
}

export const useOnboardingColors = () => onboardingColors(useTheme().dark);

export function Radio({ on }: { on: boolean }) {
  const colors = useOnboardingColors();
  return (
    <View style={{ width: 16, height: 16, borderRadius: 8, borderWidth: on ? 5 : 1.5, borderColor: on ? colors.checkboxOn : colors.checkboxBorder, backgroundColor: colors.checkbox }} />
  );
}


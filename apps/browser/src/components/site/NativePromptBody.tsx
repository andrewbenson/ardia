import { NativePromptView, type NativePromptEvent } from "@ardia/settings";
import { useState } from "react";
import { StyleSheet, View } from "react-native";
import { useTheme } from "../../lib/theme";
import { useFormColors } from "../settings/controls";

export type PromptLine = { text: string; strong?: boolean; tone?: "primary" | "secondary"; size?: number; kern?: number; maxLines?: number };
export type PromptDetail =
  | { kind: "well"; sections: { label?: string; lines: PromptLine[] }[] }
  | { kind: "choices"; choices: { id: string; title: string; selected: boolean }[] }
  | { kind: "checkbox"; label: string; value: boolean }
  | { kind: "note"; text: string };
export type PromptSpec = {
  icons: string[];
  image?: string | null;
  title: string;
  message?: string | null;
  details?: PromptDetail[];
  buttons: { id: string; title: string; primary?: boolean }[];
  close?: boolean;
};

export function NativePromptBody({
  spec,
  onButton,
  onChoice,
  onToggle,
  onClose,
}: {
  spec: PromptSpec;
  onButton(id: string): void;
  onChoice?(id: string): void;
  onToggle?(value: boolean): void;
  onClose?(): void;
}) {
  const theme = useTheme();
  const colors = useFormColors();
  const [height, setHeight] = useState<number | null>(null);
  const state = JSON.stringify({
    icons: spec.icons,
    image: spec.image ?? null,
    title: spec.title,
    message: spec.message ?? null,
    details: spec.details ?? [],
    buttons: spec.buttons,
    close: spec.close ?? true,
    dark: !!theme.dark,
    theme: { textPrimary: theme.textPrimary, textSecondary: theme.textSecondary, toolbarHover: theme.toolbarHover, rowHover: theme.rowHover, icon: theme.icon, accent: colors.accent },
    control: colors.control,
    controlBorder: colors.controlBorder,
    goButton: theme.goButton,
    goButtonText: theme.goButtonText,
  });
  const onEvent = (e: NativePromptEvent) => {
    if (e.kind === "button") onButton(e.id);
    else if (e.kind === "choice") onChoice?.(e.id);
    else if (e.kind === "toggle") onToggle?.(e.value);
    else onClose?.();
  };
  return (
    <View style={{ height: height ?? undefined, minHeight: 1 }}>
      <NativePromptView style={StyleSheet.absoluteFill} state={state} onPromptEvent={(e) => onEvent(e.nativeEvent)} onPromptHeight={(e) => setHeight(e.nativeEvent.height)} />
    </View>
  );
}

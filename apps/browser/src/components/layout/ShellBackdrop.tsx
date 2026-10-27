import { setWindowShellBackdrop, windowShellActive } from "@ardia/settings";
import { WindowBackdrop } from "@ardia/shaders";
import { useEffect, useState } from "react";
import { StyleSheet } from "react-native";
import { useTheme } from "../../lib/theme";
import { useWindowId } from "../../store/hooks";

export function useWindowShell(): boolean {
  const windowId = useWindowId();
  const [active] = useState(() => windowShellActive(windowId));
  return active;
}

export function ShellBackdrop({ shell }: { shell: boolean }) {
  const theme = useTheme();
  const windowId = useWindowId();
  const json = JSON.stringify({ vibrancy: true, colors: theme.windowTint, angle: 180, grainScale: 1, ...theme.backdrop, grainOpacity: theme.grain });
  useEffect(() => {
    if (shell) void setWindowShellBackdrop(windowId, json);
  }, [shell, windowId, json]);
  if (shell) return null;
  return <WindowBackdrop vibrancy {...theme.backdrop} colors={theme.windowTint} grainOpacity={theme.grain} style={StyleSheet.absoluteFill} />;
}

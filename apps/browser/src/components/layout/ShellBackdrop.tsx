import { setProfilePagerLooks, setWindowShellBackdrop, windowShellActive } from "@solara/settings";
import { WindowBackdrop } from "@solara/shaders";
import { useEffect, useMemo, useState } from "react";
import { StyleSheet } from "react-native";
import { profileTheme, spaceLookSource, useTheme, type Theme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { useWindowId } from "../../store/hooks";
import { pagerFor } from "./profilePager";

export function useWindowShell(): boolean {
  const windowId = useWindowId();
  const [active] = useState(() => windowShellActive(windowId));
  return active;
}

const backdropLook = (theme: Theme) => ({ vibrancy: true, colors: theme.windowTint, angle: 180, grainScale: 1, ...theme.backdrop, grainOpacity: theme.grain });

function useProfileLooks(windowId: string) {
  const [native] = useState(() => pagerFor(windowId).nativeOwned);
  const profiles = useBrowser((s) => s.profiles);
  const appDark = useBrowser((s) => s.ui.appDark);
  const source = useBrowser((s) => spaceLookSource(s.settings));
  const json = useMemo(
    () => (native ? JSON.stringify(Object.fromEntries(Object.entries(profiles).map(([id, p]) => [id, backdropLook(profileTheme(p, appDark, source))]))) : null),
    [native, profiles, appDark, source],
  );
  useEffect(() => {
    if (json) void setProfilePagerLooks(json);
  }, [json]);
}

export function ShellBackdrop({ shell }: { shell: boolean }) {
  const theme = useTheme();
  const windowId = useWindowId();
  useProfileLooks(windowId);
  const json = JSON.stringify(backdropLook(theme));
  useEffect(() => {
    if (shell) void setWindowShellBackdrop(windowId, json);
  }, [shell, windowId, json]);
  if (shell) return null;
  return <WindowBackdrop vibrancy {...theme.backdrop} colors={theme.windowTint} grainOpacity={theme.grain} style={StyleSheet.absoluteFill} />;
}

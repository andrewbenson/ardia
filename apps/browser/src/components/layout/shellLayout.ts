import { setWindowShellLayout, windowShellActive } from "@ardia/settings";
import { useEffect, useState } from "react";
import type { Animated } from "react-native";

type ShellLayout = { sidebarWidth: number; topTabs: boolean; fullscreen: boolean; addressBarInSidebar: boolean; away: boolean };

export const current = (value: Animated.Value) => (value as unknown as { __getValue(): number }).__getValue();

export function nextFrame(push: () => void): () => void {
  let pending = false;
  return () => {
    if (pending) return;
    pending = true;
    requestAnimationFrame(() => {
      pending = false;
      push();
    });
  };
}

export function useShellLayoutPush(windowId: string, dock: Animated.Value, layout: ShellLayout) {
  const [shell] = useState(() => windowShellActive(windowId));
  useEffect(() => {
    if (!shell) return;
    const sub = dock.addListener(nextFrame(() => void setWindowShellLayout(windowId, { dock: current(dock) })));
    return () => dock.removeListener(sub);
  }, [shell, windowId, dock]);
  const { sidebarWidth, topTabs, fullscreen, addressBarInSidebar, away } = layout;
  useEffect(() => {
    if (shell) requestAnimationFrame(() => void setWindowShellLayout(windowId, { dock: current(dock), sidebarWidth, topTabs, fullscreen, addressBarInSidebar, away }));
  }, [shell, windowId, dock, sidebarWidth, topTabs, fullscreen, addressBarInSidebar, away]);
}

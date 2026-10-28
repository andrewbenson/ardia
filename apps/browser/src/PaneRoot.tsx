import { useEffect } from "react";
import { AppRegistry, View } from "react-native";
import { PaneContent } from "./components/ContentCard";
import { ThemeScope } from "./lib/theme";
import { useBrowser } from "./store/browser";
import { WindowContext } from "./store/hooks";

const mounted = { count: 0 };
if (__DEV__) (globalThis as { acPaneRoots?: typeof mounted }).acPaneRoots = mounted;

function PaneRoot({ windowId, tabId, shown = false }: { windowId: string; tabId: string; shown?: boolean }) {
  useEffect(() => {
    mounted.count++;
    return () => {
      mounted.count--;
    };
  }, []);
  const exists = useBrowser((s) => !!s.windows[windowId]?.tabIds.includes(tabId));
  if (!exists) return null;
  return (
    <WindowContext.Provider value={windowId}>
      <ThemeScope>
        <View pointerEvents="box-none" style={{ flex: 1 }}>
          <PaneContent windowId={windowId} tabId={tabId} shown={shown} />
        </View>
      </ThemeScope>
    </WindowContext.Provider>
  );
}

export function registerPaneRoot() {
  AppRegistry.registerComponent("pane", () => PaneRoot);
}

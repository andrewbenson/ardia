import { Component, Fragment, type ReactNode } from "react";
import { Pressable, ScrollView, Text, View } from "react-native";
import { recordJsError } from "../lib/jsErrors";
import { ThemeScope, useTheme } from "../lib/theme";
import { WindowContext } from "../store/hooks";

const AUTO_RETRIES = 2;
const RETRY_DELAYS_MS = [300, 1200];
const CALM_AFTER_MS = 60_000;

type Props = { area: string; windowId?: string; quiet?: boolean; children: ReactNode };
type State = { error: Error | null; mount: number; retries: number; lastErrorAt: number };

export class AreaBoundary extends Component<Props, State> {
  state: State = { error: null, mount: 0, retries: 0, lastErrorAt: 0 };
  private retryTimer: ReturnType<typeof setTimeout> | undefined;

  static getDerivedStateFromError(error: Error) {
    return { error };
  }

  componentDidCatch(error: Error) {
    recordJsError(error, "render", this.props.area);
    if (__DEV__) (globalThis as { __lastRenderError?: string }).__lastRenderError = `${error.message}\n${error.stack ?? ""}`;
    const now = Date.now();
    const retries = now - this.state.lastErrorAt > CALM_AFTER_MS ? 0 : this.state.retries;
    this.setState({ retries, lastErrorAt: now });
    if (retries >= AUTO_RETRIES) return;
    clearTimeout(this.retryTimer);
    this.retryTimer = setTimeout(() => this.remount(retries + 1), RETRY_DELAYS_MS[retries] ?? RETRY_DELAYS_MS.at(-1));
  }

  componentWillUnmount() {
    clearTimeout(this.retryTimer);
  }

  private remount(retries: number) {
    this.setState((s) => ({ error: null, mount: s.mount + 1, retries }));
  }

  private reload = () => this.remount(0);

  render() {
    if (!this.state.error) return <Fragment key={this.state.mount}>{this.props.children}</Fragment>;
    if (this.state.retries < AUTO_RETRIES || this.props.quiet) return null;
    const row = <AreaErrorRow fill={this.props.area === "window"} detail={__DEV__ ? this.state.error : null} onReload={this.reload} />;
    if (!this.props.windowId) return row;
    return (
      <WindowContext.Provider value={this.props.windowId}>
        <ThemeScope>{row}</ThemeScope>
      </WindowContext.Provider>
    );
  }
}

function AreaErrorRow({ fill, detail, onReload }: { fill: boolean; detail: Error | null; onReload: () => void }) {
  const theme = useTheme();
  return (
    <View style={fill ? { flex: 1, alignItems: "center", justifyContent: "center", padding: 16 } : { padding: 12 }}>
      <View style={{ flexDirection: "row", alignItems: "center" }}>
        <Text style={{ fontSize: 12, color: theme.textSecondary }}>Something went wrong · </Text>
        <Pressable accessibilityRole="button" accessibilityLabel="Reload" onPress={onReload}>
          {({ pressed }) => <Text style={{ fontSize: 12, fontWeight: "500", color: pressed ? theme.textSecondary : theme.textPrimary }}>Reload</Text>}
        </Pressable>
      </View>
      {detail ? (
        <ScrollView style={{ marginTop: 12, maxHeight: 320, alignSelf: "stretch" }}>
          <Text style={{ color: "#ff8a8a", fontSize: 11, fontFamily: "Menlo" }}>
            {detail.message}
            {"\n\n"}
            {detail.stack}
          </Text>
        </ScrollView>
      ) : null}
    </View>
  );
}

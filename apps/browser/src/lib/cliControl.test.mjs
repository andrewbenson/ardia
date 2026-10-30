import assert from "node:assert/strict";
import { test } from "node:test";

globalThis.__DEV__ = false;
const { useBrowser } = await import("../store/browser.ts");
const cli = await import("./cliControl.ts");

test("Stop turns off the native-backed CLI setting", () => {
  useBrowser.getState().updateSettings({ cliControl: true });
  cli.stopCliControl();
  assert.equal(useBrowser.getState().settings.cliControl, false);
});

test("the command is the app's name in lowercase, so a fork ships its own", async () => {
  const { appInfo } = await import("../test-native/index.ts");
  assert.equal(cli.cliProduct(), "Ardia");
  assert.equal(cli.cliCommand(), "ardia");
  appInfo.appName = "Solara";
  try {
    assert.equal(cli.cliProduct(), "Solara");
    assert.equal(cli.cliCommand(), "solara");
  } finally {
    delete appInfo.appName;
  }
  assert.equal(cli.cliCommand(), "ardia");
});

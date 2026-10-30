import assert from "node:assert/strict";
import { test } from "node:test";

globalThis.__DEV__ = false;
const reasons = [];
const replies = [];
let installedVersion = null;
let legacyInstalls = 0;
globalThis.acTestNativeModules = {
  SolaraSettings: {
    servicesActive: () => false,
    installCli: (reason) => {
      reasons.push(reason);
      return new Promise((resolve, reject) => replies.push({ resolve, reject }));
    },
  },
  ArdiaCli: {
    installedVersion: () => installedVersion,
    install: async () => {
      legacyInstalls++;
      return { ok: false, appVersion: "", error: "The legacy installer ran.", lines: [] };
    },
    addListener: () => ({ remove() {} }),
  },
};
const cli = await import("./cliControl.ts");
const { documentWrites } = await import("../test-native/index.ts");

test("an install from the RN pane runs in Swift with the old native-services switch off", async () => {
  const writes = documentWrites.length;
  const pending = cli.installCliInBackground("settings");
  assert.equal(cli.useCli.getState().installing, "settings");
  assert.deepEqual(reasons, ["settings"]);
  replies.shift().resolve({ ok: false, appVersion: "0.1.0", error: "The installer stopped in Swift.", lines: [] });
  const result = await pending;
  assert.equal(result.error, "The installer stopped in Swift.");
  assert.equal(cli.useCli.getState().installing, null);
  assert.equal(cli.useCli.getState().error, "The installer stopped in Swift.");
  assert.equal(legacyInstalls, 0);
  assert.equal(documentWrites.length, writes);
});

test("concurrent install requests share one native install and publish its success", async () => {
  const writes = documentWrites.length;
  const pending = cli.installCliInBackground("onboarding");
  assert.equal(cli.installCliInBackground("settings"), pending);
  assert.equal(cli.useCli.getState().installing, "onboarding");
  assert.deepEqual(reasons, ["settings", "onboarding"]);
  installedVersion = "0.2.0";
  replies.shift().resolve({ ok: true, appVersion: "0.2.0", version: "0.2.0", binPath: "/fixture/bin/solara", lines: [] });
  const result = await pending;
  assert.equal(result.ok, true);
  assert.equal(cli.useCli.getState().installing, null);
  assert.equal(cli.useCli.getState().installedVersion, "0.2.0");
  assert.equal(cli.useCli.getState().binPath, "/fixture/bin/solara");
  assert.equal(cli.useCli.getState().error, null);
  assert.equal(legacyInstalls, 0);
  assert.equal(documentWrites.length, writes);
});

test("a native install rejection clears the pending state so a later attempt can run", async () => {
  const pending = cli.installCliInBackground("settings");
  replies.shift().reject(new Error("Native installer unavailable."));
  const result = await pending;
  assert.equal(result.ok, false);
  assert.equal(result.error, "Native installer unavailable.");
  assert.equal(cli.useCli.getState().installing, null);
  assert.equal(cli.useCli.getState().error, "Native installer unavailable.");
  const retry = cli.installCliInBackground("settings");
  assert.notEqual(retry, pending);
  replies.shift().resolve({ ok: false, appVersion: "0.2.0", lines: [] });
  await retry;
  assert.equal(cli.useCli.getState().error, "The installer stopped.");
  assert.equal(legacyInstalls, 0);
});

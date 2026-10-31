import assert from "node:assert/strict";
import { declaration, runNative, source } from "../test-native/safe-host/run.mjs";
import { test } from "node:test";

const sent = [];
globalThis.acTestNativeModules = {
  SolaraStoreAdapter: {
    status: () => ({ active: true, scope: "everything", safeMode: "option" }),
    dispatch: (json) => { sent.push(...[JSON.parse(json)].flat()); return JSON.stringify({ rev: 0 }); },
    addListener: () => ({ remove() {} }),
  },
};
const { shellNativeModules } = await import("../test-native/shell.ts");
const notices = [];
shellNativeModules.SolaraShell.confirm = async (options) => { notices.push(options); return { confirmed: false, suppressed: false }; };
const { useBrowser } = await import("../store/browser.ts");
const { startNativeStore, attachReplica } = await import("../store/nativeStore.ts");

test("native workspace action wrapping keeps the safe profile-deletion explanation", () => {
  startNativeStore();
  attachReplica(useBrowser);
  useBrowser.getState().deleteProfile("default");
  assert.equal(notices.length, 1);
  assert.equal(notices[0].title, "Safe Mode");
  assert.match(notices[0].message, /can't be deleted in safe mode/);
  assert.equal(sent.some((c) => c.name === "deleteProfile"), false);
  assert.ok(useBrowser.getState().profiles.default);
  assert.deepEqual(useBrowser.getState().orphanedProfileData, []);
});

test("SolaraCoreHost refuses loaded and unloaded profile deletion with a reason before engine or disk access", () => {
  const method = declaration(source("packages/solaracore/ios/SolaraCoreHost.mm"), "+ (void)deleteProfileData:");
  const results = runNative("Profile.mm", method);
  assert.equal(results.length, 4);
  for (const result of results) {
    assert.equal(result.callbacks, 1);
    if (result.safe) {
      assert.deepEqual(result.remaining, ["safe mode"]);
      assert.equal(result.engineLookups, 0);
      assert.equal(result.profileLookups, 0);
      assert.equal(result.engineCalls, 0);
      assert.equal(result.deletedProfiles, 0);
      assert.equal(result.directoryExists, true);
      assert.equal(result.bookmarksKept, true);
      assert.equal(result.historyKept, true);
    } else {
      assert.deepEqual(result.remaining, []);
      assert.equal(result.engineLookups, 1);
      assert.equal(result.profileLookups, 1);
      assert.equal(result.engineCalls, result.loaded ? 1 : 0);
      assert.equal(result.deletedProfiles, 1);
      assert.equal(result.directoryExists, result.loaded);
      assert.equal(result.bookmarksKept, result.loaded);
      assert.equal(result.historyKept, result.loaded);
    }
  }
});

test("SolaraCoreProfileData refuses default-profile deletion with a reason before calling services", () => {
  const results = runNative("Profile.swift", source("packages/solaracore/ios/SolaraCoreProfileData.swift"), [], true);
  assert.deepEqual(results[0], { safe: true, remaining: ["safe mode"], callbacks: 1, calls: [] });
  assert.equal(results[1].safe, false);
  assert.deepEqual(results[1].remaining, []);
  assert.equal(results[1].callbacks, 1);
  assert.deepEqual(results[1].calls, [
    "clearBrowsingData", "ac_browsing_data_clear", "listPasswords", "listPasswords", "neverSaveOrigins", "neverSaveOrigins",
    "addresses", "addresses", "cards", "cards", "listExtensions", "listExtensions", "siteSettingsOrigins", "siteSettingsOrigins", "zoomLevels", "zoomLevels",
  ]);
});

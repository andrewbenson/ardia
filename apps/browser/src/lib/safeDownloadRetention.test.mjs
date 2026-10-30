import assert from "node:assert/strict";
import { test } from "node:test";
import { declaration, runNative, source } from "../test-native/safe-host/run.mjs";

let safeMode = "option";
globalThis.acTestNativeModules = { ArdiaStore: { status: () => ({ active: false, safeMode }) } };
const { useBrowser } = await import("../store/browser.ts");
const { startNativeStore } = await import("../store/nativeStore.ts");

const saved = Array.from({ length: 100 }, (_, i) => ({
  id: `saved-${i}`, url: `https://download.example/${i}`, filename: `${i}.txt`, path: `/fixture/${i}.txt`,
  state: "finished", received: 1, total: 1, speed: 0, mimeType: "text/plain", profile: "",
}));
const replay = { ...saved[0], id: "engine-42" };

for (const mode of ["option", "failedLaunches", null]) {
  test(`download replay preserves saved list entries in safe mode: ${mode}`, () => {
    safeMode = mode;
    startNativeStore();
    useBrowser.setState({ downloads: saved });
    useBrowser.getState().upsertDownload(replay);
    useBrowser.getState().upsertDownload({ ...replay, received: 2 });
    const ids = useBrowser.getState().downloads.map((d) => d.id);
    assert.deepEqual(ids, ["engine-42", ...saved.slice(0, mode === null ? 99 : 100).map((d) => d.id)]);
    assert.equal(useBrowser.getState().downloads[0].received, 2);
    useBrowser.getState().removeDownload("saved-0");
    assert.equal(useBrowser.getState().downloads.some((d) => d.id === "saved-0"), false);
    useBrowser.getState().clearDownloads();
    assert.deepEqual(useBrowser.getState().downloads, []);
  });
}

test("native download replay preserves saved list entries while safe user removal still works", () => {
  const text = source("native/SolaraKit/Sources/SolaraStore/ProfileActions.swift");
  const production = ["public func upsertDownload(", "public func removeDownload("]
    .map((signature) => declaration(text, signature)).join("\n");
  const [safe, normal] = runNative("DownloadRetention.swift", production, [], true);
  const ids = saved.map((d) => d.id);
  assert.deepEqual(safe, { safe: true, replayed: ["engine-42", ...ids], removed: ["engine-42", ...ids.slice(1)] });
  assert.deepEqual(normal, { safe: false, replayed: ["engine-42", ...ids.slice(0, 99)], removed: ["engine-42", ...ids.slice(1, 99)] });
});

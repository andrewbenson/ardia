import assert from "node:assert/strict";
import test from "node:test";
import { fixtureReady, querySample, validateFixtureManifest } from "./omnibox-gate.mjs";

const manifest = { version: 1, seed: "big", migrated: true, offline: true, origin: "http://127.0.0.1:47817", tabs: 200, source: { tabs: 158, bookmarks: 822 }, catalogs: { "": { history: 5000, bookmarks: 900 }, work: { history: 800, bookmarks: 100 } } };
const snapshot = () => ({ tabs: 200, profileId: "default", source: { sourceMode: "js-feed", engineProfile: "", bookmarkEngineProfile: "", history: 5000, bookmarks: 822, tabs: 158 }, catalogs: Object.fromEntries(Object.entries(manifest.catalogs).map(([engine, counts]) => [engine, { history: { ready: true, count: counts.history }, bookmarks: { ready: true, count: counts.bookmarks } }])) });

test("fixture manifest rejects legacy, small and different-port inputs", () => {
  assert.equal(validateFixtureManifest(manifest, manifest.origin), manifest);
  for (const changed of [{ migrated: false }, { offline: false }, { tabs: 1 }, { source: { tabs: 158, bookmarks: 0 } }]) assert.throws(() => validateFixtureManifest({ ...manifest, ...changed }, manifest.origin));
  assert.throws(() => validateFixtureManifest(manifest, "http://127.0.0.1:47818"));
});

test("readiness requires raw catalogs, projected sources and the actual source route", () => {
  assert.equal(fixtureReady(snapshot(), manifest, "js-feed"), true);
  assert.equal(fixtureReady(snapshot(), manifest, "native-store"), false);
  const unready = snapshot();
  unready.catalogs.work.history.ready = false;
  assert.equal(fixtureReady(unready, manifest, "js-feed"), false);
  const lagging = snapshot();
  lagging.source.bookmarks--;
  assert.equal(fixtureReady(lagging, manifest, "js-feed"), false);
  const extra = snapshot();
  extra.tabs++;
  assert.equal(fixtureReady(extra, manifest, "js-feed", 1), false);
  extra.source.tabs++;
  assert.equal(fixtureReady(extra, manifest, "js-feed", 1), true);
  const missing = snapshot();
  missing.catalogs[""].bookmarks.count--;
  assert.equal(fixtureReady(missing, manifest, "js-feed"), false);
});

test("a query needs its own tab, fresh generation, commit and presentation", () => {
  const good = { tabId: "t", query: "n", generation: "epoch:2", keyAt: 100, committedAt: 102, shownAt: 103 };
  assert.deepEqual(querySample({ queries: [good] }, "t", "n", 100), good);
  for (const changed of [{ invalidated: true }, { tabId: "other" }, { query: "old" }, { keyAt: 90 }, { committedAt: 99 }, { shownAt: undefined }, { shownAt: 101 }]) assert.equal(querySample({ queries: [{ ...good, ...changed }] }, "t", "n", 100), undefined);
  assert.equal(querySample({ queries: [good] }, "t", "n", 100, [good]), undefined);
  assert.equal(querySample({ samples: { j2_suggest: [1] }, queries: [] }, "t", "n", 100), undefined);
});

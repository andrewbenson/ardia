export function validateFixtureManifest(manifest, origin) {
  if (manifest?.version !== 1 || manifest.seed !== "big" || manifest.migrated !== true || manifest.offline !== true) throw new Error("expected a migrated big omnibox fixture v1");
  if (manifest.origin !== origin) throw new Error(`fixture origin ${manifest.origin} differs from ${origin}; use --page-port from fixture.json`);
  if (manifest.tabs !== 200 || manifest.source?.tabs !== 158 || manifest.catalogs?.[""]?.history !== 5000 || manifest.catalogs?.[""]?.bookmarks !== 900 || manifest.catalogs?.work?.history !== 800 || manifest.catalogs?.work?.bookmarks !== 100) throw new Error("fixture counts differ from seed.mjs big");
  if (!Number.isInteger(manifest.source.bookmarks) || manifest.source.bookmarks <= 0 || manifest.source.bookmarks > 900) throw new Error("invalid deduplicated bookmark count");
  return manifest;
}

export function fixtureReady(snapshot, manifest, mode, extraTabs = 0) {
  if (!snapshot || snapshot.tabs !== manifest.tabs + extraTabs || snapshot.profileId !== "default") return false;
  for (const [engine, counts] of Object.entries(manifest.catalogs)) {
    const catalog = snapshot.catalogs?.[engine];
    if (!catalog?.history?.ready || !catalog?.bookmarks?.ready || catalog.history.count !== counts.history || catalog.bookmarks.count !== counts.bookmarks) return false;
  }
  const source = snapshot.source;
  return source?.sourceMode === mode && source.engineProfile === "" && source.bookmarkEngineProfile === "" && source.history === 5000 && source.bookmarks === manifest.source.bookmarks && source.tabs === manifest.source.tabs + extraTabs;
}

export function querySample(state, tabId, query, after, previous = []) {
  const seen = new Set(previous.map((sample) => sample.generation));
  return state.queries?.find((sample) => sample.invalidated !== true && sample.tabId === tabId && sample.query === query && typeof sample.generation === "string" && !seen.has(sample.generation) && Number.isFinite(sample.keyAt) && sample.keyAt >= after - 1 && Number.isFinite(sample.committedAt) && sample.committedAt >= sample.keyAt && Number.isFinite(sample.shownAt) && sample.shownAt >= sample.committedAt);
}

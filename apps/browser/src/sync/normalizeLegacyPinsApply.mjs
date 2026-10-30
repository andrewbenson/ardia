import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { registerHooks } from "node:module";
import { deflateRawSync, inflateRawSync } from "node:zlib";

registerHooks({
  load(url, context, next) {
    const loaded = next(url, context);
    if (loaded.source == null) return loaded;
    let source = typeof loaded.source === "string" ? loaded.source : new TextDecoder().decode(loaded.source);
    if (url.endsWith("/src/store/nativeStore.ts")) {
      source = source.replace("export const nativeOwnsWorkspace = () => active && ownsWorkspace;", "export const nativeOwnsWorkspace = () => globalThis.__legacyInstalling === true || active && ownsWorkspace;");
    }
    if (url.endsWith("/src/store/model.ts")) {
      source = source.replace("const launch = Date.now()", "let launch = Date.now()");
      source += "\nglobalThis.__legacyApplyModel = (m) => { launch = m.launch; counter = m.counter; navSeq = m.navSeq; };\n";
    }
    if (url.endsWith("/src/store/organize.ts")) {
      source += "\nglobalThis.__legacyApplyOrganize = (m) => { lastPinChoice = m.lastPinChoice ?? 0; remotePinDeletions.clear(); for (const [key, value] of Object.entries(m.remotePinDeletions ?? {})) remotePinDeletions.set(key, value); };\n";
    }
    return { ...loaded, source };
  },
});

await import("../test-loader.mjs");
const { useBrowser } = await import("../store/browser.ts");
const { nativeOwnsWorkspace } = await import("../store/nativeStore.ts");
await import("../store/pinOrderChoices.ts");
const { pinnedAdapter } = await import("./pinned.ts");
assert.equal(nativeOwnsWorkspace(), false);
const clone = (value) => JSON.parse(JSON.stringify(value));
const project = (state, template) => clone(Object.fromEntries(Object.keys(template).map((key) => [key, key === "ui" ? { focusedWindowId: state.ui.focusedWindowId, focusOrder: state.ui.focusOrder, lastProfileId: state.ui.lastProfileId } : state[key]])));

function differences(left, right, path = "") {
  if (JSON.stringify(left) === JSON.stringify(right)) return [];
  if (left && right && typeof left === "object" && typeof right === "object") {
    return [...new Set([...Object.keys(left), ...Object.keys(right)])].flatMap((key) => differences(left[key], right[key], path ? `${path}.${key}` : key));
  }
  return [{ path, legacy: left === undefined ? { $absent: true } : left, current: right === undefined ? { $absent: true } : right }];
}

const folder = new URL("../../../../native/SolaraKit/Tests/SolaraSyncTests/Cases/SyncPinsApply/Legacy/", import.meta.url);
let changed = 0;
for (const version of ["legacy38", "legacy40"]) {
  const file = new URL(`${version}.json.deflate`, folder);
  const document = JSON.parse(inflateRawSync(readFileSync(file)));
  const original = JSON.stringify(document);
  for (const recorded of document.cases) {
    const legacyAfter = recorded.legacyAfter ?? recorded.after;
    const legacyResult = recorded.legacyResult ?? recorded.result;
    Date.now = () => recorded.now;
    useBrowser.getState().hydrate({});
    globalThis.__legacyInstalling = true;
    try {
      useBrowser.setState(clone(recorded.before));
    } finally {
      globalThis.__legacyInstalling = false;
    }
    globalThis.__legacyApplyModel(recorded.memory);
    globalThis.__legacyApplyOrganize(recorded.memory);
    assert.deepEqual(project(useBrowser.getState(), recorded.before), recorded.before, "fixture installation changed its pre-apply state");
    const answers = new Map((recorded.lookups ?? []).filter(([kind]) => kind === "base").map(([, key, ...value]) => [key, value.length ? value[0] : undefined]));
    const known = new Set((recorded.lookups ?? []).filter(([kind, , value]) => kind === "recordKnown" && value).map(([, key]) => key));
    const applied = pinnedAdapter(recorded.adapter.args[0]).apply(new Map(recorded.visible), new Set(recorded.changed), (key) => answers.get(key), {
      known: (key) => known.has(key), now: recorded.records?.now ?? recorded.now, horizon: recorded.records?.horizon ?? 0,
    });
    assert.ok(!(applied instanceof Promise));
    const after = project(useBrowser.getState(), legacyAfter);
    const changes = differences(legacyAfter, after);
    for (const change of changes) assert.match(change.path, /^tabs\.[^.]+\.pinnedUrl$/, "historical fixture difference extended beyond the pinned home policy");
    if (version === "legacy40") assert.deepEqual(changes, []);
    recorded.legacyAfter = legacyAfter;
    recorded.legacyResult = legacyResult;
    recorded.after = after;
    recorded.result = applied === undefined ? null : applied instanceof Set ? { written: [...applied] } : applied;
    recorded.historicalDifferences = changes;
    if (changes.length) {
      changed++;
      console.log(JSON.stringify({ version, test: recorded.test, differences: changes }));
    }
  }
  if (process.argv.includes("--check")) assert.equal(JSON.stringify(document), original, "current TypeScript fallback changed the normalized fixture");
  else writeFileSync(file, deflateRawSync(Buffer.from(JSON.stringify(document)), { level: 9 }));
  console.log(`${version}: ${document.cases.length} fixture applies independently evaluated through current TypeScript fallback`);
}
assert.equal(changed, 5);

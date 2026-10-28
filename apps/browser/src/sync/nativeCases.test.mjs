import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { inflateRawSync } from "node:zlib";
import { changedSources } from "../../../../packages/sync/scripts/pinSources.mjs";

const cases = new URL("../../../../native/SolaraKit/Tests/SolaraSyncTests/Cases/", import.meta.url);
const committed = (file) => JSON.parse(inflateRawSync(readFileSync(new URL(file, cases))).toString());

test("readable.ts still gives every verdict StateDecode.swift replays", async () => {
  const { verdicts } = await import("../../scripts/native/stateCases.mjs");
  const stale = committed("state.json.deflate").cases.filter((c) => JSON.stringify(verdicts(c.value)) !== JSON.stringify(c.verdicts)).length;
  assert.equal(stale, 0, "port the change to StateDecode.swift, then re-record with node --import ./src/test-loader.mjs scripts/native/stateCases.mjs");
});

for (const [fixture, swift, recorder] of [
  ["Cases/state.json.deflate", "StateDecode.swift", "stateCases.mjs"],
]) {
  test(`the sources behind ${fixture} haven't changed since it was recorded`, () => {
    assert.deepEqual(changedSources(fixture), [], `look at ${swift} for the same change, then re-record with node --import ./src/test-loader.mjs scripts/native/${recorder}`);
  });
}

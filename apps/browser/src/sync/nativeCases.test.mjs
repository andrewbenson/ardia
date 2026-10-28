import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { inflateRawSync } from "node:zlib";
import { changedSources } from "../../../../packages/sync/scripts/pinSources.mjs";

const cases = new URL("../../../../native/SolaraKit/Tests/SolaraSyncTests/Cases/", import.meta.url);
const committed = (file) => JSON.parse(inflateRawSync(readFileSync(new URL(file, cases))).toString());

test("passwordLedger.ts still answers every case PasswordLedger.swift replays", async () => {
  const { evaluate } = await import("../../scripts/native/ledgerCases.mjs");
  const stale = committed("ledger.json.deflate").cases.filter((c) => JSON.stringify(evaluate(c.input)) !== JSON.stringify(c.output)).length;
  assert.equal(stale, 0, "port the change to PasswordLedger.swift, then re-record with node --import ./src/test-loader.mjs scripts/native/ledgerCases.mjs");
});

test("editJournal.ts still answers every case EditJournal.swift replays", async () => {
  const { runScript, runUnion } = await import("../../scripts/native/journalCases.mjs");
  const { cases: scripts, unions } = committed("journal.json.deflate");
  const stale =
    scripts.filter((c) => JSON.stringify(runScript(c.script)) !== JSON.stringify(c.steps)).length +
    unions.filter((c) => JSON.stringify(runUnion(c.input)) !== JSON.stringify(c.output)).length;
  assert.equal(stale, 0, "port the change to EditJournal.swift, then re-record with node --import ./src/test-loader.mjs scripts/native/journalCases.mjs");
});

test("readable.ts still gives every verdict StateDecode.swift replays", async () => {
  const { verdicts } = await import("../../scripts/native/stateCases.mjs");
  const stale = committed("state.json.deflate").cases.filter((c) => JSON.stringify(verdicts(c.value)) !== JSON.stringify(c.verdicts)).length;
  assert.equal(stale, 0, "port the change to StateDecode.swift, then re-record with node --import ./src/test-loader.mjs scripts/native/stateCases.mjs");
});

for (const [fixture, swift, recorder] of [
  ["Cases/ledger.json.deflate", "PasswordLedger.swift", "ledgerCases.mjs"],
  ["Cases/journal.json.deflate", "EditJournal.swift", "journalCases.mjs"],
  ["Cases/state.json.deflate", "StateDecode.swift", "stateCases.mjs"],
  ["Adapters", "the adapters in SolaraSync (StoreAdapters, PinnedAdapters, HostedAdapters, Extensions)", "replay.mjs --phase adapters"],
  ["Scenarios/extensions.json.deflate", "SolaraSync's Extensions.swift", "../../../packages/sync/scripts/extensions-scenario.mjs"],
]) {
  test(`the sources behind ${fixture} haven't changed since it was recorded`, () => {
    assert.deepEqual(changedSources(fixture), [], `look at ${swift} for the same change, then re-record with node --import ./src/test-loader.mjs scripts/native/${recorder}`);
  });
}

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { inflateRawSync } from "node:zlib";
import { changedSources } from "../scripts/pinSources.mjs";
import { namedRedesignScripts, namedScripts, randomRedesignScript, randomScript, runScenario, type Script } from "../scripts/scenario.mjs";

const fixtures = new URL("../../../native/SolaraKit/Tests/SolaraSyncTests/Scenarios/", import.meta.url);

async function recorded(scripts: Script[]) {
  const cases = [];
  for (const script of scripts) cases.push({ script, trace: await runScenario(script) });
  return JSON.stringify({ cases });
}

for (const [file, scripts] of [
  ["scope.json.deflate", () => [...namedScripts(), ...Array.from({ length: 60 }, (_, i) => randomScript(1 + i, 60))]],
  ["scope-redesign.json.deflate", () => [...namedRedesignScripts(), ...Array.from({ length: 60 }, (_, i) => randomRedesignScript(1 + i, 60))]],
] as const) {
  test(`the merge's sources are the ones ${file} was recorded from`, () => {
    assert.deepEqual(changedSources(`Scenarios/${file}`), [], `changed since ${file} was recorded: port the change to Scope.swift, then re-record with node packages/sync/scripts/scenario.mjs${file.includes("redesign") ? " --redesign" : ""}`);
  });

  test(`scope.ts still traces as ${file}, which the Swift merge replays`, async () => {
    const committed = inflateRawSync(readFileSync(new URL(file, fixtures))).toString();
    const now = await recorded(scripts());
    assert.ok(
      now === committed,
      `scope.ts no longer traces as ${file}: port the change to Scope.swift, then re-record with node packages/sync/scripts/scenario.mjs${file.includes("redesign") ? " --redesign" : ""}`,
    );
  });
}

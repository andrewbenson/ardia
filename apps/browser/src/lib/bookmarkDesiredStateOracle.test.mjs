import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
const { generateBookmarkDesiredFixtures, serializeBookmarkDesiredFixtures, bookmarkDesiredFixtureURL } = await import("../../../../native/SolaraKit/Scripts/bookmark-desired-fixtures.mts");

test("the unchanged reducer, diff, replay, adapter and scope regenerate identical bytes", async () => {
  const first = serializeBookmarkDesiredFixtures(await generateBookmarkDesiredFixtures());
  const second = serializeBookmarkDesiredFixtures(await generateBookmarkDesiredFixtures());
  assert.equal(first, second);
  assert.equal(readFileSync(bookmarkDesiredFixtureURL, "utf8"), first);
});

test("the oracle pins structural break, exact duplicate removal and sync idle output", async () => {
  const fixture = await generateBookmarkDesiredFixtures();
  const suffix = fixture.pure.find(r => r.name === "partial-delete-valid-suffix-resurrected");
  assert.equal(suffix.replayed.filter(n => n.kind === "url").length, 1);
  const duplicates = fixture.reducer.find(r => r.name === "toggle-all-exact-duplicates");
  assert.deepEqual(Object.values(duplicates.after.nodes).filter(n => n.kind === "url").map(n => n.url), ["https://e\u0301.example/"]);
  for (const name of ["same-value-idle", "same-value-reapply", "remote-idle-no-echo", "undo-idle", "partial-delete-idle", "snapshot-idle"]) {
    assert.deepEqual(fixture.wire.cycles.find(c => c.name === name).payloads, []);
  }
  assert.deepEqual(fixture.traces.schedules.slice(0, 5).map(s => s.nextDelay), [null, 1500, 3000, 6000, 12000]);
  assert.equal(fixture.traces.migration.result, "kept");
  assert.equal(fixture.traces.migration.keptFile, true);
  assert.equal(fixture.traces.keptMigrationLaunch.keptFile, true);
  assert.deepEqual(fixture.traces.keptMigrationLaunch.before.ready, {});
  assert.deepEqual(fixture.traces.keptMigrationLaunch.after.ready, {});
  assert.equal(fixture.traces.keptMigrationLaunch.attempts.length, 1);
});

test("wire publication observes desired edits through actual failed Chrome pushes in both origin modes", async () => {
  const fixture = await generateBookmarkDesiredFixtures();
  assert.deepEqual(fixture.wireModes.off, fixture.wireModes.on);
  assert.equal(fixture.wire.enginePushes.length, 2);
  for (const push of fixture.wire.enginePushes) {
    assert.ok(push.ops.length > 0);
    assert.equal(push.failedPushes > 0, true);
    assert.equal(push.ready, true);
    assert.equal(push.shadow.some(n => n.kind === "url"), false);
  }
  assert.equal(fixture.wire.cycles.find(c => c.name === "desired-pending-push-error").payloads.length, 1);
  assert.equal(fixture.wire.cycles.find(c => c.name === "remote-replacement-pending").desired.nodes["00000000-0000-4000-8000-000000000002"].title, "Remote while push fails");
  assert.deepEqual(fixture.traces.partialBatch.desiredTitles, ["URL 3"]);
  assert.deepEqual(fixture.traces.partialBatch.actualTitles, ["URL 3"]);
});

test("every reducer command freezes its immediate desired document and allocation receipt", async () => {
  const fixture = await generateBookmarkDesiredFixtures();
  const duplicate = fixture.reducer.find(s => s.name === "duplicate-bulk-remove-and-restore");
  assert.deepEqual(duplicate.steps[0].result.nodes.map(n => n.id), ["00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000001"]);
  assert.deepEqual(duplicate.steps[0].result.places.map(p => p.id), ["00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000001"]);
  assert.deepEqual(duplicate.after, duplicate.before);
  for (const scenario of fixture.reducer) {
    assert.equal(scenario.steps?.length, scenario.commands.length, scenario.name);
    assert.deepEqual(scenario.steps.at(-1).after, scenario.after, scenario.name);
    for (const [index, step] of scenario.steps.entries()) {
      assert.deepEqual(step.command, scenario.commands[index]);
      assert.deepEqual(step.result, scenario.results[index]);
      assert.deepEqual(step.allocatedIds, scenario.allocatedIds.slice(0, step.allocatedIds.length));
      assert.equal(step.now, scenario.now);
      assert.ok(step.after.nodes);
      assert.ok(step.after.roots);
    }
  }
});

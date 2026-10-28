import assert from "node:assert/strict";
import { test } from "node:test";
import { handoffLoaded } from "./pageHandoff.ts";

test("a handed-off page counts as loaded only for the navigation it carried", () => {
  assert.equal(handoffLoaded({ seq: 4 }, 4), true);
  assert.equal(handoffLoaded({ seq: 3 }, 4), false);
  assert.equal(handoffLoaded(null, 4), false);
  assert.equal(handoffLoaded(null, undefined), false);
});

test("a handoff with no navigation never swallows the tab's first one", () => {
  assert.equal(handoffLoaded({ seq: undefined }, undefined), false);
  assert.equal(handoffLoaded({}, undefined), false);
  assert.equal(handoffLoaded({ seq: undefined }, 1), false);
});

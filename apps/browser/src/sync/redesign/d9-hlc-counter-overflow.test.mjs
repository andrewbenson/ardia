import assert from "node:assert/strict";
import { test } from "node:test";
import { Clock } from "../../../../../packages/sync/src/hlc.ts";

test("D9b: a clock pinned behind a skewed stamp keeps its stamps increasing past 36^4 ticks", { todo: "step 12" }, () => {
  const realNow = Date.UTC(2026, 9, 27);
  const skewed = new Clock("skewed", null, () => Date.UTC(2030, 0, 1));
  const ahead = skewed.tick();
  const victim = new Clock("victim", null, () => realNow);
  victim.observe(ahead);
  let last = victim.tick();
  let inverted = null;
  for (let i = 0; i < 36 ** 4 + 5; i++) {
    const next = victim.tick();
    if (next <= last) { inverted = { last, next, ticks: i }; break; }
    last = next;
  }
  assert.equal(inverted, null, `stamps stay increasing (inverted: ${JSON.stringify(inverted)})`);
});

import assert from "node:assert/strict";
import { test } from "node:test";

const WINDOWS_TO_UNIX_MS = 11_644_473_600_000n;
const chromeMs = (micros) => Number(micros / 1000n - WINDOWS_TO_UNIX_MS);
const chromeMicros = (ms, extraMicros = 0) => (BigInt(ms) + WINDOWS_TO_UNIX_MS) * 1000n + BigInt(extraMicros);

function markAfterApply(applied, readBack, now) {
  if (!applied.every((key) => readBack.has(key))) return null;
  const newest = Math.max(...applied.map((key) => chromeMs(readBack.get(key))));
  return Math.max(now, newest);
}

const claimedInRebuild = (modifiedMicros, rowT, ledgerT) => chromeMs(modifiedMicros) > Math.max(rowT, ledgerT);

function effectiveToggle(inSyncJson, inAnchor) {
  if (!inAnchor) return { on: inSyncJson.on, rewriteAnchor: true, ask: false };
  if (inSyncJson.n > inAnchor.n) return { on: inSyncJson.on, rewriteAnchor: true, ask: false };
  if (inAnchor.n > inSyncJson.n) return { on: inAnchor.on, rewriteSyncJson: true, ask: false };
  if (inSyncJson.on === inAnchor.on) return { on: inSyncJson.on, ask: false };
  return { on: false, ask: true };
}

test("SPEC-t: t is taken after every covered login's date was read back, so it's at or after each", () => {
  const readBack = new Map([["a", chromeMicros(1_000_500, 999)], ["b", chromeMicros(1_000_700)]]);
  assert.equal(markAfterApply(["a", "b"], readBack, 1_000_600), 1_000_700);
  assert.equal(markAfterApply(["a", "b"], readBack, 1_000_900), 1_000_900);
});

test("SPEC-t-unconfirmed: an apply whose read-back never confirms every login writes no row", () => {
  assert.equal(markAfterApply(["a", "b"], new Map([["a", chromeMicros(5)]]), 10), null);
});

test("SPEC-t-precision: Chrome's microseconds compare at millisecond precision, strictly later", () => {
  assert.equal(claimedInRebuild(chromeMicros(2_000, 999), 2_000, 1_000), false, "same millisecond, later microseconds: not later");
  assert.equal(claimedInRebuild(chromeMicros(2_001), 2_000, 1_000), true);
  assert.equal(claimedInRebuild(chromeMicros(2_001), 2_000, 2_001), false, "the later of the two times wins");
});

test("SPEC-t-sync-write: a value sync applied is never later than the row written after its read-back", () => {
  const applied = chromeMicros(3_000, 500);
  const t = markAfterApply(["a"], new Map([["a", applied]]), 2_999);
  assert.equal(claimedInRebuild(applied, t, 0), false);
});

test("SPEC-opt-out: the copy with the higher counter wins, in both directions", () => {
  assert.equal(effectiveToggle({ on: true, n: 3 }, { on: false, n: 4 }).on, false, "sync.json rolled back to on loses to the newer off");
  assert.equal(effectiveToggle({ on: false, n: 3 }, { on: true, n: 4 }).on, true, "sync.json rolled back to off doesn't stop sync");
  assert.equal(effectiveToggle({ on: true, n: 5 }, { on: false, n: 4 }).on, true, "an anchor rolled back to off loses");
  const torn = effectiveToggle({ on: true, n: 4 }, { on: false, n: 4 });
  assert.deepEqual([torn.on, torn.ask], [false, true], "equal counters that disagree: off, and the Sync pane asks");
});

test("SPEC-opt-out-settings-reset: a reset settings doc has no anchor, which is no decision, so sync stays on", () => {
  const r = effectiveToggle({ on: true, n: 2 }, null);
  assert.equal(r.on, true);
  assert.equal(r.rewriteAnchor, true);
});

test("SPEC-opt-out-unloaded-profile: a type re-enabled while a profile was unloaded is on for it once it loads, and its anchor is rewritten", () => {
  const atToggle = { on: true, n: 7 };
  const unloadedProfileAnchor = { on: false, n: 6 };
  const r = effectiveToggle(atToggle, unloadedProfileAnchor);
  assert.equal(r.on, true);
  assert.equal(r.rewriteAnchor, true);
});

test("SPEC-t-clock-step-back: the clock stepping back between Chrome's write and t still gives a t at or after every applied date", () => {
  const written = chromeMicros(10_000, 400);
  const steppedBack = 9_000;
  const t = markAfterApply(["a"], new Map([["a", written]]), steppedBack);
  assert.equal(t, 10_000);
  assert.equal(claimedInRebuild(written, t, 0), false, "the applied value isn't claimed");
});

test("SPEC-t-bigint: Chrome's microsecond dates exceed 2^53, so a Number loses the last microseconds", () => {
  const micros = chromeMicros(1_761_500_000_123, 999);
  assert.ok(micros > BigInt(Number.MAX_SAFE_INTEGER));
  assert.notEqual(BigInt(Number(micros)), micros);
  assert.equal(chromeMs(micros), 1_761_500_000_123);
});

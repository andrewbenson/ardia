import assert from "node:assert/strict";
import { test } from "node:test";
const { historyPatch, MAX_PATCH_ROWS } = await import("./historyPatch.ts");

const row = (url) => ({ url });
const apply = (prev, patch) => {
  const gone = new Set(patch.removed);
  const next = prev.filter((r) => !gone.has(r.url));
  for (const [i, r] of patch.inserts) next.splice(i, 0, r);
  return next;
};

test("a visit that moves a row to the front is one removal and one insert", () => {
  const [a, b, c] = [row("a"), row("b"), row("c")];
  const moved = { url: "c", again: true };
  const patch = historyPatch([a, b, c], [moved, a, b]);
  assert.deepEqual(patch, { removed: ["c"], inserts: [[0, moved]] });
  assert.deepEqual(apply([a, b, c], patch), [moved, a, b]);
});

test("removals, new rows and rows that fall off the end replay to the same list", () => {
  const rows = Array.from({ length: 50 }, (_, i) => row(`u${i}`));
  const next = [row("new1"), ...rows.slice(0, 10), row("new2"), ...rows.slice(12, 45)];
  const patch = historyPatch(rows, next);
  assert.ok(patch);
  assert.deepEqual(apply(rows, patch).map((r) => r.url), next.map((r) => r.url));
});

test("a reorder of rows that stayed, or a change too big, sends the whole list", () => {
  const [a, b] = [row("a"), row("b")];
  assert.equal(historyPatch([a, b], [b, a]), null);
  const many = Array.from({ length: MAX_PATCH_ROWS + 1 }, (_, i) => row(`n${i}`));
  assert.equal(historyPatch([], many), null);
});

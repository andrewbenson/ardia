import assert from "node:assert/strict";
import { test } from "node:test";

globalThis.__DEV__ = false;
const { splitGeometry } = await import("./geometry.ts");

const leading = (split, width, height) =>
  Object.entries(splitGeometry(split, width, height).panes)
    .filter(([, r]) => r.x === 0 && r.y === 0)
    .map(([id]) => id);

const splits = [
  { id: "s", windowId: "w", tabIds: ["a", "b"], orientation: "horizontal", sizes: [0.5, 0.5] },
  { id: "s", windowId: "w", tabIds: ["a", "b"], orientation: "vertical", sizes: [0.3, 0.7] },
  { id: "s", windowId: "w", tabIds: ["a", "b", "c"], orientation: "horizontal", sizes: [0.2, 0.5, 0.3] },
  { id: "s", windowId: "w", tabIds: ["a", "b", "c"], orientation: "horizontal", sizes: [0.5, 0.5], stack: { index: 1, sizes: [0.5, 0.5] } },
  { id: "s", windowId: "w", tabIds: ["a", "b", "c"], orientation: "vertical", sizes: [0.6, 0.4], stack: { index: 0, sizes: [0.4, 0.6] } },
];

test("the pane at the card's origin is the same at the pane roots' unit size as at the card's real size", () => {
  for (const split of splits) {
    const unit = leading(split, 1000, 1000);
    assert.equal(unit.length, 1, JSON.stringify(split));
    for (const [w, h] of [[1440, 900], [900, 1400], [500, 400]]) assert.deepEqual(leading(split, w, h), unit, `${JSON.stringify(split)} at ${w}×${h}`);
  }
});

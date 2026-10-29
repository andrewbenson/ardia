import assert from "node:assert/strict";
import { test } from "node:test";
import { folderRows } from "./rows.ts";

const item = (id, stack) => ({ id, source: "github", url: "https://example.com/" + id, title: id, subtitle: "", icon: null, updatedAt: 0, section: "authored", pr: { number: 1, repo: "o/r", headRef: id, baseRef: "main", stack } });
const stacked = [item("a", { id: "stack:a", position: 1, size: 2 }), item("b", { id: "stack:a", position: 2, size: 2 }), item("c")];

test("with stacks grouped, a stack is one row", () => {
  const rows = folderRows({ id: "f", kind: "pullRequests", groupStacks: true }, stacked, {});
  assert.deepEqual(rows.map((r) => r.kind === "stack" ? `stack:${r.items.map((i) => i.id).join(",")}` : r.key), ["stack:a,b", "c"]);
});

test("with stacks ungrouped, each pull request is its own row", () => {
  const rows = folderRows({ id: "f", kind: "pullRequests", groupStacks: false }, stacked, {});
  assert.deepEqual(rows.map((r) => `${r.kind}:${r.key}`), ["item:a", "item:b", "item:c"]);
});

import assert from "node:assert/strict";
import { test } from "node:test";

globalThis.__DEV__ = false;
const feed = await import("./paneFeed.ts");

test("a window that let a tab go can't clear what the tab's new window published", () => {
  const [source, destination] = [{}, {}];
  const style = { transform: [{ translateY: {} }] };
  feed.publishPaneStatusStyle("t", source, { transform: [{ translateY: {} }] });
  feed.publishPaneStatusStyle("t", destination, style);
  feed.dropPaneStatusStyle("t", source);
  assert.equal(feed.paneStatusStyle("t"), style);
  feed.dropPaneStatusStyle("t", destination);
  assert.equal(feed.paneStatusStyle("t"), undefined);
});

test("a remounted card keeps its over-card tab when the old card's cleanup runs late", () => {
  const [old, fresh] = [{}, {}];
  feed.publishPopoversOverCard("w", old, "a");
  feed.publishPopoversOverCard("w", fresh, "b");
  feed.dropPopoversOverCard("w", old);
  assert.equal(feed.popoversOverCard("w"), "b");
  feed.dropPopoversOverCard("w", fresh);
  assert.equal(feed.popoversOverCard("w"), undefined);
});

test("a tab stays drawn by its pane root while any of its pane roots is up", () => {
  const [leaving, arriving] = [{}, {}];
  feed.markPaneRootDrawn("t", leaving, true);
  feed.markPaneRootDrawn("t", arriving, true);
  feed.markPaneRootDrawn("t", leaving, false);
  assert.equal(feed.paneRootDrawn("t"), true);
  feed.markPaneRootDrawn("t", arriving, false);
  assert.equal(feed.paneRootDrawn("t"), false);
});

test("the same owner republishing an equal shift changes nothing", () => {
  const owner = {};
  const shift = {};
  feed.publishPaneStatusStyle("s", owner, { transform: [{ translateY: shift }] });
  const first = feed.paneStatusStyle("s");
  feed.publishPaneStatusStyle("s", owner, { transform: [{ translateY: shift }] });
  assert.equal(feed.paneStatusStyle("s"), first);
  feed.dropPaneStatusStyle("s", owner);
});

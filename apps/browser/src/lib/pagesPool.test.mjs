import assert from "node:assert/strict";
import { test } from "node:test";

const on = { switch: true, available: true };
globalThis.acTestNativeModules = {
  SolaraWindowShell: { active: (windowId) => windowId === "shelled", pagesPool: () => on.switch },
  SolaraTabPool: { available: () => on.available },
};
const { pagesPooledIn } = await import("./pagesPool.ts");

test("pages are pooled only in a window whose shell is up, with the switch on and the pool serving", () => {
  assert.equal(pagesPooledIn("shelled"), true);
  assert.equal(pagesPooledIn("popup"), false);
  on.available = false;
  assert.equal(pagesPooledIn("shelled"), false);
  on.available = true;
  on.switch = false;
  assert.equal(pagesPooledIn("shelled"), false);
  on.switch = true;
});

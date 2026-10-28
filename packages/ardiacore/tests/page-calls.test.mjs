import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const source = (name) => readFileSync(new URL(`../ios/${name}`, import.meta.url), "utf8");

const viewFunctions = (name, view) => {
  const text = source(name);
  const body = text.slice(text.indexOf(`View(${view}.self)`));
  return new Set([...body.matchAll(/AsyncFunction\("(\w+)"\)/g)].map((m) => m[1]));
};

const dispatched = (() => {
  const text = source("PageCalls.swift");
  const list = text.slice(text.indexOf("public static let methods"), text.indexOf("]", text.indexOf("public static let methods")));
  return new Set([...list.matchAll(/"(\w+)"/g)].map((m) => m[1]));
})();

test("pageCall dispatches every method of the Chrome page view, by the same names", () => {
  assert.deepEqual([...dispatched].sort(), [...viewFunctions("CefModule.swift", "CefWebView")].sort());
});

test("the WebKit page view has no method the dispatcher lacks", () => {
  const missing = [...viewFunctions("WebKitModule.swift", "WebKitTabView")].filter((m) => !dispatched.has(m));
  assert.deepEqual(missing, []);
});

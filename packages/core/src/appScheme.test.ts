import assert from "node:assert/strict";
import { test } from "node:test";
import { appScheme, appSchemeFor, appUrlOrigin, appUrlRoute, setAppScheme, toAppUrl, toEngineUrl } from "./appUrls.ts";
import { breadcrumb, fixupUrl, resolveInput, urlForDisplay } from "./omnibox.ts";
import { displayUrl } from "./suggest.ts";

test("upstream keeps ardia:// until a product name is set", () => {
  assert.equal(appScheme(), "ardia");
  assert.equal(urlForDisplay("chrome://version/"), "ardia://version");
  assert.equal(fixupUrl("ardia://version"), "ardia://version");
});

test("the scheme is the product name, lowercased, and never a scheme the engine owns", () => {
  assert.equal(appSchemeFor("Vista"), "vista");
  assert.equal(appSchemeFor("My Browser"), "mybrowser");
  assert.equal(appSchemeFor("Chrome"), "ardia");
  assert.equal(appSchemeFor("HTTP"), "ardia");
  assert.equal(appSchemeFor("42"), "ardia");
  assert.equal(appSchemeFor(""), "ardia");
  assert.equal(appSchemeFor(null), "ardia");
});

test("a fork displays chrome:// and ardia:// pages under its own scheme", () => {
  assert.equal(setAppScheme("Vista"), "vista");
  assert.equal(urlForDisplay("chrome://version/"), "vista://version");
  assert.equal(urlForDisplay("ardia://version/"), "vista://version");
  assert.equal(urlForDisplay("vista://history/?q=a"), "vista://history?q=a");
  assert.equal(displayUrl("chrome://gpu/"), "vista://gpu");
  assert.equal(toAppUrl("view-source:chrome://version"), "view-source:vista://version");
  assert.equal(toAppUrl("about:flags"), "vista://flags");
  assert.equal(appUrlOrigin("ardia://settings/sync"), "vista://settings");
  assert.deepEqual(breadcrumb("chrome://flags/", "Experiments"), { host: "vista://flags", trail: ["Experiments"] });
  assert.deepEqual(breadcrumb("vista://history", "History"), { host: "vista://history", trail: [] });
});

test("a fork's typed scheme, ardia:// and chrome:// all resolve, and reach the engine as chrome://", () => {
  setAppScheme("Vista");
  for (const typed of ["vista://version", "ardia://version", "chrome://version", "VISTA://version"]) {
    assert.equal(fixupUrl(typed), "vista://version", typed);
    assert.equal(resolveInput(typed), "vista://version", typed);
  }
  assert.equal(toEngineUrl("vista://version"), "chrome://version");
  assert.equal(toEngineUrl("ardia://flags/#x"), "chrome://flags/#x");
  assert.equal(toEngineUrl("view-source:vista://version"), "view-source:chrome://version");
  assert.equal(toEngineUrl("https://vista.example/"), "https://vista.example/");
});

test("a fork routes its own pages from either scheme", () => {
  setAppScheme("Vista");
  assert.deepEqual(appUrlRoute("vista://history"), { kind: "page", page: "history" });
  assert.deepEqual(appUrlRoute("ardia://bookmarks"), { kind: "page", page: "bookmarks" });
  assert.deepEqual(appUrlRoute("vista://settings/sync"), { kind: "settings", section: "sync" });
  assert.deepEqual(appUrlRoute("vista://newtab"), { kind: "newTab" });
  assert.deepEqual(appUrlRoute("vista://version"), { kind: "engine", url: "chrome://version" });
  assert.equal(appUrlRoute("chrome://version"), null);
});

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
  assert.equal(appSchemeFor("Solara"), "solara");
  assert.equal(appSchemeFor("My Browser"), "mybrowser");
  assert.equal(appSchemeFor("Chrome"), "ardia");
  assert.equal(appSchemeFor("HTTP"), "ardia");
  assert.equal(appSchemeFor("42"), "ardia");
  assert.equal(appSchemeFor(""), "ardia");
  assert.equal(appSchemeFor(null), "ardia");
});

test("a fork displays chrome:// and ardia:// pages under its own scheme", () => {
  assert.equal(setAppScheme("Solara"), "solara");
  assert.equal(urlForDisplay("chrome://version/"), "solara://version");
  assert.equal(urlForDisplay("ardia://version/"), "solara://version");
  assert.equal(urlForDisplay("solara://history/?q=a"), "solara://history?q=a");
  assert.equal(displayUrl("chrome://gpu/"), "solara://gpu");
  assert.equal(toAppUrl("view-source:chrome://version"), "view-source:solara://version");
  assert.equal(toAppUrl("about:flags"), "solara://flags");
  assert.equal(appUrlOrigin("ardia://settings/sync"), "solara://settings");
  assert.deepEqual(breadcrumb("chrome://flags/", "Experiments"), { host: "solara://flags", trail: ["Experiments"] });
  assert.deepEqual(breadcrumb("solara://history", "History"), { host: "solara://history", trail: [] });
});

test("a fork's typed scheme, ardia:// and chrome:// all resolve, and reach the engine as chrome://", () => {
  setAppScheme("Solara");
  for (const typed of ["solara://version", "ardia://version", "chrome://version", "SOLARA://version"]) {
    assert.equal(fixupUrl(typed), "solara://version", typed);
    assert.equal(resolveInput(typed), "solara://version", typed);
  }
  assert.equal(toEngineUrl("solara://version"), "chrome://version");
  assert.equal(toEngineUrl("ardia://flags/#x"), "chrome://flags/#x");
  assert.equal(toEngineUrl("view-source:solara://version"), "view-source:chrome://version");
  assert.equal(toEngineUrl("https://solara.example/"), "https://solara.example/");
});

test("a fork routes its own pages from either scheme", () => {
  setAppScheme("Solara");
  assert.deepEqual(appUrlRoute("solara://history"), { kind: "page", page: "history" });
  assert.deepEqual(appUrlRoute("ardia://bookmarks"), { kind: "page", page: "bookmarks" });
  assert.deepEqual(appUrlRoute("solara://settings/sync"), { kind: "settings", section: "sync" });
  assert.deepEqual(appUrlRoute("solara://newtab"), { kind: "newTab" });
  assert.deepEqual(appUrlRoute("solara://version"), { kind: "engine", url: "chrome://version" });
  assert.equal(appUrlRoute("chrome://version"), null);
});

test("an app or about: URL whose fragment has a line break still parses", () => {
  setAppScheme("Solara");
  assert.equal(urlForDisplay("ardia://x#a\nb"), "solara://x#a\nb");
  assert.equal(appUrlOrigin("about:flags#a\nb"), "solara://flags");
  assert.deepEqual(breadcrumb("solara://settings/sync#a\u2028b", "Settings"), { host: "solara://settings", trail: ["Settings"] });
  assert.deepEqual(appUrlRoute("ardia://settings/sync#a\nb"), { kind: "settings", section: "sync" });
  assert.equal(displayUrl("chrome://version/#a\rb"), "solara://version#a\rb");
});

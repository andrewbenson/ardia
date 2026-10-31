import assert from "node:assert/strict";
import { test } from "node:test";
import { appScheme, appSchemeFor, appUrlOrigin, appUrlRoute, setAppScheme, toAppUrl, toEngineUrl } from "./appUrls.ts";
import { breadcrumb, fixupUrl, resolveInput, urlForDisplay } from "./omnibox.ts";
import { displayUrl } from "./suggest.ts";

test("upstream keeps solara:// until a product name is set", () => {
  assert.equal(appScheme(), "solara");
  assert.equal(urlForDisplay("chrome://version/"), "solara://version");
  assert.equal(fixupUrl("solara://version"), "solara://version");
});

test("the scheme is the product name, lowercased, and never a scheme the engine owns", () => {
  assert.equal(appSchemeFor("Solara"), "solara");
  assert.equal(appSchemeFor("My Browser"), "mybrowser");
  assert.equal(appSchemeFor("Chrome"), "solara");
  assert.equal(appSchemeFor("HTTP"), "solara");
  assert.equal(appSchemeFor("42"), "solara");
  assert.equal(appSchemeFor(""), "solara");
  assert.equal(appSchemeFor(null), "solara");
});

test("a fork displays chrome:// and solara:// pages under its own scheme", () => {
  assert.equal(setAppScheme("Solara"), "solara");
  assert.equal(urlForDisplay("chrome://version/"), "solara://version");
  assert.equal(urlForDisplay("solara://version/"), "solara://version");
  assert.equal(urlForDisplay("solara://history/?q=a"), "solara://history?q=a");
  assert.equal(displayUrl("chrome://gpu/"), "solara://gpu");
  assert.equal(toAppUrl("view-source:chrome://version"), "view-source:solara://version");
  assert.equal(toAppUrl("about:flags"), "solara://flags");
  assert.equal(appUrlOrigin("solara://settings/sync"), "solara://settings");
  assert.deepEqual(breadcrumb("chrome://flags/", "Experiments"), { host: "solara://flags", trail: ["Experiments"] });
  assert.deepEqual(breadcrumb("solara://history", "History"), { host: "solara://history", trail: [] });
});

test("a fork's typed scheme, solara:// and chrome:// all resolve, and reach the engine as chrome://", () => {
  setAppScheme("Solara");
  for (const typed of ["solara://version", "solara://version", "chrome://version", "SOLARA://version"]) {
    assert.equal(fixupUrl(typed), "solara://version", typed);
    assert.equal(resolveInput(typed), "solara://version", typed);
  }
  assert.equal(toEngineUrl("solara://version"), "chrome://version");
  assert.equal(toEngineUrl("solara://flags/#x"), "chrome://flags/#x");
  assert.equal(toEngineUrl("view-source:solara://version"), "view-source:chrome://version");
  assert.equal(toEngineUrl("https://solara.example/"), "https://solara.example/");
});

test("a fork routes its own pages from either scheme", () => {
  setAppScheme("Solara");
  assert.deepEqual(appUrlRoute("solara://history"), { kind: "page", page: "history" });
  assert.deepEqual(appUrlRoute("solara://bookmarks"), { kind: "page", page: "bookmarks" });
  assert.deepEqual(appUrlRoute("solara://settings/sync"), { kind: "settings", section: "sync" });
  assert.deepEqual(appUrlRoute("solara://newtab"), { kind: "newTab" });
  assert.deepEqual(appUrlRoute("solara://version"), { kind: "engine", url: "chrome://version" });
  assert.equal(appUrlRoute("chrome://version"), null);
});

test("an app or about: URL whose fragment has a line break still parses", () => {
  setAppScheme("Solara");
  assert.equal(urlForDisplay("solara://x#a\nb"), "solara://x#a\nb");
  assert.equal(appUrlOrigin("about:flags#a\nb"), "solara://flags");
  assert.deepEqual(breadcrumb("solara://settings/sync#a\u2028b", "Settings"), { host: "solara://settings", trail: ["Settings"] });
  assert.deepEqual(appUrlRoute("solara://settings/sync#a\nb"), { kind: "settings", section: "sync" });
  assert.equal(displayUrl("chrome://version/#a\rb"), "solara://version#a\rb");
});

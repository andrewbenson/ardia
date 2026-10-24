import assert from "node:assert/strict";
import { test } from "node:test";
import { canToggleDeveloperMode, developerHostOf, isDeveloperMode, isLocalDeveloperUrl, withDeveloperMode } from "./developerMode.ts";

const none = { sites: [] };

test("local hosts are always in Developer Mode, on any port and path", () => {
  for (const url of [
    "http://localhost:3000/app?x=1",
    "https://localhost/",
    "http://127.0.0.1:8080/",
    "http://[::1]:5173/",
    "http://app.localhost:4000/",
    "http://LOCALHOST:3000/",
  ])
    assert.equal(isDeveloperMode(url, none), true, url);
});

test("other sites are off until turned on, and the switch is per host", () => {
  assert.equal(isDeveloperMode("https://example.com/a", none), false);
  const sites = withDeveloperMode([], "https://www.example.com:8443/path?q", true);
  assert.deepEqual(sites, ["example.com"]);
  assert.equal(isDeveloperMode("https://example.com/other", { sites }), true);
  assert.equal(isDeveloperMode("http://www.example.com/", { sites }), true);
  assert.equal(isDeveloperMode("https://sub.example.com/", { sites }), false);
  assert.deepEqual(withDeveloperMode(sites, "https://example.com/", false), []);
});

test("turning a site on twice keeps one entry", () => {
  assert.deepEqual(withDeveloperMode(["a.com", "b.com"], "https://a.com/", true), ["b.com", "a.com"]);
});

test("only http and https pages have Developer Mode", () => {
  for (const url of ["file:///Users/me/index.html", "about:blank", "ardia://settings", "not a url", "", "chrome://version"]) {
    assert.equal(developerHostOf(url), null, url);
    assert.equal(isDeveloperMode(url, { sites: ["localhost"] }), false, url);
    assert.equal(canToggleDeveloperMode(url), false, url);
  }
});

test("local hosts can't be switched off and aren't stored", () => {
  assert.equal(canToggleDeveloperMode("http://localhost:3000/"), false);
  assert.equal(isLocalDeveloperUrl("http://localhost:3000/"), true);
  assert.deepEqual(withDeveloperMode([], "http://localhost:3000/", true), []);
  assert.deepEqual(withDeveloperMode(["x.dev"], "http://127.0.0.1/", false), ["x.dev"]);
  assert.equal(canToggleDeveloperMode("https://staging.example.com/"), true);
  assert.equal(isLocalDeveloperUrl("https://localhost.example.com/"), false);
});

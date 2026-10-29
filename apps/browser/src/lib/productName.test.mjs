import assert from "node:assert/strict";
import { test } from "node:test";
const { appInfo } = await import("../test-native/index.ts");

appInfo.appName = "Solara";
appInfo.switchesURL = "https://stats.example.com/flags.json";
appInfo.updateFeedURL = "https://github.com/example/solara/releases/latest/download/appcast.xml";

const { PRODUCT, SERVICES } = await import("./productName.ts");
const { SETTINGS, setting } = await import("../components/settings/settingsIndex.ts");

test("the bundle's product name names the app everywhere", () => {
  assert.equal(PRODUCT, "Solara");
  assert.equal(setting("general.openAtLogin").title, "Open Solara at login");
  assert.equal(setting("general.autoUpdate").title, "Automatically update Solara");
  assert.equal(SETTINGS.find((e) => e.id.endsWith(".cliControl")).title, "Let the solara command control Solara");
  assert.equal(SETTINGS.find((e) => e.id.endsWith(".cliInstall")).title, "The solara command");
});

test("no product-facing copy still names Ardia", () => {
  const strings = [
    ...SETTINGS.flatMap((e) => [e.title, e.section, e.description ?? ""]),
  ];
  assert.deepEqual(strings.filter((s) => /Ardia/.test(s)), []);
});

test("service copy names the servers this build talks to", () => {
  assert.deepEqual(SERVICES, { updateHost: "github.com", switchFile: "stats.example.com/flags.json" });
});

test("a fork opens its own pages under its scheme and still knows ardia:// ones", async () => {
  const { APP_SCHEME } = await import("./productName.ts");
  const { internalPageOf, internalUrl } = await import("../components/pages/internalUrls.ts");
  const { urlForDisplay } = await import("@ardia/core");
  assert.equal(APP_SCHEME, "solara");
  assert.equal(internalUrl("history"), "solara://history");
  assert.equal(internalUrl("history", "a b"), "solara://history?q=a%20b");
  assert.equal(internalPageOf("solara://history?q=x"), "history");
  assert.equal(internalPageOf("ardia://bookmarks"), "bookmarks");
  assert.equal(internalPageOf("SOLARA://Downloads/"), "downloads");
  assert.equal(internalPageOf("chrome://history"), null);
  assert.equal(internalPageOf("solara://version"), null);
  assert.equal(internalPageOf("https://solara.example/history"), null);
  assert.equal(urlForDisplay("chrome://version/"), "solara://version");
});

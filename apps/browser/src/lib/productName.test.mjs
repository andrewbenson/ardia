import assert from "node:assert/strict";
import { test } from "node:test";
import { appInfo } from "@ardia/shell";

appInfo.appName = "Vista";
appInfo.telemetryURL = "https://stats.example.com/otel/v1/logs";
appInfo.switchesURL = "https://stats.example.com/flags.json";
appInfo.updateFeedURL = "https://github.com/example/vista/releases/latest/download/appcast.xml";

const { PRODUCT, SERVICES } = await import("./productName.ts");
const { ONBOARDING_COPY } = await import("../components/onboarding/copy.ts");
const { SETTINGS, setting } = await import("../components/settings/settingsIndex.ts");
const { SHARING_COPY } = await import("../telemetry/copy.ts");

test("the bundle's product name names the app everywhere", () => {
  assert.equal(PRODUCT, "Vista");
  assert.equal(ONBOARDING_COPY.wordmark, "Vista");
  assert.equal(ONBOARDING_COPY.system.setDefault, "Set Vista as default browser");
  assert.equal(ONBOARDING_COPY.system.subtitle, "Vista works best as your default browser.");
  assert.equal(setting("general.openAtLogin").title, "Open Vista at login");
  assert.equal(setting("general.autoUpdate").title, "Automatically update Vista");
  assert.equal(SHARING_COPY.ask.title, "Help fix Vista?");
  assert.equal(SETTINGS.find((e) => e.id.endsWith(".cliControl")).title, "Let the vista command control Vista");
  assert.equal(SETTINGS.find((e) => e.id.endsWith(".cliInstall")).title, "The vista command");
});

test("no product-facing copy still names Ardia", () => {
  const strings = [
    ...Object.values(ONBOARDING_COPY.system),
    ONBOARDING_COPY.importOpened,
    ONBOARDING_COPY.pinnedSubtitle,
    ...SETTINGS.flatMap((e) => [e.title, e.section, e.description ?? ""]),
    JSON.stringify(SHARING_COPY),
  ];
  assert.deepEqual(strings.filter((s) => /Ardia/.test(s)), []);
});

test("sharing copy names the servers this build talks to", () => {
  assert.deepEqual(SERVICES, { telemetryHost: "stats.example.com", updateHost: "github.com", switchFile: "stats.example.com/flags.json" });
  assert.match(SHARING_COPY.footnote, /^Sent to stats\.example\.com /);
  assert.match(SHARING_COPY.switchFile, /reads stats\.example\.com\/flags\.json:/);
});

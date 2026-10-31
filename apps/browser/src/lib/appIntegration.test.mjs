import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { after, test } from "node:test";

const appURL = new URL("./appIntegration.ts", import.meta.url).href;
const f = globalThis.appIntegrationTest = {
  state: { tabs: { t: {} }, windows: { w: {} }, live: {} },
  subscriptions: [], loading: [], native: [], startup: [], help: [], focus: [],
};
const fake = (source) => ({ url: `data:text/javascript,${encodeURIComponent(source)}`, shortCircuit: true });
const sources = {
  "@ardia/settings": `export const nativeAppIntegrationCommand = async (command, windowId) => {
    const f = globalThis.appIntegrationTest;
    f.native.push([command, windowId]);
    await new Promise((resolve) => { f.resolveNative = resolve; });
  };`,
  "@ardia/shell": `
    const f = globalThis.appIntegrationTest;
    export const onCommand = (fn) => { f.command = fn; };
    export const onNotificationResponse = (fn) => { f.notification = fn; };
    export const setScriptLoading = async (ids) => { f.loading.push(ids); };
    export const systemInfo = () => ({ isolatedInstance: true });
    export const readDocument = () => null;
    export const saveDocument = async () => {};
    export const isDefaultBrowser = async () => false;
    export const setAsDefaultBrowser = async () => false;
  `,
  "../components/onboarding": `
    const f = globalThis.appIntegrationTest;
    export const maybeStartOnboarding = () => { f.startup.push("onboarding"); };
    export const startOnboarding = (id) => { f.help.push(["onboarding", id]); };
    export const startToolTour = async (id) => { f.help.push(["tool", id]); };
    export const openVideoTour = (id) => { f.help.push(["video", id]); };
  `,
  "../components/onboarding/state": `export const onboardingCompletedAt = () => 1; export const useOnboarding = { getState: () => ({ windowId: null }) };`,
  "../components/ntp/releaseNotes": `export const trackAppVersion = () => { globalThis.appIntegrationTest.startup.push("version"); return true; };`,
  "../store/browser": `export const useBrowser = { getState: () => globalThis.appIntegrationTest.state, subscribe: (fn) => { globalThis.appIntegrationTest.subscriptions.push(fn); } };`,
  "./actions": `export const focus = (id) => { globalThis.appIntegrationTest.focus.push(["window", id]); }; export const switchToTab = (id) => { globalThis.appIntegrationTest.focus.push(["tab", id]); };`,
  "./afterFirstWindow": `export const afterFirstWindow = (fn) => { globalThis.appIntegrationTest.afterWindow = fn; };`,
  "./defaultBrowserOffer": `export const offerDefaultBrowserAgain = async (deps) => { globalThis.appIntegrationTest.offer = deps; };`,
  "./releaseNotesPage": `export const openReleaseNotesAfterUpdate = () => { globalThis.appIntegrationTest.startup.push("release"); }; export const openReleaseNotesPage = (id) => { globalThis.appIntegrationTest.help.push(["release", id]); };`,
  "./webNotifications": `export const handleWebNotificationResponse = (response) => response.data === "web";`,
};
const hooks = registerHooks({
  resolve(specifier, context, next) {
    if (context.parentURL === appURL && specifier in sources) return fake(sources[specifier]);
    return next(specifier, context);
  },
});
const integration = await import("./appIntegration.ts");
after(() => { hooks.deregister(); delete globalThis.appIntegrationTest; });

test("startup retains the JS duties and publishes only script loading", async () => {
  integration.startAppIntegration();
  assert.deepEqual(f.startup, ["version", "onboarding", "release"]);
  assert.deepEqual(f.loading, [[]]);
  assert.equal(f.subscriptions.length, 1);
  f.afterWindow();
  assert.equal(f.offer.testInstance, true);
  assert.equal(f.offer.onboarding, false);
  for (const command of ["showOnboarding", "toolTour", "videoTour", "releaseNotes"]) f.command({ command, windowId: "w" });
  assert.deepEqual(f.help, [["onboarding", "w"], ["tool", "w"], ["video", "w"], ["release", "w"]]);
  f.notification({ action: "click", tabId: "t", windowId: "w" });
  f.notification({ action: "click", windowId: "w" });
  f.notification({ action: "close", tabId: "t" });
  f.notification({ action: "click", tabId: "t", data: "web" });
  assert.deepEqual(f.focus, [["tab", "t"], ["window", "w"]]);
  for (const command of ["sendFeedback", "copyDiagnostics", "recordPerformanceIssue", "taskManager"]) f.command({ command, windowId: "w" });
  assert.deepEqual(f.native, []);
  assert.equal("diagnostics" in integration, false);
});

test("loading coalesces for 100 ms, reads the latest live state, and deduplicates", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const change = (live) => {
    const prev = f.state;
    f.state = { ...prev, live };
    f.subscriptions[0](f.state, prev);
  };
  change({ a: { isLoading: true } });
  t.mock.timers.tick(50);
  change({ a: { isLoading: true }, b: { isLoading: false } });
  t.mock.timers.tick(49);
  assert.deepEqual(f.loading, [[]]);
  t.mock.timers.tick(1);
  assert.deepEqual(f.loading, [[], ["a"]]);
  change({ a: { isLoading: true }, b: { isLoading: false } });
  t.mock.timers.tick(100);
  assert.deepEqual(f.loading, [[], ["a"]]);
  change({});
  t.mock.timers.tick(100);
  assert.deepEqual(f.loading, [[], ["a"], []]);
});

test("the feedback export awaits Swift for check-in callers", async () => {
  let finished = false;
  const pending = integration.sendFeedback("w").then(() => { finished = true; });
  assert.deepEqual(f.native, [["sendFeedback", "w"]]);
  await Promise.resolve();
  assert.equal(finished, false);
  f.resolveNative();
  await pending;
  assert.equal(finished, true);
});

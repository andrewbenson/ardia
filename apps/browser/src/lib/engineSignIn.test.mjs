import assert from "node:assert/strict";
import { test } from "node:test";

const imports = [];
const storeKeys = [];
globalThis.acTestNativeModules = {
  ArdiaWebKit: {
    addListener: () => ({ remove() {} }),
    endPrivateSession: () => Promise.resolve(),
    cookieStoreKey: (profile) => (storeKeys.push(profile), Promise.resolve(profile)),
    importCookies: (profile, key, cookies) => (imports.push({ profile, key, cookies }), Promise.resolve(cookies.length)),
  },
};

const { environment } = await import("../test-native/shell.ts");
environment.set("ARDIA_WEBKIT_SIGN_IN", "on");
const { useBrowser } = await import("../store/browser.ts");
const model = await import("../store/model.ts");
const { webviews } = await import("./webviews.ts");
const { carrySignInToWebKit } = await import("./engineSignIn.ts");

const S = () => useBrowser.getState();
const cookie = { name: "NetflixId", value: "v", domain: ".video.example", path: "/", expires: -1, session: true, httpOnly: true, secure: true };

function pageWithCookies() {
  let answer;
  const pending = new Promise((resolve) => (answer = resolve));
  return { handle: { pageCookies: () => pending }, answer: () => answer([cookie]) };
}

test("the default profile's cookies go to its WebKit store, whose key is the empty string", async () => {
  S().hydrate({});
  imports.length = 0;
  const w = S().createWindow({ url: "https://video.example/title/1" });
  const tabId = model.activeTabId(S(), w);
  const page = pageWithCookies();
  webviews.set(tabId, page.handle);
  const carried = carrySignInToWebKit(tabId, "https://video.example/title/1");
  page.answer();
  assert.equal(await carried, 1);
  assert.deepEqual(imports.map((i) => [i.profile, i.key, i.cookies.length]), [["", "", 1]]);
  webviews.clear();
});

test("closing the private window while the cookies are read imports nothing", async () => {
  S().hydrate({});
  imports.length = 0;
  const w = S().createWindow({ incognito: true, url: "https://video.example/title/1" });
  const tabId = model.activeTabId(S(), w);
  const page = pageWithCookies();
  webviews.set(tabId, page.handle);
  const carried = carrySignInToWebKit(tabId, "https://video.example/title/1");
  await Promise.resolve();
  S().closeWindow(w);
  page.answer();
  assert.equal(await carried, 0);
  assert.deepEqual(imports, []);
  webviews.clear();
});

test("a tab that moved to another profile while the cookies were read imports nothing", async () => {
  S().hydrate({});
  imports.length = 0;
  const w = S().createWindow({ url: "https://music.example/" });
  const tabId = model.activeTabId(S(), w);
  const page = pageWithCookies();
  webviews.set(tabId, page.handle);
  const carried = carrySignInToWebKit(tabId, "https://music.example/");
  await Promise.resolve();
  S().updateTab(tabId, { profileId: "work" });
  page.answer();
  assert.equal(await carried, 0);
  assert.deepEqual(imports, []);
  webviews.clear();
});

import assert from "node:assert/strict";
import { test } from "node:test";

globalThis.acTestNativeModules = {
  SolaraStoreAdapter: {
    status: () => ({ active: false, reason: "the native store refused to import: session.json could not be parsed", refusedSession: "/data/session.json" }),
    snapshot: () => null,
    dispatch: () => null,
    catchUp: () => null,
    flush: () => false,
    addListener: () => ({ remove() {} }),
  },
};

const { docs } = await import("../test-native/index.ts");
const { useBrowser } = await import("../store/browser.ts");
const { useToasts } = await import("../components/layout/toasts.ts");
const { flushPersistence, startPersistence } = await import("./persist.ts");

test("when the native store refuses the session, the JS store saves nothing and every window says where the session is", () => {
  const session = "{ not json";
  const downloads = JSON.stringify({ version: 2, downloads: [] });
  docs.set("session.json", session);
  docs.set("downloads.json", downloads);
  startPersistence();
  const s = useBrowser.getState();
  const first = s.createWindow({});
  s.updateSettings({ appearance: "dark" });
  s.upsertDownload({ id: "d", url: "https://e/", state: "complete", profile: "" });
  const second = useBrowser.getState().createWindow({});
  flushPersistence({ final: true });
  assert.equal(docs.get("session.json"), session);
  assert.equal(docs.get("downloads.json"), downloads);
  for (const windowId of [first, second]) {
    const notice = useToasts.getState().notices[windowId];
    assert.match(notice?.title ?? "", /couldn't read its saved session/);
    assert.match(notice?.message ?? "", /won't be saved.*\/data\/session\.json/);
  }
});

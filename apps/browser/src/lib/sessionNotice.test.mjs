import assert from "node:assert/strict";
import { test } from "node:test";

const { unreadableDocs } = await import("../test-native/index.ts");
const { useBrowser } = await import("../store/browser.ts");
const { hideToast, showToast, useToasts } = await import("../components/layout/toasts.ts");
const { startPersistence } = await import("./persist.ts");

test("the unsaved-session notice stays up when another toast comes and goes in its window", () => {
  unreadableDocs.set("session.json", "Permission denied");
  startPersistence();
  const windowId = useBrowser.getState().createWindow({});
  const notice = useToasts.getState().notices[windowId];
  assert.match(notice?.title ?? "", /couldn't read its saved session/);
  showToast(windowId, "Cannot Add New Pane", "Split View can show up to 4 tabs at once.");
  const toast = useToasts.getState().toasts[windowId];
  assert.equal(toast?.title, "Cannot Add New Pane");
  assert.deepEqual(useToasts.getState().notices[windowId], notice);
  hideToast(windowId, toast.id);
  assert.equal(useToasts.getState().toasts[windowId], null);
  assert.deepEqual(useToasts.getState().notices[windowId], notice);
});

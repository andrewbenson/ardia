#!/usr/bin/env node
// With ARDIA_NATIVE_SIDEBAR=1, a click on the empty sidebar under the rows ends a tab's rename the way RN's does since
// c69941d5: the typed name is kept, the field closes, and the click opens no tab. Esc still cancels.
//
//   node apps/browser/scripts/sidebar-rename-test.mjs <Debug Solara.app under apps/browser/build-*> [--keep-data]
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg || resolve(appArg).startsWith("/Applications/")) {
  console.error("usage: node sidebar-rename-test.mjs <Debug Solara.app under apps/browser/build-*> [--keep-data]");
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-sidebar-rename-"));
const rep = reporter(join(scratch, "sidebar-rename-test.log"), { name: "sidebar-rename-test" });
const ids = ["t0", "t1", "t2"];
const tabs = ids.map((id) => ({ id, url: `data:text/html,<title>Tab ${id}</title>`, title: `Tab ${id}` }));

const app = await launch(resolve(appArg), {
  data: join(scratch, "data"),
  env: { ARDIA_NATIVE_SIDEBAR: "1" },
  session: session({ profiles: ["Personal"], windows: [{ id: "w1", tabIds: ids, activeTabIds: { default: "t0" }, frame: [60, 60, 1200, 800] }], tabs }),
  ready: "return !!ac.store",
});
const run = (body) => app.eval(body, { timeout: 30000 });
const renaming = () => run(`return ac.sidebarRows.useSidebarUi.getState().renaming?.id ?? null`);
const tabCount = () => run(`return ac.store.getState().windows.w1.tabIds.length`);
const until = async (what, test, ms = 3000) => {
  const end = Date.now() + ms;
  for (;;) {
    if (await test()) return;
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await sleep(40);
  }
};
const startRename = async (id) => {
  await run(`ac.pages.setSidebarUi({ renaming: { windowId: "w1", kind: "tab", id: ${JSON.stringify(id)} } }); return true`);
  await sleep(400);
};

try {
  await sleep(2500);
  const last = await run(`return ac.sidebarRows.measureRow("w1", "t2")`);
  const blank = { x: last.x + 60, y: Math.round(last.y + last.height + 160) };

  await rep.check("a click on the empty sidebar keeps the typed name, closes the field and opens no tab", async () => {
    const before = await tabCount();
    await startRename("t1");
    await run(`return ac.shell.devTypeKeys("w1", "Renamed", 10)`);
    await sleep(200);
    const click = await run(`return ac.shell.devClick("w1", { x: ${blank.x}, y: ${blank.y} })`);
    rep.say(`clicked ${JSON.stringify(click)}`);
    await until("the field to close", async () => (await renaming()) === null);
    assert.equal(await run(`return ac.store.getState().tabs.t1.customTitle`), "Renamed");
    await sleep(500);
    assert.equal(await tabCount(), before, "no new tab");
  });

  await rep.check("a second click there right after opens no tab either", async () => {
    const before = await tabCount();
    await startRename("t2");
    await run(`return ac.shell.devTypeKeys("w1", "Second", 10)`);
    await sleep(200);
    await run(`return ac.shell.devClick("w1", { x: ${blank.x}, y: ${blank.y} })`);
    await run(`return ac.shell.devClick("w1", { x: ${blank.x}, y: ${blank.y} })`);
    await until("the field to close", async () => (await renaming()) === null);
    assert.equal(await run(`return ac.store.getState().tabs.t2.customTitle`), "Second");
    await sleep(500);
    assert.equal(await tabCount(), before, "no new tab");
  });

  await rep.check("Esc still cancels", async () => {
    await startRename("t0");
    await run(`return ac.shell.devTypeKeys("w1", "Nope", 10)`);
    await sleep(200);
    await run(`return ac.shell.devTypeKeys("w1", "\\u001b", 10)`);
    await until("the field to close", async () => (await renaming()) === null);
    assert.equal(await run(`return ac.store.getState().tabs.t0.customTitle ?? null`), null);
  });
} finally {
  await app.quit();
  if (!keep) rmSync(join(scratch, "data"), { recursive: true, force: true });
}
process.exit(rep.summary() ? 0 : 1);

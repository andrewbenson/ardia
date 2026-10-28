#!/usr/bin/env node
// The pinned tiles' folder panel, drawn by RN and then natively (ARDIA_NATIVE_SIDEBAR=1: SidebarFolderPanelView in
// the sidebar's panel layer), driven by clicks through the window: a click on the folder tile opens the panel under
// it, its member rows sit on RN's window frames within half a point, a click on a row shows that tab and closes the panel,
// and a click on the page, a second click on the tile and Escape each close it, as RN does.
//
//   node apps/browser/scripts/folder-panel-test.mjs <Debug Solara.app under apps/browser/build-*> [--keep-data]
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg || resolve(appArg).startsWith("/Applications/")) {
  console.error("usage: node folder-panel-test.mjs <Debug Solara.app under apps/browser/build-*> [--keep-data]");
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-folder-panel-"));
const rep = reporter(join(scratch, "folder-panel-test.log"), { name: "folder-panel-test" });

async function run(native) {
  const data = join(scratch, native ? "native" : "rn");
  mkdirSync(data, { recursive: true });
  const app = await launch(resolve(appArg), { data, onboarded: true, env: native ? { ARDIA_NATIVE_SIDEBAR: "1" } : {} });
  try {
    await app.ready({ test: "return !!globalThis.expo?.modules?.SolaraPages?.devViewFrame && !!ac.pages.tileFolders" });
    await sleep(4000);
    const win = await app.eval(`return globalThis.expo.modules.ArdiaCEF.chromeWindows().then((ws) => ws.find((w) => w.hasRoot).window)`);
    const dev = (action) => app.eval(`return globalThis.expo.modules.ArdiaCEF.devWindow(${win}, ${JSON.stringify(action)})`);
    await dev("fakeActiveClicks");
    const setup = JSON.parse(await app.eval(`const s = ac.store.getState(); const w = Object.keys(s.windows)[0];
      const ids = ["one", "two", "three"].map((n) => s.newTab(w, { url: "data:text/html,<title>" + n + "</title>" + n, background: true }));
      s.pinTabs(ids, true);
      return new Promise((r) => setTimeout(r, 800)).then(() => JSON.stringify({ w, ids, folder: ac.pages.tileFolders.make(ids) }))`));
    assert.ok(setup.folder, "a folder made");
    await sleep(1200);
    const q = JSON.stringify;
    const anchor = async () => JSON.parse(await app.eval(`return ac.pages.tileFolders.measure(${q(setup.w)}, ${q(setup.folder)}).then((a) => JSON.stringify(a))`));
    const isOpen = () => app.eval(`return !!ac.pages.tileFolders.panel.getState().open`);
    const active = () => app.eval(`const s = ac.store.getState(); const w = s.windows[${q(setup.w)}]; return w.activeTabIds[w.profileId]`);
    const tile = await anchor();
    assert.ok(tile, "the folder tile is laid out");
    const press = async (x, y) => {
      await dev(`mouse:down:${x},${y}`);
      await sleep(60);
      await dev(`mouse:up:${x},${y}`);
    };
    const clickTile = () => press(tile.x + tile.width / 2, tile.y + tile.height / 2);
    const rowFrames = async () => {
      if (native) {
        const rows = [];
        for (let i = 0; i < 3; i++) rows.push(JSON.parse(await app.eval(`return globalThis.expo.modules.SolaraPages.devViewFrame(${win}, "FolderPanelRow#${i}")`)));
        return rows.filter((r) => r.found).map(({ x, y, width, height }) => ({ x, y, width, height }));
      }
      return JSON.parse(await app.eval(`const c = globalThis.sidebarDrag;
        return Promise.all([...c.items.values()].filter((i) => i.view && i.section === "folder" && i.kind !== "tail").map((i) => new Promise((r) => i.view.measureInWindow((x, y, width, height) => r({ x, y, width, height })))))
          .then((l) => JSON.stringify(l.filter((f) => f.width > 0).sort((a, b) => a.y - b.y)))`));
    };
    const out = {};
    await clickTile();
    await sleep(700);
    out.opened = await isOpen();
    out.rows = await rowFrames();
    out.native = native ? JSON.parse(await app.eval(`return globalThis.expo.modules.SolaraPages.devViewFrame(${win}, "SidebarFolderPanelView")`)).found : false;
    if (out.rows[1]) await press(out.rows[1].x + out.rows[1].width / 2, out.rows[1].y + out.rows[1].height / 2);
    await sleep(500);
    out.rowShows = (await active()) === setup.ids[1];
    out.rowCloses = !(await isOpen());
    await clickTile();
    await sleep(700);
    out.openedAgain = await isOpen();
    await press(800, 500);
    await sleep(500);
    out.pageCloses = !(await isOpen());
    await clickTile();
    await sleep(700);
    const reopened = await isOpen();
    await clickTile();
    await sleep(700);
    out.tileCloses = reopened && !(await isOpen());
    await clickTile();
    await sleep(700);
    await dev("keys:0:\u001b:53");
    await sleep(500);
    out.escCloses = !(await isOpen());
    rep.say(`${native ? "native" : "RN"}: ${JSON.stringify(out)}`);
    return out;
  } finally {
    await app.quit();
    if (!keep) rmSync(data, { recursive: true, force: true });
  }
}

let rn = null;
let mine = null;
await rep.check("RN: a click on the tile opens the panel; a row shows its tab and closes it; the page, the tile and Escape close it", async () => {
  rn = await run(false);
  assert.ok(rn.opened, "opened");
  assert.equal(rn.rows.length, 3, "three member rows");
  assert.ok(rn.rowShows && rn.rowCloses, `row: ${rn.rowShows} ${rn.rowCloses}`);
  assert.ok(rn.pageCloses, "a click on the page");
  assert.ok(rn.tileCloses, "a second click on the tile");
  assert.ok(rn.escCloses, "Escape");
});
await rep.check("native: the same, in the sidebar's panel layer, with the rows on RN's frames", async () => {
  mine = await run(true);
  assert.ok(mine.native, "a SidebarFolderPanelView");
  assert.ok(mine.opened, "opened");
  assert.equal(mine.rows.length, 3, "three member rows");
  for (let i = 0; i < 3; i++) for (const k of ["x", "y", "width", "height"]) assert.ok(rn && Math.abs(mine.rows[i][k] - rn.rows[i][k]) <= 0.5, `row ${i} ${k}: ${mine.rows[i][k]} vs RN ${rn?.rows[i]?.[k]}`);
  for (const k of ["rowShows", "rowCloses", "pageCloses", "tileCloses", "escCloses"]) assert.equal(mine[k], rn?.[k], `${k} as RN`);
});
process.exit(rep.summary() ? 0 : 1);

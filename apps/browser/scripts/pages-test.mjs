#!/usr/bin/env node
// The native internal pages (ARDIA_NATIVE_PAGES=1) in a hidden instance, driven by clicks and keys: Downloads lists
// the window's downloads, the search field filters them and Escape clears it, ✕ removes one from the list and
// Clear All keeps only the running ones. History groups visits by day, search filters, hovering a row shows its
// checkbox, a click selects and shift-click extends the selection, Cancel clears it, and Clear Browsing Data… opens
// the dialog, whose Clear Data empties the history and closes it. Bookmarks shows the bar's bookmarks, the folder
// tree opens a folder, search finds across folders, click, ⌘-click and shift-click select, Delete removes with an
// Undo toast that puts them back, and dragging a row moves it.
//
//   node apps/browser/scripts/pages-test.mjs <Debug Solara.app under apps/browser/build-*> [--keep-data]
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg || resolve(appArg).startsWith("/Applications/")) {
  console.error("usage: node pages-test.mjs <Debug Solara.app under apps/browser/build-*> [--keep-data]");
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-pages-"));
const data = join(scratch, "data");
const files = join(scratch, "files");
mkdirSync(files);
writeFileSync(join(files, "report.pdf"), "report");
writeFileSync(join(files, "photo.png"), "photo");
const rep = reporter(join(scratch, "pages-test.log"), { name: "pages-test" });
const download = (id, filename, state, extra = {}) => ({
  id, url: `https://example.com/${filename}`, filename, path: join(files, filename), state, paused: false,
  received: 1000, total: state === "downloading" ? 4000 : 1000, speed: 0, mimeType: "", ...extra,
});
const downloads = [download("d1", "report.pdf", "finished"), download("d2", "photo.png", "finished"), download("d3", "big.zip", "downloading")];
let app = null;
const dev = (action) =>
  app.eval(`const C = globalThis.expo.modules.ArdiaCEF; return C.chromeWindows().then((ws) => C.devWindow(ws.find((w) => w.hasRoot).window, ${JSON.stringify(action)}))`);
const page = async () => JSON.parse(await app.eval(`return globalThis.expo.modules.SolaraPages.devPages()`)).pages[0];
const until = async (test, ms = 3000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await test();
    if (last.ok) return last;
    await sleep(100);
  }
  return last;
};
const frameOf = (current, label) => current.frames.find((f) => f.label === label);
const click = (frame) => dev(`click:${frame.x + frame.width / 2},${frame.y + frame.height / 2}`);

try {
  app = await launch(resolve(appArg), { data, onboarded: true, env: { ARDIA_NATIVE_PAGES: "1" } });
  await app.ready({ test: "return !!globalThis.expo?.modules?.SolaraPages?.devPages" });
  await sleep(5000);
  await app.eval(`const s = ac.store.getState(); const w = Object.keys(s.windows)[0]; for (const d of ${JSON.stringify(downloads)}) s.upsertDownload(d); s.setDownloadsOpen(w, false); ac.pages.openInternalPage("downloads", w); return true`);
  await dev("fakeActiveClicks");

  await rep.check("Downloads lists the window's downloads, newest first", async () => {
    const shown = await until(async () => {
      const p = await page();
      return { ok: p?.kind === "downloads" && p.shown.length === 3, p };
    });
    assert.deepEqual(shown.p?.shown, ["d3", "d2", "d1"]);
  });

  await rep.check("typing in the search field filters, Escape clears it", async () => {
    const p = await page();
    await click(frameOf(p, "Search downloads"));
    await sleep(200);
    await dev("type:photo");
    const filtered = await until(async () => {
      const now = await page();
      return { ok: now.query === "photo", now };
    });
    assert.equal(filtered.now.query, "photo");
    assert.deepEqual(filtered.now.shown, ["d2"]);
    await dev("keys:0:\u001b:53");
    const cleared = await until(async () => {
      const now = await page();
      return { ok: now.query === "", now };
    });
    assert.deepEqual(cleared.now.shown, ["d3", "d2", "d1"]);
  });

  await rep.check("✕ removes a download from the list", async () => {
    const p = await page();
    await click(frameOf(p, "remove:d2"));
    const after = await until(async () => {
      const ids = await app.eval(`return ac.store.getState().downloads.map((d) => d.id).join(",")`);
      return { ok: ids === "d3,d1", ids };
    });
    assert.equal(after.ids, "d3,d1");
  });

  await rep.check("Clear All keeps only the running download", async () => {
    const p = await page();
    await click(frameOf(p, "Clear All"));
    const after = await until(async () => {
      const ids = await app.eval(`return ac.store.getState().downloads.map((d) => d.id).join(",")`);
      return { ok: ids === "d3", ids };
    });
    assert.equal(after.ids, "d3");
  });
  const now = Date.now();
  const sites = ["https://news.example.com/", "https://github.com/solara", "https://en.wikipedia.org/wiki/Sun", "https://apple.example.net/mac"];
  const history = Array.from({ length: 8 }, (_, i) => ({ url: `${sites[i % 4]}?p=${i}`, title: `Page ${i}`, visits: 1, lastVisit: now - i * 5 * 3600_000 }));
  await app.eval(`const s = ac.store.getState(); const w = Object.keys(s.windows)[0]; s.importHistory(s.windows[w].profileId, ${JSON.stringify(history)}); ac.pages.openInternalPage("history", w); return true`);

  await rep.check("History lists every visit, newest first", async () => {
    const shown = await until(async () => {
      const p = await page();
      return { ok: p?.kind === "history" && p.shown.length === 8, p };
    });
    assert.deepEqual(shown.p?.shown, history.map((h) => h.url));
  });

  await rep.check("typing in the search field filters the history", async () => {
    const p = await page();
    await click(frameOf(p, "Search history"));
    await sleep(200);
    await dev("type:wikipedia");
    const filtered = await until(async () => {
      const now = await page();
      return { ok: now.query === "wikipedia" && now.shown.length === 2, now };
    });
    assert.deepEqual(filtered.now.shown, [history[2].url, history[6].url]);
    await dev("keys:0:\u001b:53");
    await until(async () => ({ ok: (await page()).shown.length === 8 }));
  });

  await rep.check("hovering shows a row's checkbox, click selects, shift-click extends, Cancel clears", async () => {
    const rowFrame = (p, url) => frameOf(p, `row:${url}`);
    const ready = await until(async () => {
      const now = await page();
      return { ok: !!rowFrame(now, history[1].url) && !!rowFrame(now, history[3].url), now };
    });
    assert.ok(ready.ok, `row frames: ${ready.now.frames.map((f) => f.label).join(" | ")}`);
    let p = ready.now;
    const first = rowFrame(p, history[1].url);
    await app.eval(`return globalThis.expo.modules.SolaraPages.devPageHover(${JSON.stringify(history[1].url)})`);
    const hovered = await until(async () => {
      const now = await page();
      return { ok: now.frames.some((f) => f.label === "Select" && Math.abs(f.y + f.height / 2 - (first.y + first.height / 2)) < 4), now };
    });
    assert.ok(hovered.ok, "checkbox on hover");
    const box = hovered.now.frames.find((f) => f.label === "Select" && Math.abs(f.y + f.height / 2 - (first.y + first.height / 2)) < 4);
    await click(box);
    await app.eval(`return globalThis.expo.modules.SolaraPages.devPageHover(null)`);
    const one = await until(async () => {
      const now = await page();
      return { ok: now.selected.length === 1, now };
    });
    assert.deepEqual(one.now.selected, [history[1].url]);
    p = one.now;
    const third = rowFrame(p, history[3].url);
    await dev(`mouse:down:${third.x + 200},${third.y + third.height / 2},1,${0x20000}`);
    await dev(`mouse:up:${third.x + 200},${third.y + third.height / 2},1,${0x20000}`);
    const range = await until(async () => {
      const now = await page();
      return { ok: now.selected.length === 3, now };
    });
    assert.deepEqual(range.now.selected, [history[1].url, history[2].url, history[3].url].sort());
    await click(frameOf(range.now, "Cancel"));
    const none = await until(async () => {
      const now = await page();
      return { ok: now.selected.length === 0, now };
    });
    assert.equal(none.now.selected.length, 0);
  });

  await rep.check("Clear Browsing Data… opens the dialog; Clear Data empties the history and closes it", async () => {
    const p = await page();
    await click(frameOf(p, "Clear Browsing Data…"));
    const open = await until(async () => {
      const now = await page();
      return { ok: now.clearOpen && !!frameOf(now, "Clear Data"), now };
    });
    assert.ok(open.ok, "dialog open");
    await click(frameOf(open.now, "Clear Data"));
    const cleared = await until(async () => {
      const now = await page();
      return { ok: !now.clearOpen, now };
    }, 8000);
    assert.equal(cleared.now.clearOpen, false, "dialog closed");
    assert.deepEqual(cleared.now.shown, history.slice(1).map((h) => h.url), "the last hour's visit is gone");
  });
  const seeded = await app.eval(`const s = ac.store.getState(); const w = Object.keys(s.windows)[0]; const profileId = s.windows[w].profileId; const bar = s.bookmarks.roots[profileId].bar;
    const work = s.addBookmarkFolder({ profileId, title: "Work", parentId: bar });
    const ids = ["alpha", "beta", "gamma", "delta"].map((t) => s.addBookmark({ profileId, url: "https://" + t + ".example.com/", title: t[0].toUpperCase() + t.slice(1), parentId: bar }));
    const inner = s.addBookmark({ profileId, url: "https://reports.example.org/q4", title: "Q4 Report", parentId: work });
    ac.pages.openInternalPage("bookmarks", w);
    return JSON.stringify({ bar, work, ids, inner })`);
  const marks = JSON.parse(seeded);
  const barIds = () => app.eval(`const s = ac.store.getState(); return s.bookmarks.nodes[${JSON.stringify(marks.bar)}].children.join(",")`);

  await rep.check("Bookmarks lists the bar's bookmarks and folders", async () => {
    const shown = await until(async () => {
      const p = await page();
      return { ok: p?.kind === "bookmarks" && p.shown.length === 5, p };
    });
    assert.deepEqual(shown.p?.shown, [marks.work, ...marks.ids]);
  });

  await rep.check("the folder tree opens a folder; search finds across folders", async () => {
    let p = await until(async () => {
      const now = await page();
      return { ok: !!frameOf(now, `folder:${marks.work}`), now };
    });
    await click(frameOf(p.now, `folder:${marks.work}`));
    const inWork = await until(async () => {
      const now = await page();
      return { ok: now.folder === marks.work, now };
    });
    assert.deepEqual(inWork.now.shown, [marks.inner]);
    await click(frameOf(inWork.now, "Search bookmarks"));
    await sleep(200);
    await dev("type:report");
    const found = await until(async () => {
      const now = await page();
      return { ok: now.query === "report", now };
    });
    assert.deepEqual(found.now.shown, [marks.inner]);
    await dev("keys:0:\u001b:53");
    p = await until(async () => ({ ok: (await page()).query === "", now: await page() }));
    await click(frameOf(p.now, `folder:${marks.bar}`));
    await until(async () => ({ ok: (await page()).folder === marks.bar }));
  });

  await rep.check("click, ⌘-click and shift-click select; Delete removes with an Undo toast that restores", async () => {
    let p = await until(async () => {
      const now = await page();
      return { ok: marks.ids.every((id) => frameOf(now, `bookmark:${id}`)), now };
    });
    const at = (id) => { const f = frameOf(p.now, `bookmark:${id}`); return `${f.x + 120},${f.y + f.height / 2}`; };
    await dev(`click:${at(marks.ids[0])}`);
    const one = await until(async () => {
      const now = await page();
      return { ok: now?.selected.length === 1, now };
    });
    assert.deepEqual(one.now?.selected, [marks.ids[0]], `tabs: ${await app.eval("return JSON.stringify(Object.values(ac.store.getState().tabs).map((t) => t.url))")}`);
    await sleep(600);
    await dev(`mouse:down:${at(marks.ids[2])},1,${0x100000}`);
    await dev(`mouse:up:${at(marks.ids[2])},1,${0x100000}`);
    const two = await until(async () => {
      const now = await page();
      return { ok: now.selected.length === 2, now };
    });
    assert.deepEqual(two.now.selected, [marks.ids[0], marks.ids[2]]);
    await sleep(600);
    await dev(`click:${at(marks.ids[0])}`);
    await sleep(600);
    await dev(`mouse:down:${at(marks.ids[3])},1,${0x20000}`);
    await dev(`mouse:up:${at(marks.ids[3])},1,${0x20000}`);
    const range = await until(async () => {
      const now = await page();
      return { ok: now.selected.length === 4, now };
    });
    assert.deepEqual(range.now.selected, marks.ids);
    await click(frameOf(range.now, "Delete"));
    const gone = await until(async () => {
      const now = await page();
      return { ok: now.undo === 4 && now.shown.length === 1, now };
    });
    assert.equal(gone.now.undo, 4, "undo toast");
    assert.equal(await barIds(), marks.work);
    const toast = await until(async () => {
      const now = await page();
      return { ok: !!frameOf(now, "Undo"), now };
    });
    await click(frameOf(toast.now, "Undo"));
    const back = await until(async () => ({ ok: (await barIds()) === [marks.work, ...marks.ids].join(","), now: await page() }));
    assert.ok(back.ok, `bar after undo: ${await barIds()}`);
  });

  await rep.check("dragging a row below another moves it there", async () => {
    const p = await until(async () => {
      const now = await page();
      return { ok: marks.ids.every((id) => frameOf(now, `bookmark:${id}`)), now };
    });
    const from = frameOf(p.now, `bookmark:${marks.ids[0]}`);
    const to = frameOf(p.now, `bookmark:${marks.ids[2]}`);
    await dev(`drag:${from.x + 120},${from.y + from.height / 2};${to.x + 120},${to.y + to.height * 0.8}`);
    const moved = await until(async () => ({ ok: (await barIds()) === [marks.work, marks.ids[1], marks.ids[2], marks.ids[0], marks.ids[3]].join(",") }), 4000);
    assert.ok(moved.ok, `bar after drag: ${await barIds()}`);
  });
} finally {
  await app?.quit();
  if (!keep) for (const dir of [data, files]) rmSync(dir, { recursive: true, force: true });
  else rep.say(`data: ${data}`);
}
process.exit(rep.summary() ? 0 : 1);

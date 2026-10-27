#!/usr/bin/env node
// The native internal pages (ARDIA_NATIVE_PAGES=1) in a hidden instance, driven by clicks and keys: Downloads lists
// the window's downloads, the search field filters them and Escape clears it, ✕ removes one from the list and
// Clear All keeps only the running ones.
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
    await click(p.frames.filter((f) => f.label === "Remove from List")[0]);
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
} finally {
  await app?.quit();
  if (!keep) for (const dir of [data, files]) rmSync(dir, { recursive: true, force: true });
  else rep.say(`data: ${data}`);
}
process.exit(rep.summary() ? 0 : 1);

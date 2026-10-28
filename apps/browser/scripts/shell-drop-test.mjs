#!/usr/bin/env node
// With the native window shell on (ARDIA_NATIVE_SHELL=1), a file, link or text dragged over the page still lands on
// Chromium's web contents: no shell view above the page registers those drag types, as in RN. Checked with the page
// alone, with the zoom popover open in the pane overlays, with a sidebar hover card shown, and with two tabs in the
// native split chrome. A drop on the zoom popover's card must go where RN's does: the same point is probed in an RN
// instance (shell and native toolbar off), and the shell must hand the drop to the same kind of view.
//
//   node apps/browser/scripts/shell-drop-test.mjs <Debug Solara.app under apps/browser/build-*> [--keep-data]
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg || resolve(appArg).startsWith("/Applications/")) {
  console.error("usage: node shell-drop-test.mjs <Debug Solara.app under apps/browser/build-*> [--keep-data]");
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-shell-drop-"));
const rep = reporter(join(scratch, "shell-drop-test.log"), { name: "shell-drop-test" });
const TYPES = ["public.file-url", "public.url", "public.utf8-plain-text"];
const WEB = /RenderWidgetHostViewCocoa|WebContentsViewCocoa|ArdiaCoreWebView/;
const PAGE = "data:text/html,<body style='height:2000px'>drop here</body>";

async function open(env, dir) {
  const app = await launch(resolve(appArg), { data: join(scratch, dir), onboarded: true, env });
  await app.ready({ test: "return !!globalThis.expo?.modules?.SolaraPages?.devDropTarget" });
  await sleep(4000);
  await app.eval(`const s = ac.store.getState(); const w = Object.keys(s.windows)[0]; s.newTab(w, { url: ${JSON.stringify(PAGE)} }); return true`);
  await sleep(3000);
  const win = await app.eval(`const C = globalThis.expo.modules.ArdiaCEF; return C.chromeWindows().then((ws) => ws.find((w) => w.hasRoot).window)`);
  const info = JSON.parse(await app.eval(`const C = globalThis.expo.modules.ArdiaCEF; return C.devWindow(${win}, "winfo")`));
  const [, , w, h] = info.frame.replace(/[{}]/g, "").split(",").map(Number);
  const tab = await app.eval(`const s = ac.store.getState(); const w = Object.keys(s.windows)[0]; return s.windows[w].activeTabIds[s.windows[w].profileId]`);
  const target = async (x, y, type) => JSON.parse(await app.eval(`return globalThis.expo.modules.SolaraPages.devDropTarget(${win}, ${x}, ${y}, ${JSON.stringify(type)})`));
  const frameOf = async (needle) => JSON.parse(await app.eval(`return globalThis.expo.modules.SolaraPages.devViewFrame(${win}, ${JSON.stringify(needle)})`));
  const zoom = (on) => app.eval(`ac.pageState.setState((s) => ({ popover: { ...s.popover, [${JSON.stringify(tab)}]: ${on ? '"zoom"' : "null"} } })); return true`);
  return { app, w, h, tab, target, frameOf, zoom };
}

let shell = null;
let rn = null;
try {
  shell = await open({ ARDIA_NATIVE_SHELL: "1" }, "shell-data");
  const { w, h } = shell;
  const page = [Math.round(w * 0.6), Math.round(h * 0.6)];
  const pageGoesToWeb = async (label, at = page) => {
    for (const type of TYPES) {
      const hit = await shell.target(at[0], at[1], type);
      assert.match(String(hit.view), WEB, `${label}: ${type} taken by ${hit.chain?.join(" < ")}`);
    }
  };

  await rep.check("with the page alone, file, URL and text drops go to the web contents", () => pageGoesToWeb("alone"));

  let onPopover = null;
  const nativeOnPopover = {};
  await rep.check("with the zoom popover open, a drop beside it reaches the page", async () => {
    await shell.zoom(true);
    await sleep(800);
    const pop = await shell.frameOf("PopoverView");
    assert.ok(pop.found, "popover shown");
    onPopover = [Math.round(pop.x + pop.width / 2), Math.round(pop.y + Math.min(pop.height, 40) / 2)];
    await pageGoesToWeb("beside the popover", [Math.round(w * 0.4), Math.round(h * 0.75)]);
    for (const type of TYPES) nativeOnPopover[type] = WEB.test(String((await shell.target(onPopover[0], onPopover[1], type)).view));
    await shell.zoom(false);
    await sleep(400);
  });

  await rep.check("with a sidebar hover card shown, a drop on the page still reaches it", async () => {
    await shell.app.eval(`const s = ac.store.getState(); const w = Object.keys(s.windows)[0]; ac.pages.setSidebarUi({ hover: { windowId: w, kind: "tab", id: ${JSON.stringify(shell.tab)}, anchor: { x: 10, y: 120, width: 240, height: 32 } } }); return true`);
    await sleep(800);
    await pageGoesToWeb("with a hover card");
    await shell.app.eval(`ac.pages.setSidebarUi({ hover: null }); return true`);
  });

  await rep.check("with two tabs in a split, a drop on either pane reaches the web contents", async () => {
    await shell.app.eval(`const s = ac.store.getState(); const w = Object.keys(s.windows)[0]; const other = s.newTab(w, { url: "data:text/html,<body>right</body>" }); s.createSplit([${JSON.stringify(shell.tab)}, other]); return true`);
    await sleep(2000);
    assert.ok((await shell.frameOf("SplitChromeView")).found, "the native split chrome shown");
    await pageGoesToWeb("left pane", [Math.round(w * 0.35), Math.round(h * 0.6)]);
    await pageGoesToWeb("right pane", [Math.round(w * 0.8), Math.round(h * 0.6)]);
  });
  await shell.app.quit();
  shell = null;

  await rep.check("a drop on the zoom popover goes where RN's does", async () => {
    assert.ok(onPopover, "the shell's popover point");
    rn = await open({ ARDIA_NATIVE_SHELL: "0", ARDIA_NATIVE_TOOLBAR: "0" }, "rn-data");
    await rn.zoom(true);
    await sleep(800);
    const rnOnPopover = {};
    for (const type of TYPES) rnOnPopover[type] = WEB.test(String((await rn.target(onPopover[0], onPopover[1], type)).view));
    rep.say(`on the popover, to the page? RN ${JSON.stringify(rnOnPopover)}, shell ${JSON.stringify(nativeOnPopover)}`);
    assert.deepEqual(nativeOnPopover, rnOnPopover);
  });
} finally {
  await shell?.app.quit();
  await rn?.app.quit();
  if (!keep) for (const dir of ["shell-data", "rn-data"]) rmSync(join(scratch, dir), { recursive: true, force: true });
}
process.exit(rep.summary() ? 0 : 1);

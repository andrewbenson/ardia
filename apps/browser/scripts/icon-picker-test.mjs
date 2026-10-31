#!/usr/bin/env node
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg || resolve(appArg).startsWith("/Applications/") || args.some((arg) => arg.startsWith("--") && arg !== "--keep-data")) {
  console.error("usage: node icon-picker-test.mjs <Debug Solara.app under apps/browser/build-*> [--keep-data]");
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-icon-picker-"));
const rep = reporter(join(scratch, "icon-picker-test.log"), { name: "icon-picker-test" });
const ids = Array.from({ length: 8 }, (_, i) => `t${i}`);
const tabs = ids.map((id) => ({ id, url: `data:text/html,<title>Tab ${id}</title>`, title: `Tab ${id}` }));
const layout = { windows: [{ id: "w1", tabIds: ids, activeTabIds: { default: "t1" }, frame: [60, 60, 1200, 800] }], tabs };
const CELL = 30;
const INSET = 8.5;

async function start() {
  const app = await launch(resolve(appArg), {
    data: join(scratch, "native"),
    env: { SOLARA_NATIVE_SIDEBAR: "1", SOLARA_NATIVE_SHELL: "1" },
    probe: true,
    session: session(layout),
    ready: "return !!ac.store",
  });
  return { app, run: (body) => app.eval(body, { timeout: 30000 }) };
}

const untilSnapshot = async (app, what, accept, ms = 5000) => {
  const deadline = Date.now() + ms;
  let last;
  while (Date.now() < deadline) {
    last = await app.snapshot({ windowId: "w1" }).catch((error) => ({ error: error.message }));
    if (!last.error && last.consistent && accept(last)) return last;
    await sleep(100);
  }
  throw new Error(`${what}: native snapshot never matched (${JSON.stringify(last)})`);
};
const nativePicker = (state) => state.windows.find((window) => window.id === "w1")?.iconPicker;
const nativeIcon = async (app, id, icon) => untilSnapshot(app, `native icon for ${id}`, (state) => state.tabs.find((tab) => tab.id === id)?.customIcon === icon);
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const until = async (what, test, ms = 3000) => {
  const end = Date.now() + ms;
  for (;;) {
    const value = await test();
    if (value) return value;
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await sleep(50);
  }
};
const openPicker = (run, kind, id) =>
  run(`return ac.sidebarRows.measureRow("w1", ${JSON.stringify(id)}).then((anchor) => { ac.sidebarRows.setSidebarUi({ iconPicker: { windowId: "w1", kind: ${JSON.stringify(kind)}, id: ${JSON.stringify(id)}, anchor } }); return true; })`);

let native;
try {
  native = await start();
  const { run } = native;
  await sleep(2500);
  const picker = async () => JSON.parse(await run(`return globalThis.expo.modules.SolaraHosted.sidebarIconPicker("w1")`));
  const input = (action) => run(`return globalThis.expo.modules.SolaraHosted.sidebarIconPickerInput("w1", ${JSON.stringify(action)})`);
  const click = (x, y) => run(`return ac.shell.devClick("w1", { x: ${x}, y: ${y} })`);
  const point = (x, y) => run(`return ac.shell.devSetPointer("w1", { x: ${x}, y: ${y} })`);
  const open = async (kind, id) => {
    await openPicker(run, kind, id);
    const p = await until("the picker shows", async () => ((await picker())?.panel ? picker() : null));
    await untilSnapshot(native.app, "native picker frame and labels", (state) => {
      const read = nativePicker(state);
      return read && same(read.panel, p.panel) && read.tab === p.tab && read.focused === p.focused &&
        read.items === p.items && read.first === p.first && same(read.footer, p.footer);
    });
    return p;
  };
  const closed = async () => {
    await until("the picker closes", async () => (await picker()) === null && (await run(`return ac.sidebarRows.useSidebarUi.getState().iconPicker`)) === null);
    await untilSnapshot(native.app, "native picker dismissed", (state) => nativePicker(state) === null);
  };
  const icon = (id) => run(`return ac.store.getState().tabs[${JSON.stringify(id)}].customIcon ?? null`);
  const cellCenter = (panel, index) => [panel[0] + INSET + (index % 7) * CELL + CELL / 2, panel[1] + INSET + 26 + 8 + Math.floor(index / 7) * CELL + CELL / 2];
  const footerCenter = (panel) => [panel[0] + 128, panel[1] + panel[3] - INSET - 13];

  await rep.check("it opens beside the row at the expected frame, focused", async () => {
    const p = await open("tab", "t3");
    const anchor = JSON.parse(await run(`return ac.sidebarRows.measureRow("w1", "t3").then((a) => JSON.stringify(a))`));
    assert.deepEqual(p.panel, [Math.max(8, Math.min(240 + 6, anchor.x + anchor.width + 6)), Math.max(8, anchor.y - 8), 256, 231]);
    assert.equal(p.tab, "emoji");
    assert.equal(p.focused, true, "the search field has the keys");
    assert.equal(p.items, 108);
    assert.deepEqual(p.footer, []);
  });

  await rep.check("typing filters, and Return takes the first match and closes", async () => {
    await input("type:pizza");
    const p = await until("one match", async () => ((await picker())?.items === 1 ? picker() : null));
    assert.equal(p.first, "🍕");
    await untilSnapshot(native.app, "native filtered picker", (state) => nativePicker(state)?.items === p.items && nativePicker(state)?.first === p.first);
    await input("return");
    await closed();
    assert.equal(await icon("t3"), "🍕");
    await nativeIcon(native.app, "t3", "🍕");
  });

  await rep.check("Escape closes it without a change, and a typed miss shows No matches", async () => {
    let p = await open("tab", "t3");
    assert.deepEqual(p.footer, ["Reset Icon"], "a custom icon offers Reset Icon");
    assert.equal(p.panel[3], 265);
    await input("type:zzzz");
    p = await until("no matches", async () => ((await picker())?.items === 0 ? picker() : null));
    assert.equal(p.panel[3], 82 + 34);
    await untilSnapshot(native.app, "native no-match picker", (state) => nativePicker(state)?.items === 0 && same(nativePicker(state)?.panel, p.panel));
    await input("escape");
    await closed();
    assert.equal(await icon("t3"), "🍕");
  });

  await rep.check("a hovered cell lights, and a click on a cell sets that icon", async () => {
    const p = await open("tab", "t3");
    const [x, y] = cellCenter(p.panel, 2);
    await point(x, y);
    await until("the third cell hovered", async () => (await picker())?.hovered === "❤️");
    await untilSnapshot(native.app, "native hovered icon", (state) => nativePicker(state)?.hovered === "❤️");
    await point(900, 600);
    await until("the hover leaves", async () => (await picker())?.hovered === null);
    await click(x, y);
    await closed();
    assert.equal(await icon("t3"), "❤️");
    await nativeIcon(native.app, "t3", "❤️");
  });

  await rep.check("the Icons tab lists symbols, a click there sets one, and a symbol icon reopens on it", async () => {
    let p = await open("tab", "t4");
    await click(p.panel[0] + 256 - INSET - 14, p.panel[1] + INSET + 13);
    p = await until("the Icons tab", async () => ((await picker())?.tab === "symbols" ? picker() : null));
    assert.equal(p.items, 78);
    assert.equal(p.first, "symbol:star");
    await untilSnapshot(native.app, "native symbols tab", (state) => nativePicker(state)?.tab === p.tab && nativePicker(state)?.items === p.items && nativePicker(state)?.first === p.first);
    const [x, y] = cellCenter(p.panel, 1);
    await click(x, y);
    await closed();
    assert.equal(await icon("t4"), "symbol:heart");
    await nativeIcon(native.app, "t4", "symbol:heart");
    p = await open("tab", "t4");
    assert.equal(p.tab, "symbols");
    await input("escape");
    await closed();
  });

  await rep.check("Reset Icon clears a custom icon", async () => {
    const p = await open("tab", "t3");
    await click(...footerCenter(p.panel));
    await closed();
    assert.equal(await icon("t3"), null);
    await nativeIcon(native.app, "t3", null);
  });

  await rep.check("a group gets No Icon from its footer", async () => {
    const groupId = await run(`return ac.store.getState().groupTabs(["t5", "t6"])`);
    assert.ok(groupId, "a group made");
    await sleep(600);
    const p = await open("group", groupId);
    assert.deepEqual(p.footer, ["No Icon"]);
    await click(...footerCenter(p.panel));
    await closed();
    assert.equal(await run(`return ac.store.getState().groups[${JSON.stringify(groupId)}].icon`), "symbol:square.stack.fill");
  });

  await rep.check("a click outside closes it without a change", async () => {
    await open("tab", "t3");
    await click(900, 600);
    await closed();
    assert.equal(await icon("t3"), null);
  });
} finally {
  await native?.app.quit();
}

const ok = rep.summary();
if (!keep) rmSync(scratch, { recursive: true, force: true });
process.exit(ok ? 0 : 1);

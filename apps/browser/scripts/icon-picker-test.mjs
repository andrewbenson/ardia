#!/usr/bin/env node
// The native sidebar's icon picker in the window shell's overlay (ARDIA_NATIVE_ICON_PICKER=1 with ARDIA_NATIVE_SIDEBAR=1
// and ARDIA_NATIVE_SHELL=1): it opens beside the row at RN's frame with its search field focused and RN draws none of
// its own; typing filters, Return takes the first match and Escape closes without a change; a hovered cell lights; a
// click on a cell sets that icon, the Icons tab lists symbols, Reset Icon clears a custom icon and a group gets No Icon;
// a click outside closes it. Without the switch RN's picker shows and the native one stays hidden.
//
//   node apps/browser/scripts/icon-picker-test.mjs <Debug Solara.app under apps/browser/build-*> [--keep-data]
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg || resolve(appArg).startsWith("/Applications/")) {
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

async function start(name, env) {
  const app = await launch(resolve(appArg), {
    data: join(scratch, name),
    env: { ARDIA_NATIVE_SIDEBAR: "1", ARDIA_NATIVE_SHELL: "1", ...env },
    probe: true,
    session: session(layout),
    ready: "return !!ac.store",
  });
  return { app, run: (body) => app.eval(body, { timeout: 30000 }) };
}

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
  native = await start("native", { ARDIA_NATIVE_ICON_PICKER: "1" });
  const { run } = native;
  await sleep(2500);
  const picker = async () => JSON.parse(await run(`return globalThis.expo.modules.SolaraHosted.sidebarIconPicker("w1")`));
  const input = (action) => run(`return globalThis.expo.modules.SolaraHosted.sidebarIconPickerInput("w1", ${JSON.stringify(action)})`);
  const click = (x, y) => run(`return ac.shell.devClick("w1", { x: ${x}, y: ${y} })`);
  const point = (x, y) => run(`return ac.shell.devSetPointer("w1", { x: ${x}, y: ${y} })`);
  const open = async (kind, id) => {
    await openPicker(run, kind, id);
    return until("the picker shows", async () => ((await picker())?.panel ? picker() : null));
  };
  const closed = () => until("the picker closes", async () => (await picker()) === null && (await run(`return ac.sidebarRows.useSidebarUi.getState().iconPicker`)) === null);
  const icon = (id) => run(`return ac.store.getState().tabs[${JSON.stringify(id)}].customIcon ?? null`);
  const cellCenter = (panel, index) => [panel[0] + INSET + (index % 7) * CELL + CELL / 2, panel[1] + INSET + 26 + 8 + Math.floor(index / 7) * CELL + CELL / 2];
  const footerCenter = (panel) => [panel[0] + 128, panel[1] + panel[3] - INSET - 13];

  await rep.check("it opens beside the row at RN's frame, focused, and RN draws none of its own", async () => {
    const p = await open("tab", "t3");
    const anchor = JSON.parse(await run(`return ac.sidebarRows.measureRow("w1", "t3").then((a) => JSON.stringify(a))`));
    assert.deepEqual(p.panel, [Math.max(8, Math.min(240 + 6, anchor.x + anchor.width + 6)), Math.max(8, anchor.y - 8), 256, 231]);
    assert.equal(p.tab, "emoji");
    assert.equal(p.focused, true, "the search field has the keys");
    assert.equal(p.items, 108);
    assert.deepEqual(p.footer, []);
    assert.equal(await run(`return acPerf.findFibers("PickerPanel", 5).length`), 0, "RN draws no picker");
  });

  await rep.check("typing filters, and Return takes the first match and closes", async () => {
    await input("type:pizza");
    const p = await until("one match", async () => ((await picker())?.items === 1 ? picker() : null));
    assert.equal(p.first, "🍕");
    await input("return");
    await closed();
    assert.equal(await icon("t3"), "🍕");
  });

  await rep.check("Escape closes it without a change, and a typed miss shows No matches", async () => {
    let p = await open("tab", "t3");
    assert.deepEqual(p.footer, ["Reset Icon"], "a custom icon offers Reset Icon");
    assert.equal(p.panel[3], 265);
    await input("type:zzzz");
    p = await until("no matches", async () => ((await picker())?.items === 0 ? picker() : null));
    assert.equal(p.panel[3], 82 + 34);
    await input("escape");
    await closed();
    assert.equal(await icon("t3"), "🍕");
  });

  await rep.check("a hovered cell lights, and a click on a cell sets that icon", async () => {
    const p = await open("tab", "t3");
    const [x, y] = cellCenter(p.panel, 2);
    await point(x, y);
    await until("the third cell hovered", async () => (await picker())?.hovered === "❤️");
    await point(900, 600);
    await until("the hover leaves", async () => (await picker())?.hovered === null);
    await click(x, y);
    await closed();
    assert.equal(await icon("t3"), "❤️");
  });

  await rep.check("the Icons tab lists symbols, a click there sets one, and a symbol icon reopens on it", async () => {
    let p = await open("tab", "t4");
    await click(p.panel[0] + 256 - INSET - 14, p.panel[1] + INSET + 13);
    p = await until("the Icons tab", async () => ((await picker())?.tab === "symbols" ? picker() : null));
    assert.equal(p.items, 78);
    assert.equal(p.first, "symbol:star");
    const [x, y] = cellCenter(p.panel, 1);
    await click(x, y);
    await closed();
    assert.equal(await icon("t4"), "symbol:heart");
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

let rn;
try {
  rn = await start("rn", { ARDIA_NATIVE_ICON_PICKER: "0" });
  const { run } = rn;
  await sleep(2500);
  await rep.check("without the switch RN's picker shows and the native one stays hidden", async () => {
    await openPicker(run, "tab", "t3");
    await sleep(800);
    assert.equal(await run(`return acPerf.findFibers("PickerPanel", 5).length`), 1, "RN draws its picker");
    assert.equal(await run(`return globalThis.expo.modules.SolaraHosted.sidebarIconPicker("w1")`), "null");
  });
} finally {
  await rn?.app.quit();
}

const ok = rep.summary();
if (!keep) rmSync(scratch, { recursive: true, force: true });
process.exit(ok ? 0 : 1);

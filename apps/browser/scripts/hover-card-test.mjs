#!/usr/bin/env node
// The native sidebar's hover cards in the window shell's overlay (ARDIA_NATIVE_SIDEBAR=1, ARDIA_NATIVE_SHELL=1): a
// card shows after RN's 500 ms intent and not before, RN draws none of its own, moving onto the card keeps it past the
// 160 ms hide delay, its buttons act, and it leaves on hover away, a click in the sidebar and a tab switch.
//
//   node apps/browser/scripts/hover-card-test.mjs <Debug Solara.app under apps/browser/build-*> [--keep-data]
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg || resolve(appArg).startsWith("/Applications/")) {
  console.error("usage: node hover-card-test.mjs <Debug Solara.app under apps/browser/build-*> [--keep-data]");
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-hover-card-"));
const rep = reporter(join(scratch, "hover-card-test.log"), { name: "hover-card-test" });
const ids = Array.from({ length: 8 }, (_, i) => `t${i}`);
const tabs = ids.map((id, i) => ({ id, url: `https://example.com/?${id}`, title: i === 3 ? "Anker USB-C to USB-C Cable (240W, 6 ft), Nylon Braided" : `Tab ${id}` }));

const app = await launch(resolve(appArg), {
  data: join(scratch, "data"),
  env: { ARDIA_NATIVE_SIDEBAR: "1", ARDIA_NATIVE_SHELL: "1" },
  probe: true,
  session: session({ profiles: ["Personal"], windows: [{ id: "w1", tabIds: ids, activeTabIds: { default: "t1" }, frame: [60, 60, 1200, 800] }], tabs }),
  ready: "return !!ac.store",
});
const run = (body) => app.eval(body, { timeout: 30000 });
const card = async () => JSON.parse(await run(`return globalThis.expo.modules.SolaraHosted.sidebarHoverCard("w1")`));
const hover = () => run(`const h = ac.sidebarRows.useSidebarUi.getState().hover; return h ? h.id : null`);
const point = (x, y) => run(`return ac.shell.devSetPointer("w1", { x: ${x}, y: ${y} })`);
const rnCards = () => run(`return acPerf.findFibers("DiaTabCard", 5).length`);
const row = async (id) => run(`return ac.sidebarRows.measureRow("w1", ${JSON.stringify(id)})`);
const until = async (what, test, ms = 3000) => {
  const end = Date.now() + ms;
  for (;;) {
    const got = await test();
    if (got) return got;
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await sleep(40);
  }
};
const onRow = async (id) => {
  const r = await row(id);
  await point(r.x + 60, Math.round(r.y + r.height / 2));
  return r;
};
const shown = (id) => until(`the card for ${id}`, async () => (await hover()) === id && (await card())?.phase === "shown" && (await card()));
const gone = (what) => until(`the card to leave on ${what}`, async () => (await card())?.phase === "hidden" && !(await hover()), 1500);

try {
  await sleep(3000);

  await rep.check("a card waits for the 500 ms hover intent, then shows natively with no RN card", async () => {
    const t0 = Date.now();
    await onRow("t3");
    await sleep(300);
    assert.equal(await hover(), null, "nothing at 300 ms");
    assert.equal((await card())?.phase ?? "hidden", "hidden", "no native card at 300 ms");
    const c = await shown("t3");
    rep.say(`shown after ${Date.now() - t0} ms at ${c.frame.map(Math.round)}`);
    assert.ok(c.inWindow && c.onScreen && c.opacity > 0.99, "on screen and opaque");
    assert.equal(await rnCards(), 0, "RN draws no Dia card of its own");
    assert.deepEqual(Object.keys(c.buttons).sort(), ["Bookmark", "Open in Split View", "Pin"]);
  });

  await rep.check("moving from the row onto the card keeps it past the hide delay", async () => {
    const c = await card();
    const [x, y, w, h] = c.frame;
    await point(x + w / 2, y + 12);
    await sleep(600);
    assert.equal(await hover(), "t3");
    assert.equal((await card()).phase, "shown");
  });

  await rep.check("the card's Pin button pins the tab and the card stays", async () => {
    const [x, y, w, h] = (await card()).buttons.Pin;
    await run(`return ac.shell.devClick("w1", { x: ${x + w / 2}, y: ${y + h / 2} })`);
    await until("t3 pinned", () => run(`return !!ac.store.getState().tabs.t3.pinned`));
    await until("the card to show Unpin", async () => !!(await card())?.buttons?.Unpin);
    assert.equal((await card()).phase, "shown");
    await run(`ac.store.getState().togglePin("t3"); return true`);
  });

  await rep.check("hovering away hides it after the 160 ms delay and the 100 ms fade", async () => {
    const t0 = Date.now();
    await point(900, 600);
    await sleep(100);
    assert.equal((await card()).phase, "shown", "still shown inside the delay");
    await gone("hover away");
    rep.say(`gone after ${Date.now() - t0} ms`);
  });

  await rep.check("a tab switch dismisses it", async () => {
    await onRow("t4");
    await shown("t4");
    await run(`ac.actions.switchToTab("t5"); return true`);
    await gone("a tab switch");
  });

  await rep.check("a click in the sidebar dismisses it", async () => {
    await point(900, 600);
    await gone("hover away");
    const r = await onRow("t6");
    await shown("t6");
    await run(`return ac.shell.devClick("w1", { x: ${r.x + 60}, y: ${Math.round(r.y + r.height / 2)} })`);
    await gone("a click");
  });
} finally {
  await app.quit();
  if (!keep) rmSync(join(scratch, "data"), { recursive: true, force: true });
}
process.exit(rep.summary() ? 0 : 1);

#!/usr/bin/env node
// The native sidebar's hover cards in the window shell's overlay (ARDIA_NATIVE_SIDEBAR=1, ARDIA_NATIVE_SHELL=1 and
// ARDIA_NATIVE_MEDIA=1 for the player): a
// card shows after RN's 500 ms intent and not before, RN draws none of its own, moving onto the card keeps it past the
// 160 ms hide delay, its buttons act, and it leaves on hover away, a click in the sidebar and a space switch (a tab
// switch keeps it, as in RN). A group's card lists the group's tabs, takes typing and switches to the match on Return. A live
// pull request's card opens the pull request from its comments line. A playing pinned tab's player card goes back to
// the tab from its artwork.
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
const titleOf = (id, i) => (i === 3 ? "Anker USB-C to USB-C Cable (240W, 6 ft), Nylon Braided" : `Tab ${id}`);
const tabs = ids.map((id, i) => ({ id, url: `data:text/html,<title>${titleOf(id, i)}</title>`, title: titleOf(id, i), lastActiveAt: Date.now() - i * 60_000 }));

const app = await launch(resolve(appArg), {
  data: join(scratch, "data"),
  env: { ARDIA_NATIVE_SIDEBAR: "1", ARDIA_NATIVE_SHELL: "1", ARDIA_NATIVE_MEDIA: "1" },
  probe: true,
  session: session({ profiles: ["Personal", "Work"], windows: [{ id: "w1", tabIds: ids, activeTabIds: { default: "t1" }, frame: [60, 60, 1200, 800] }], tabs }),
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
    if (Date.now() > end) throw new Error(`timed out waiting for ${what} (hover ${await hover()}, card ${JSON.stringify(await card())}, ${await run(`const h = ac.sidebarHover; return JSON.stringify({ rows: ["t3","t4","t5"].filter(h.pointerOnRow), onCard: h.pointerOnCard(), ui: ac.sidebarRows.useSidebarUi.getState() })`)})`);
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
    const r = await row("t3");
    const early = await run(`const H = globalThis.expo.modules.SolaraHosted; return ac.shell.devSetPointer("w1", { x: ${r.x + 60}, y: ${Math.round(r.y + r.height / 2)} }).then(() => { const t0 = Date.now(); return new Promise((done) => setTimeout(done, 300)).then(() => H.sidebarHoverCard("w1")).then((c) => ({ ms: Date.now() - t0, hover: ac.sidebarRows.useSidebarUi.getState().hover, phase: JSON.parse(c)?.phase ?? "hidden" })); })`);
    assert.ok(early.ms < 450, `sampled in time (${early.ms} ms)`);
    assert.equal(early.hover, null, "nothing at 300 ms");
    assert.equal(early.phase, "hidden", "no native card at 300 ms");
    const c = await shown("t3");
    rep.say(`shown at ${c.frame.map(Math.round)}`);
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
    const early = await run(`const H = globalThis.expo.modules.SolaraHosted; return ac.shell.devSetPointer("w1", { x: 900, y: 600 }).then(() => { const t0 = Date.now(); return new Promise((done) => setTimeout(done, 80)).then(() => H.sidebarHoverCard("w1")).then((c) => ({ ms: Date.now() - t0, phase: JSON.parse(c)?.phase })); })`);
    if (early.ms < 150) assert.equal(early.phase, "shown", `still shown inside the delay (${early.ms} ms)`);
    await gone("hover away");
  });

  await rep.check("a tab switch keeps it, as RN's does, and a space switch dismisses it", async () => {
    await onRow("t4");
    await shown("t4");
    await run(`ac.actions.switchToTab("t5"); return true`);
    await sleep(400);
    assert.equal((await card()).phase, "shown", "kept through the tab switch");
    await run(`ac.store.getState().switchProfile("w1", "work"); return true`);
    await gone("a space switch");
    await run(`ac.store.getState().switchProfile("w1", "default"); return true`);
    await sleep(600);
  });

  await rep.check("a click in the sidebar dismisses it", async () => {
    await point(900, 600);
    await gone("hover away");
    const r = await onRow("t6");
    await shown("t6");
    await run(`return ac.shell.devClick("w1", { x: ${r.x + 60}, y: ${Math.round(r.y + r.height / 2)} })`);
    await gone("a click");
  });

  await rep.check("a group's card lists its tabs natively, filters as you type and Return switches to the match", async () => {
    await point(900, 600);
    await gone("hover away");
    const g = await run(`const s = ac.store.getState(); const g = s.createGroup(["t2", "t3", "t4"], { name: "Group" }); ac.store.getState().updateGroup(g, { collapsed: true }); return g`);
    await sleep(600);
    const r = await row(g);
    assert.ok(r, "the group's row is measured");
    await point(r.x + 60, Math.round(r.y + r.height / 2));
    const c = await shown(g);
    assert.equal(c.kind, "group");
    assert.deepEqual([...c.rows].sort(), ["t2", "t3", "t4"]);
    assert.equal(await run(`return acPerf.findFibers("GroupPanel", 5).length`), 0, "RN draws no group panel");
    const [x, y, w] = c.frame;
    await point(x + w / 2, y + 20);
    await until("the search field to take the keys", async () => (await card())?.typingInCard);
    await run(`return ac.shell.devTypeKeys("w1", "Anker", 10)`);
    await until("one match", async () => Object.keys((await card())?.buttons ?? {}).length === 1);
    await run(`return ac.shell.devTypeKeys("w1", "\\r", 10)`);
    await until("t3 active", () => run(`const s = ac.store.getState(); return s.windows.w1.activeTabIds[s.windows.w1.profileId] === "t3"`));
    await gone("choosing a row");
  });

  await rep.check("a live pull request's card shows natively, and its comments line opens the pull request", async () => {
    await point(900, 600);
    await gone("hover away");
    const folder = await run(`
      const { store } = ac.live;
      const folder = store.createFolder("default", "pullRequests");
      const pr = { number: 7, repo: "ardia/app", author: "octocat", authorAvatar: null, draft: false, headRef: "h7", baseRef: "main", review: "approved",
        mergeable: "mergeable", checks: [{ name: "lint", state: "failure", url: "https://ci.example/lint" }], comments: 2, unresolvedThreads: 0, additions: 4, deletions: 1, changedFiles: 1 };
      store.applyFetch(folder, [{ id: "pr7", source: "github", url: "https://example.com/pr/7", title: "Pull request 7", subtitle: "", icon: null, updatedAt: Date.now(), section: "authored", pr }], {});
      store.setStatus(folder, { state: "idle", lastFetch: Date.now(), error: null });
      return folder;`);
    await sleep(800);
    const key = `live|${folder}|pr7`;
    const r = await row(key);
    assert.ok(r, "the live row is measured");
    await point(r.x + 60, Math.round(r.y + r.height / 2));
    const c = await shown(key);
    assert.equal(c.kind, "live");
    assert.equal(await run(`return acPerf.findFibers("LiveItemCard", 5).length`), 0, "RN draws no live card");
    const before = await run(`return ac.store.getState().windows.w1.tabIds.length`);
    const [x, y, w, h] = c.frame;
    await point(x + 40, y + h - 20);
    await sleep(200);
    await run(`return ac.shell.devClick("w1", { x: ${x + 40}, y: ${y + h - 20} })`);
    await until("the pull request to open", async () => (await run(`const s = ac.store.getState(); return s.windows.w1.tabIds.map((id) => s.tabs[id].url)`)).includes("https://example.com/pr/7"));
    await gone("opening the item");
    assert.ok((await run(`return ac.store.getState().windows.w1.tabIds.length`)) >= before);
  });

  await rep.check("a playing pinned tab's player card shows natively, and its artwork goes back to the tab", async () => {
    await point(900, 600);
    await gone("hover away");
    await run(`ac.store.getState().updateSettings({ sidebarMediaControls: true }); ac.store.getState().togglePin("t0");
      ac.media.setState((m) => ({ sessions: { ...m.sessions, t0: { title: "A Song", artist: "An Artist", album: "", artwork: null, playbackState: "playing", position: 30, duration: 200,
        playbackRate: 0, timestamp: Date.now(), hasVideo: false, actions: ["play", "pause"], controllable: true, playedAt: Date.now() } } })); return true`);
    await sleep(800);
    await onRow("t0");
    const c = await shown("t0");
    assert.equal(c.kind, "player");
    assert.deepEqual([c.frame[2], c.frame[3]], [320, 76]);
    assert.equal(await run(`return acPerf.findFibers("NativeHoverPlayer", 5).length + acPerf.findFibers("RNHoverPlayer", 5).length`), 0, "RN draws no player card");
    const [x, y, w, h] = c.buttons["Back to Tab"];
    await point(x + w / 2, y + h / 2);
    await sleep(200);
    await run(`return ac.shell.devClick("w1", { x: ${x + w / 2}, y: ${y + h / 2} })`);
    await until("t0 active", () => run(`const s = ac.store.getState(); return s.windows.w1.activeTabIds[s.windows.w1.profileId] === "t0"`));
    await gone("going back to the tab");
  });
} finally {
  await app.quit();
  if (!keep) rmSync(join(scratch, "data"), { recursive: true, force: true });
}
process.exit(rep.summary() ? 0 : 1);

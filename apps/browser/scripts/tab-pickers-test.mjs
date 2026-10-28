import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node tab-pickers-test.mjs <Debug Solara.app> [--keep-data]

Search Tabs (⇧⌘A) and the Ctrl-Tab switcher under the native shell, drawn by RN (ARDIA_NATIVE_SHELL=1) and then by
SolaraUI's TabSearchPanelView and TabSwitcherPanelView (plus ARDIA_NATIVE_TAB_PICKERS=1). Both runs get the same
keys through the window: the search panel sits where RN's does, typing and Enter pick the same tab, Down moves to the
next match, a click on a row picks the same tab as RN's, a closed tab's row restores it, Escape and a click outside close without switching, and native's
Escape gives focus back to what had it. The switcher shows
after its delay at RN's frame with the same rows, and a click on a row switches to it every time, once with an 80 ms
mouse-up and nine times with an instant one.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-tab-pickers-"));
const rep = reporter(join(scratch, "tab-pickers-test.log"), { name: "tab-pickers-test" });

const PAGES = { a: "Inbox Mail", b: "Docs Editor", c: "News Today", d: "Daily Notes", e: "Recipe Box" };
const server = createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/html" });
  res.end(`<!doctype html><title>${PAGES[req.url.slice(1)] ?? "?"}</title><link rel="icon" href="data:,"><body>${req.url.slice(1)}</body>`);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const url = (id) => `http://127.0.0.1:${server.address().port}/${id}`;
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: Object.entries(PAGES).map(([id, title]) => ({ id, url: url(id), title })),
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
});

const HELPERS = `
const C = globalThis.expo.modules.ArdiaCEF;
const H = globalThis.expo.modules.SolaraHosted;
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const ui = () => ac.sidebarRows.useSidebarUi.getState();
const active = () => ac.store.getState().windows.w1.activeTabIds.default;
const hostOf = (fiber) => { let f = fiber; while (f && !(f.stateNode && f.stateNode.measureInWindow)) f = f.child; return f && f.stateNode; };
const measure = (fiber) => new Promise((r) => { const n = hostOf(fiber); return n ? n.measureInWindow((x, y, w, h) => r([x, y, w, h])) : r(null); });
const surface = (match) => acPerf.findFibers("Surface", 400).find((f) => f.child && match(f.memoizedProps));
const rnSearch = () => { const f = surface((p) => p.cornerRadius === 16 && p.style && p.style.top === 56); return f ? measure(f) : Promise.resolve(null); };
const rnSwitcher = () => { const f = surface((p) => p.style && p.style.width === 400 && p.style.padding === 8); return f ? measure(f) : Promise.resolve(null); };
const native = () => H.tabPickers ? H.tabPickers("w1").then(JSON.parse) : Promise.resolve({});
const act = (n, a) => C.devWindow(n, a);
const key = (n, chars, code) => act(n, "keys:0:" + chars + (code === undefined ? "" : ":" + code));
const type = (n, text) => [...text].reduce((p, ch) => p.then(() => key(n, ch)).then(() => settle(40)), Promise.resolve());
const click = (n, p, gap) => act(n, "mouse:moved:" + p[0] + "," + p[1]).then(() => settle(60))
  .then(() => act(n, "mouse:down:" + p[0] + "," + p[1])).then(() => settle(gap)).then(() => act(n, "mouse:up:" + p[0] + "," + p[1]));
`;
const KEYS = { down: ["", 125], enter: ["\r", 36], escape: ["\u001b", 53] };
let app = null;
const run = (body, timeout = 20000) => app.eval(`${HELPERS}\n${body}`, { timeout });
const until = async (what, body, ms = 8000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await run(body).catch((e) => ({ error: String(e.message ?? e) }));
    if (last && !last.error) return last;
    await sleep(100);
  }
  throw new Error(`${what}: never true (last ${JSON.stringify(last)})`);
};
const near = (a, b, tol = 0.5) => a && b && a.length === b.length && a.every((v, i) => Math.abs(v - b[i]) <= tol);
const seen = { rn: {}, native: {} };

try {
  for (const nativePickers of [false, true]) {
    const tag = nativePickers ? "native" : "rn";
    const mine = seen[tag];
    app = await launch(resolve(appArg), {
      data: join(scratch, `data-${tag}`), fresh: true, session: fixture, onboarded: true, probe: true,
      env: { ARDIA_NATIVE_SHELL: "1", ARDIA_NATIVE_TAB_PICKERS: nativePickers ? "1" : "0" },
      ready: "return !!ac.store.getState().windows.w1 && !!ac.sidebarRows",
    });
    const number = await until("the window", `return C.chromeWindows().then((ws) => ws.find((w) => w.visible)?.window ?? null);`, 15000);
    const press = (name) => run(`return key(${number}, ${JSON.stringify(KEYS[name][0])}, ${KEYS[name][1]});`);
    for (const id of ["b", "c", "d", "e", "a"]) {
      await run(`ac.store.getState().activate(${JSON.stringify(id)}); return true;`);
      await sleep(250);
    }
    const openSearch = async () => {
      await run(`ac.runCommand({ command: "searchTabs", windowId: "w1" }); return true;`);
      return nativePickers
        ? until("the native search panel", `return native().then((d) => d.search && d.search.typing ? d.search : null);`, 4000)
        : until("RN's search panel", `return rnSearch();`, 4000).then((frame) => ({ frame }));
    };
    const searchClosed = () =>
      until("search closes", `return ui().searchTabs === null && (${nativePickers} ? native().then((d) => !d.search || null) : rnSearch().then((f) => !f || null));`, 3000);

    await rep.check(`${tag}-search-opens`, async () => {
      const panel = await openSearch();
      mine.searchFrame = panel.frame;
      if (nativePickers) {
        if (await run(`return rnSearch();`)) throw new Error("RN still draws the search panel");
        if (!near(panel.frame.slice(0, 3), seen.rn.searchFrame.slice(0, 3)) || !near(panel.frame.slice(3), seen.rn.searchFrame.slice(3))) throw new Error(`frame ${panel.frame}, RN ${seen.rn.searchFrame}`);
        if (panel.rows.filter((r) => r.startsWith("tab:")).length !== 5 || panel.selected !== 0 || panel.query !== "") throw new Error(JSON.stringify(panel));
      } else if ((await run(`return native();`)).search) throw new Error("native search panel in RN mode");
      await press("escape");
      await searchClosed();
      return panel.frame;
    });

    await rep.check(`${tag}-search-type-enter`, async () => {
      await openSearch();
      await run(`return type(${number}, "no").then(() => true);`);
      await sleep(300);
      if (nativePickers) {
        const d = await run(`return native();`);
        if (d.search.query !== "no") throw new Error(`query ${JSON.stringify(d.search.query)}`);
      }
      await press("enter");
      await searchClosed();
      mine.firstMatch = await run(`return active();`);
      if (nativePickers && mine.firstMatch !== seen.rn.firstMatch) throw new Error(`picked ${mine.firstMatch}, RN picked ${seen.rn.firstMatch}`);
      return mine.firstMatch;
    });

    await rep.check(`${tag}-search-down-enter`, async () => {
      await run(`ac.store.getState().activate("a"); return true;`);
      await sleep(200);
      await openSearch();
      await run(`return type(${number}, "no").then(() => true);`);
      await sleep(200);
      await press("down");
      await sleep(100);
      if (nativePickers) {
        const d = await run(`return native();`);
        if (d.search.selected !== 1) throw new Error(`selected ${d.search.selected}`);
      }
      await press("enter");
      await searchClosed();
      mine.secondMatch = await run(`return active();`);
      if (mine.secondMatch === mine.firstMatch) throw new Error(`Down didn't move off ${mine.firstMatch}`);
      if (nativePickers && mine.secondMatch !== seen.rn.secondMatch) throw new Error(`picked ${mine.secondMatch}, RN picked ${seen.rn.secondMatch}`);
      return mine.secondMatch;
    });

    await rep.check(`${tag}-search-row-click`, async () => {
      const panel = await openSearch();
      const [x, y, w] = panel.frame;
      await run(`return click(${number}, [${Math.round(x + w / 2)}, ${Math.round(y + 50 + 1 + 6 + 21.5 + 36 + 18)}], 60).then(() => true);`);
      await searchClosed();
      mine.clicked = await run(`return active();`);
      if (nativePickers && mine.clicked !== seen.rn.clicked) throw new Error(`clicked into ${mine.clicked}, RN into ${seen.rn.clicked}`);
      return mine.clicked;
    });

    await rep.check(`${tag}-search-escape`, async () => {
      const before = await run(`return active();`);
      const focused = nativePickers ? (await run(`return native();`)).responder : null;
      await openSearch();
      await run(`return type(${number}, "re").then(() => true);`);
      await press("escape");
      await searchClosed();
      if ((await run(`return active();`)) !== before) throw new Error("Escape switched tabs");
      if (nativePickers) {
        const after = (await run(`return native();`)).responder;
        if (after !== focused || after === "window") throw new Error(`focus went to ${after}, was on ${focused}`);
        return after;
      }
      return true;
    });

    await rep.check(`${tag}-search-click-away`, async () => {
      const before = await run(`return active();`);
      const panel = await openSearch();
      const [x, y, w, h] = panel.frame;
      await run(`return click(${number}, [${Math.round(x + w / 2)}, ${Math.round(y + h + 120)}], 60).then(() => true);`);
      await searchClosed();
      if ((await run(`return active();`)) !== before) throw new Error("the click switched tabs");
      return true;
    });

    await rep.check(`${tag}-search-restores-closed`, async () => {
      await run(`ac.store.getState().closeTab("e"); return true;`);
      await until("e closes", `return !ac.store.getState().tabs.e || null;`, 3000);
      const panel = await openSearch();
      if (nativePickers && !panel.rows.some((r) => r.startsWith("closed:"))) throw new Error(`no closed row in ${panel.rows}`);
      await run(`return type(${number}, "recipe").then(() => true);`);
      await sleep(200);
      if (nativePickers) {
        const d = await run(`return native();`);
        if (!d.search.rows[0] || !d.search.rows[0].startsWith("closed:")) throw new Error(`rows ${d.search.rows}`);
      }
      await press("enter");
      await searchClosed();
      return until("Recipe Box comes back", `const s = ac.store.getState(); const t = Object.values(s.tabs).find((t) => t.url.endsWith("/e")); return t && s.windows.w1.activeTabIds.default === t.id ? t.id : null;`, 5000);
    });

    for (const [round, gap] of [80, 0, 0, 0, 0, 0, 0, 0, 0, 0].entries()) {
      await rep.check(`${tag}-switcher-click-${round}-${gap}ms`, async () => {
        const early = await run(`ac.runCommand({ command: "tabSwitcher", windowId: "w1" }); return settle(60).then(() => !!(ui().switcher && ui().switcher.visible));`);
        if (early) throw new Error("visible before its delay");
        const s = await until("the switcher shows", `const s = ui().switcher; return s && s.visible ? s : null;`, 2000);
        const frame = nativePickers
          ? (await until("the native switcher", `return native().then((d) => d.switcher && d.switcher.ids.length ? d.switcher : null);`, 2000)).frame
          : await until("RN's switcher", `return rnSwitcher();`, 2000);
        if (nativePickers) {
          const d = await run(`return native();`);
          if (JSON.stringify(d.switcher.ids) !== JSON.stringify(s.ids) || d.switcher.index !== s.index) throw new Error(`native ${JSON.stringify(d.switcher)}, store ${JSON.stringify(s)}`);
          if (await run(`return rnSwitcher();`)) throw new Error("RN still draws the switcher");
          if (!near(frame, seen.rn.switcher.frame)) throw new Error(`frame ${frame}, RN ${seen.rn.switcher.frame}`);
        }
        const target = 2;
        const rowY = Math.round(frame[1] + frame[3] - 8 - s.ids.length * 40 + target * 40 + 20);
        await run(`return click(${number}, [${Math.round(frame[0] + frame[2] / 2)}, ${rowY}], ${gap}).then(() => true);`);
        await until("the switcher closes", `return !ui().switcher || null;`, 2000);
        await sleep(200);
        const now = await run(`return active();`);
        mine.switcher = { frame, ids: s.ids, picked: now };
        if (now !== s.ids[target]) throw new Error(`active ${now}, clicked ${s.ids[target]} in ${s.ids}`);
        return mine.switcher;
      });
    }

    await app.quit();
    app = null;
  }
} catch (e) {
  rep.record("run", { error: e });
} finally {
  await app?.quit().catch(() => {});
  server.close();
  if (!keep && rep.results.every((r) => r.ok)) rmSync(scratch, { recursive: true, force: true });
}
const failed = rep.results.filter((r) => !r.ok);
console.log(`${rep.results.length - failed.length}/${rep.results.length} passed${failed.length ? `; log ${rep.logFile}` : ""}`);
process.exit(failed.length ? 1 : 0);

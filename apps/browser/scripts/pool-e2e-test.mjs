import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg || resolve(appArg).startsWith("/Applications/")) {
  console.error(`usage: node pool-e2e-test.mjs <Debug Solara.app under apps/browser/build-*> [--keep-data]

The page pool end to end (docs/native/page-contract.md › Checks), in a hidden instance under the native shell with
pane roots and the pool on (ARDIA_NATIVE_SHELL=1 ARDIA_SHELL_PANES=1 ARDIA_NATIVE_PAGES_POOL=1): the pool serves the
window's pages and RN mounts no TabWebView; the tab's handle reaches the page (evaluate, find and its match count,
zoom in and back, load and go back); the page's events reach the store (title, favicon, load progress partway and
then done); a page's notification, clicked while another tab is active, brings its tab back
and fires the page's onclick; a peek opens on its own pooled page and Open as Tab promotes that page into the window;
and in a split, a click in the unfocused pane focuses it. A build whose pool doesn't serve pages fails every check.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-pool-e2e-"));
const rep = reporter(join(scratch, "pool-e2e-test.log"), { name: "pool-e2e-test" });

const ICON = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==", "base64");
const server = createServer((req, res) => {
  const path = req.url.split("?")[0].slice(1);
  if (path === "icon.png") {
    res.writeHead(200, { "content-type": "image/png" });
    return res.end(ICON);
  }
  if (path === "slow.png") return setTimeout(() => (res.writeHead(200, { "content-type": "image/png" }), res.end(ICON)), 2500);
  res.writeHead(200, { "content-type": "text/html" });
  const slow = path === "slow" ? `<img src="/slow.png?${Date.now()}">` : "";
  res.end(`<!doctype html><title>${path.toUpperCase()}</title><link rel="icon" href="/icon.png"><body style="height:2000px;font:16px sans-serif">
<p>a needle and another needle</p>${slow}</body>`);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const origin = `http://127.0.0.1:${server.address().port}`;
const url = (n) => `${origin}/${n}`;
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [{ id: "a", url: url("one"), title: "ONE" }, { id: "b", url: url("two"), title: "TWO" }],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
});

const HELPERS = `
const S = () => ac.store.getState();
const W = globalThis.expo.modules.SolaraWindowShell;
const page = (id) => ac.webviews.get(id);
const active = () => S().windows.w1.activeTabIds.default;
const ev = (id, expr) => page(id).evaluate("post('result', JSON.stringify(" + expr + "))");
`;
let app = null;
const run = (body, timeout = 20000) => app.eval(`${HELPERS}\n${body}`, { timeout });
const until = async (what, body, ms = 10000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await run(body).catch((e) => ({ error: String(e.message ?? e) }));
    if (last && !last.error) return last;
    await sleep(100);
  }
  throw new Error(`${what}: never true (last ${JSON.stringify(last)})`);
};
const json = JSON.stringify;

try {
  app = await launch(resolve(appArg), {
    data: join(scratch, "data"), fresh: true, session: fixture, onboarded: true, probe: true,
    env: { ARDIA_NATIVE_SHELL: "1", ARDIA_SHELL_PANES: "1", ARDIA_NATIVE_PAGES_POOL: "1", ARDIA_TAB_POOL: "1", ARDIA_NATIVE_MEDIA: "0" },
    ready: "return !!ac.store.getState().windows.w1 && !!globalThis.acPerf",
  });
  await until("page ONE", `return S().tabs.a.title === "ONE" || null;`, 15000);

  await rep.check("the pool serves the window's pages and RN mounts no TabWebView", async () => {
    const info = await run(`return W.devHitCost("w1", 600, 400).then((h) => ({ available: !!globalThis.expo.modules.SolaraTabPool?.available?.(), handle: !!page("a"), rn: acPerf.findFibers("TabWebView", 10).length, slot: h.slot }));`);
    if (!info.available) throw new Error("SolaraTabPool isn't available");
    if (!info.handle) throw new Error("no handle registered for tab a");
    if (info.rn) throw new Error(`${info.rn} TabWebView still mounted`);
    return info;
  });

  await rep.check("evaluate reaches the page", async () => {
    const title = await run(`return ev("a", "document.title");`);
    if (title !== "ONE") throw new Error(`document.title is ${json(title)}`);
    return title;
  });

  await rep.check("find reaches the page and its match count reaches the store", async () => {
    await run(`S().setFind("a", { open: true, count: null, active: 0 }); return page("a").find("needle", true, false).then(() => true);`);
    const find = await until("two matches", `const f = S().find.a; return f && f.count === 2 ? f : null;`);
    await run(`S().setFind("a", { open: false, count: null, active: 0 }); return page("a").stopFinding(true).then(() => true);`);
    return find;
  });

  await rep.check("zoom in reaches the page and its zoom reaches the store; reset brings it back", async () => {
    await run(`return page("a").zoomStep(1).then(() => true);`);
    const zoomed = await until("zoomed in", `const z = S().tabs.a.zoom; return z && z > 1 ? z : null;`);
    await run(`return page("a").zoomStep(0).then(() => true);`);
    const reset = await until("zoom reset", `const z = S().tabs.a.zoom; return !z || z === 1 ? { z: z ?? 1 } : null;`);
    return { zoomed, reset: reset.z };
  });

  await rep.check("loadUrl and goBack reach the page; title and url come back through the store", async () => {
    await run(`return page("a").loadUrl(${json(url("three"))}).then(() => true);`);
    await until("THREE", `return S().tabs.a.title === "THREE" && S().live.a?.canGoBack ? true : null;`);
    await run(`return page("a").goBack().then(() => true);`);
    return until("back to ONE", `const t = S().tabs.a; return t.title === "ONE" && t.url === ${json(url("one"))} ? t.url : null;`);
  });

  await rep.check("the favicon event reaches the store", async () =>
    until("favicon", `const t = S().tabs.a; return t.favicon ? String(t.favicon).slice(0, 60) : null;`));

  await rep.check("load progress reaches the store, partway and then done", async () => {
    await run(`globalThis.__poolProgress = []; globalThis.__poolProgressStop = ac.pageProgress.watchPageProgress("a", () => __poolProgress.push(ac.pageProgress.pageProgressOf("a"))); return page("a").loadUrl(${json(url("slow"))}).then(() => true);`);
    await until("load finished", `return S().tabs.a.title === "SLOW" && !S().live.a?.isLoading ? true : null;`, 10000);
    await sleep(300);
    const seen = await run(`__poolProgressStop(); return __poolProgress;`);
    if (!seen.some((p) => p > 0 && p < 1)) throw new Error(`no partial progress: ${json(seen)}`);
    if (![0, 1].includes(seen.at(-1))) throw new Error(`progress ended at ${seen.at(-1)}: ${json(seen)}`);
    return seen.slice(0, 12);
  });

  await rep.check("a notification click brings its tab back and reaches the page", async () => {
    await run(`return globalThis.expo.modules.ArdiaCEF.setSiteSetting("", ${json(origin)}, "notifications", "allow").then(() => true);`);
    await run(`return ev("a", "(() => { const n = new Notification('Ping', { body: 'pool', tag: 'pool' }); n.onclick = () => { document.title = 'CLICKED'; }; return true; })()");`);
    const shown = await until("the notification reaches the app", `const n = acWebNotifications.received().find((n) => n.title === "Ping"); return n ? { id: n.id, tag: n.tag, origin: n.origin } : null;`);
    await run(`S().activate("b"); return true;`);
    await until("b active", `return active() === "b" || null;`);
    const macId = shown.tag ? `web:${shown.origin}#${shown.tag}` : `web:${shown.id}`;
    await run(`return ac.webNotifications.handleWebNotificationResponse({ id: ${json(macId)}, action: "click", tabId: "a", data: { engineId: ${json(shown.id)} } });`);
    await until("a active again", `return active() === "a" || null;`);
    await until("the page's onclick ran", `return ev("a", "document.title").then((t) => t === "CLICKED" || null);`);
    return shown;
  });

  await rep.check("a peek opens on its own pooled page and Open as Tab promotes it into the window", async () => {
    const peekId = await run(`return S().openPeek("a", ${json(url("peeked"))});`);
    await until("the peek's page loads", `const p = S().peeks.w1; return p && p.tabId === ${json(peekId)} && S().tabs[p.tabId]?.title === "PEEKED" ? true : null;`);
    const inPeek = await run(`return ev(${json(peekId)}, "document.title");`);
    if (inPeek !== "PEEKED") throw new Error(`the peek's handle reads ${json(inPeek)}`);
    await run(`ac.peek.openPeekAsTab("w1"); return true;`);
    await until("promoted", `return !S().peeks.w1 && S().windows.w1.tabIds.includes(${json(peekId)}) && active() === ${json(peekId)} ? true : null;`, 5000);
    const after = await until("the promoted page still answers", `return ev(${json(peekId)}, "document.title").then((t) => t === "PEEKED" ? t : null);`);
    await run(`S().activate("a"); return true;`);
    return { peekId, after };
  });

  await rep.check("a click in the unfocused split pane focuses it", async () => {
    await run(`S().createSplit(["a", "b"]); S().activate("a"); return true;`);
    const panes = await until("two panes placed", `return W.describe("w1").then(JSON.parse).then((d) => d.split && d.split.panes && d.split.panes.a && d.split.panes.b ? { card: d.card, panes: d.split.panes } : null);`);
    await sleep(500);
    const [cx, cy] = panes.card;
    const [bx, by, bw, bh] = panes.panes.b;
    const x = Math.round(cx + bx + bw / 2), y = Math.round(cy + by + bh * 0.6);
    const click = await run(`return ac.shell.devClick("w1", { x: ${x}, y: ${y}, wait: 250 });`);
    if (!/RenderWidgetHostViewCocoa|WebContentsViewCocoa/.test(String(click.hit))) throw new Error(`the click at ${x},${y} landed on ${click.hit}`);
    await until("b focused", `return active() === "b" || null;`, 3000);
    return { at: [x, y], hit: click.hit };
  });
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

import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node main-top-test.mjs <Debug Solara.app> [--keep-data]

The window's RN main root on top of the native shell's layers (ARDIA_SHELL_MAIN_TOP=1, with ARDIA_NATIVE_SHELL=1,
ARDIA_SHELL_PANES=1 and ARDIA_NATIVE_PAGES_POOL=1), once with the native sidebar (ARDIA_NATIVE_SIDEBAR=1) and once
with RN's: the root is stacked under the overlay and above every other slot;
no React Native view that draws nothing and handles nothing catches the pointer over the card, the sidebar or the top
strip (devReactBlockers hit-tests a grid over them and names each RN view there with no background or content; the
ones with their own mouse enter or leave handler, or a press, click, responder or drop handler on themselves or a
parent no more than twice their area, are controls and pass, and the report names the parent and prop that made each one); a click on the page
lands on the page, outside the main root, and focuses it; and file, URL and text drops there go to the web contents.
The gate for the pool wired into the app: until the pool takes the pages out of the main root, the page is under the
main root and the click check fails on that.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-main-top-"));
const rep = reporter(join(scratch, "main-top-test.log"), { name: "main-top-test" });
const WEB = /RenderWidgetHostViewCocoa|WebContentsViewCocoa|ArdiaCoreWebView/;
const TYPES = ["public.file-url", "public.url", "public.utf8-plain-text"];

const server = createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/html" });
  res.end(`<!doctype html><title>${req.url.slice(1).toUpperCase()}</title><link rel="icon" href="data:,"><body style="height:2000px">${req.url.slice(1)}</body>`);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const url = (n) => `http://127.0.0.1:${server.address().port}/${n}`;
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [{ id: "a", url: url("one"), title: "ONE" }, { id: "b", url: url("two"), title: "TWO" }],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
});

const HELPERS = `
const S = () => ac.store.getState();
const W = globalThis.expo.modules.SolaraWindowShell;
const describe = () => W.describe("w1").then(JSON.parse);
`;
const PRESS_PROPS = ["onPress", "onPressIn", "onClick", "onMouseDown", "onStartShouldSetResponder", "onResponderGrant", "draggedTypes", "onDrop", "onDragEnter"];
const OWN_PROPS = ["onMouseEnter", "onMouseLeave"];
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

async function pass(label, env) {
  app = await launch(resolve(appArg), {
    data: join(scratch, `data-${label}`), fresh: true, session: fixture, onboarded: true, probe: true,
    env: { ARDIA_NATIVE_SHELL: "1", ARDIA_NATIVE_PAGES_POOL: "1", ARDIA_SHELL_PANES: "1", ARDIA_SHELL_MAIN_TOP: "1", ...env },
    ready: "return !!ac.store.getState().windows.w1 && !!globalThis.expo.modules.SolaraWindowShell && !!globalThis.acPerf",
  });
  await until("page ONE", `return S().tabs.a.title === "ONE" || null;`, 15000);
  await sleep(1500);
  const shell = await run(`return describe();`);

  await rep.check(`${label}: the-main-root-is-under-the-overlay-and-above-the-rest`, async () => {
    const order = shell.order;
    if (!shell.reactOnTop) throw new Error(`the flag didn't take: ${JSON.stringify(shell)}`);
    if (order.at(-1) !== "SolaraUI.ShellOverlayView" || order.at(-2) !== "RCTRootView") throw new Error(`order ${order.join(" < ")}`);
    return order.join(" < ");
  });

  await rep.check(`${label}: no-rn-view-that-draws-and-handles-nothing-catches-the-pointer`, async () => {
    const found = await run(`return W.devReactBlockers("w1", 24).then(JSON.parse).then((views) => views.map((v) => {
      const press = ${JSON.stringify(PRESS_PROPS)};
      const host = typeof v.reactTag === "number" ? acPerf.hostFiber(v.reactTag) : null;
      const own = (host && host.memoizedProps) || {};
      const ownerOf = (fiber) => { for (let c = fiber && fiber.return; c; c = c.return) { const n = typeof c.type === "string" ? null : acPerf.nameOf(c.type); if (n && n !== "View" && n !== "Animated(View)") return n; } return null; };
      let by = null;
      const ownProp = ${JSON.stringify(OWN_PROPS)}.concat(press).find((k) => own[k] != null);
      if (ownProp) by = { prop: ownProp, depth: 0, tag: v.reactTag, owner: ownerOf(host) };
      const area = v.frame[2] * v.frame[3];
      let stoppedAt = null;
      for (let i = 0; !by && i < (v.ancestors || []).length; i++) {
        const [tag, w, h] = v.ancestors[i];
        if (w * h > 2 * area) { stoppedAt = { tag, depth: i + 1, size: [w, h] }; break; }
        const fiber = acPerf.hostFiber(tag);
        const props = (fiber && fiber.memoizedProps) || {};
        const prop = press.find((k) => props[k] != null);
        if (prop) by = { prop, depth: i + 1, tag, owner: ownerOf(fiber) };
      }
      return { ...v, ancestors: undefined, owner: ownerOf(host), control: !!by, by, stoppedAt, resolved: !!host };
    }));`);
    const blockers = found.filter((v) => !v.control);
    if (blockers.length) throw new Error(`${blockers.length} RN views draw and handle nothing but catch the pointer: ${JSON.stringify(blockers.slice(0, 8))}`);
    return { controls: found.map((v) => ({ owner: v.owner, by: v.by })) };
  });

  await rep.check(`${label}: a-click-on-the-page-lands-outside-the-main-root-and-focuses-it`, async () => {
    const [x, y] = shell.card;
    const slot = await run(`return W.devHitCost("w1", ${x + 200}, ${y + 300}).then((r) => r.slot);`);
    const r = await run(`return ac.shell.devClick("w1", { in: "page", x: 200, y: 300, wait: 250 });`);
    if (!WEB.test(String(r.hit))) throw new Error(`the click landed on ${r.hit}`);
    if (!WEB.test(String(r.firstResponderAfter))) throw new Error(`first responder after the click: ${r.firstResponderAfter}`);
    if (slot === "react") throw new Error(`the page is still under the main root (the pool hasn't taken it): ${r.hit} in the react slot`);
    return { ...r, slot };
  });

  await rep.check(`${label}: drops-on-the-page-reach-the-web-contents`, async () => {
    const win = await run(`return globalThis.expo.modules.ArdiaCEF.chromeWindows().then((ws) => ws.find((w) => w.hasRoot).window);`);
    const [x, y, w, h] = shell.card;
    const at = [Math.round(x + w / 2), Math.round(y + h * 0.6)];
    const seen = {};
    for (const type of TYPES) {
      const hit = JSON.parse(await run(`return globalThis.expo.modules.SolaraPages.devDropTarget(${win}, ${at[0]}, ${at[1]}, ${JSON.stringify(type)});`));
      if (!WEB.test(String(hit.view))) throw new Error(`${type} at ${at} taken by ${hit.chain?.join(" < ") ?? hit.view}`);
      seen[type] = hit.view;
    }
    return seen;
  });
  await app.quit().catch(() => {});
  app = null;
}

try {
  await pass("native-sidebar", { ARDIA_NATIVE_SIDEBAR: "1" });
  await pass("rn-sidebar", { ARDIA_NATIVE_SIDEBAR: "0" });
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

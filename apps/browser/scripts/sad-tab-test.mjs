import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node sad-tab-test.mjs <Debug Solara.app> [--keep-data]

The sad tab over a local page, drawn by RN and then natively (ARDIA_NATIVE_SHELL=1, where SadTabView sits in a
container on top of the shell's card, framed to the pane): a crashed tab covers the pane with "This tab needs to
reload" and a Reload button, an unresponsive one dims it under a 320 wide card with Exit Page and Wait. The native
overlay, its buttons and RN's are the same frames in the window (within half a point: one pixel of Yoga rounding), a click on Reload clears the
crash and a click on Wait clears the hang, and once both are gone the native container leaves the card.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-sad-tab-"));
const rep = reporter(join(scratch, "sad-tab-test.log"), { name: "sad-tab-test" });

const server = createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/html" });
  res.end(`<!doctype html><title>A</title><link rel="icon" href="data:,"><body>a</body>`);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const pageUrl = `http://127.0.0.1:${server.address().port}/a`;
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [{ id: "a", url: pageUrl, title: "A" }],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
});

const HELPERS = `
const C = globalThis.expo.modules.ArdiaCEF;
const M = globalThis.expo.modules.SolaraMedia;
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const page = () => ac.pageState.getState().pages.a || {};
const patch = (p) => ac.pageState.setState((s) => ({ pages: { ...s.pages, a: { ...(s.pages.a || {}), ...p } } }));
const fibers = (name) => acPerf.findFibers(name, 500).filter((f) => !!f.child);
const hostOf = (fiber) => { let f = fiber; while (f && !(f.stateNode && f.stateNode.measureInWindow)) f = f.child; return f && f.stateNode; };
const measure = (fiber) => new Promise((r) => { const n = hostOf(fiber); return n ? n.measureInWindow((x, y, w, h) => r([x, y, w, h])) : r(null); });
const button = (title) => { const f = fibers("PromptButton").find((b) => b.memoizedProps.title === title); return f ? measure(f) : Promise.resolve(null); };
const act = (n, a) => C.devWindow(n, a);
const click = (n, p) => act(n, "mouse:moved:" + p[0] + "," + p[1]).then(() => settle(60))
  .then(() => act(n, "mouse:down:" + p[0] + "," + p[1])).then(() => settle(60)).then(() => act(n, "mouse:up:" + p[0] + "," + p[1]));
const native = () => M && M.describePaneOverlays ? M.describePaneOverlays("w1").then(JSON.parse) : Promise.resolve(null);
`;
let app = null;
const run = (body, timeout = 20000) => app.eval(`${HELPERS}\n${body}`, { timeout });
const until = async (what, body, ms = 8000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await run(body).catch((e) => ({ error: String(e.message ?? e) }));
    if (last && !last.error) return last;
    await sleep(150);
  }
  throw new Error(`${what}: never true (last ${JSON.stringify(last)})`);
};
const near = (a, b) => a && b && a.length === b.length && a.every((v, i) => Math.abs(v - b[i]) <= 0.5);
const centre = (f) => [Math.round(f[0] + f[2] / 2), Math.round(f[1] + f[3] / 2)];

const modes = [
  { crashed: { url: pageUrl, reason: "test" } },
  { unresponsive: true },
];
const labels = { 0: ["Reload"], 1: ["Exit Page", "Wait"] };
const measured = { rn: [], native: [] };

async function frames(nativeShell, i) {
  if (!nativeShell) {
    const overlay = await until("RN's sad tab", `const [f] = fibers("SadTab"); return f ? measure(f) : null;`);
    const controls = {};
    for (const title of labels[i]) controls[title] = await until(`RN's ${title}`, `return button(${JSON.stringify(title)});`);
    return { overlay, controls };
  }
  const info = await until("the native sad tab", `return native().then((d) => d && d.tabs.a && d.tabs.a.sadTab && !d.tabs.a.sadTab.hidden ? d : null);`);
  if (!info.top || !info.inCard) throw new Error(`the overlay container is not the card's top child: ${JSON.stringify(info)}`);
  const drawn = await run(`return fibers("PromptButton").length + fibers("Symbol").filter((f) => f.memoizedProps.name === "exclamationmark.triangle").length;`);
  if (drawn) throw new Error("RN still draws the sad tab's icon or buttons with the native one on");
  return { overlay: info.tabs.a.sadTab.frame, controls: info.tabs.a.sadTab.controls, mode: info.tabs.a.sadTab.mode };
}

try {
  for (const nativeShell of [false, true]) {
    const tag = nativeShell ? "native" : "rn";
    app = await launch(resolve(appArg), {
      data: join(scratch, `data-${tag}`), fresh: true, session: fixture, onboarded: true, probe: true,
      env: { ARDIA_NATIVE_SHELL: nativeShell ? "1" : "0" },
      ready: "return !!ac.store.getState().windows.w1",
    });
    const number = await until("the window", `return C.chromeWindows().then((ws) => ws.find((w) => w.visible)?.window ?? null);`, 15000);
    await until("page A", `return ac.store.getState().tabs.a?.title === "A" || null;`, 15000);

    for (const [i, state] of modes.entries()) {
      const name = i === 0 ? "crashed" : "unresponsive";
      await rep.check(`${tag}-${name}`, async () => {
        await run(`patch(${JSON.stringify(state)}); return true;`);
        await sleep(400);
        const got = await frames(nativeShell, i);
        if (nativeShell && got.mode !== name) throw new Error(`native mode ${got.mode}`);
        measured[tag][i] = got;
        const action = i === 0 ? "Reload" : "Wait";
        await run(`return click(${number}, ${JSON.stringify(centre(got.controls[action]))}).then(() => true);`);
        await until(`${action} clears it`, `const p = page(); return !p.crashed && !p.unresponsive || null;`, 3000);
        if (nativeShell) await until("the native overlay goes", `return native().then((d) => !d || (!d.tabs.a && !d.inCard) || null);`, 3000);
        return got;
      });
    }
    await app.quit();
    app = null;
  }

  for (const [i] of modes.entries()) {
    await rep.check(`native-matches-rn-${i === 0 ? "crashed" : "unresponsive"}`, async () => {
      const rn = measured.rn[i];
      const nat = measured.native[i];
      if (!rn || !nat) throw new Error("a mode was not measured");
      if (!near(nat.overlay, rn.overlay)) throw new Error(`overlay ${nat.overlay}, RN ${rn.overlay}`);
      for (const title of labels[i]) if (!near(nat.controls[title], rn.controls[title])) throw new Error(`${title} ${nat.controls[title]}, RN ${rn.controls[title]}`);
      return { overlay: rn.overlay, controls: rn.controls };
    });
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

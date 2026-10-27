import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node little-solara-test.mjs <Debug Solara.app> [--native] [--keep-data]

Little Solara on a local page: the window opens with its bar and card where SmallChrome puts them (field at 84, 5,
28 high, the buttons at the right, the card inset 6 below a 38 pt bar), a click on the field opens the command panel,
the panel grows from the field box to RN's dropdown frame (left and top of the field, max(350, field + 137) wide, 12
from the window's right edge at most) with its field taking a click inside the 38 pt bar and a click on the card closing it,
a click on the bar's blank part leaves the window alone, and Open in Solara (its button natively, ⌘O's command under RN) moves the tab to the main window and closes the small one;
then a relaunch handed a link, as another app hands it (ARDIA_ACCEPT_EXTERNAL_URLS=1, since a hidden instance otherwise
passes outside links on to another copy), opens it in Little Solara and not the main window. --native runs with ARDIA_NATIVE_MEDIA=1, where the window is the native Little Solara shell:
its backdrop, bar and RN slots in that order and the bar fed from JS.`);
  process.exit(2);
}
const native = args.includes("--native");
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-little-solara-"));
const data = join(scratch, "data");
const rep = reporter(join(scratch, "little-solara-test.log"), { name: `little-solara-test${native ? " --native" : ""}` });

const server = createServer((req, res) => {
  const name = req.url.slice(1) || "root";
  res.writeHead(200, { "content-type": "text/html" });
  res.end(`<!doctype html><title>${name.toUpperCase()}</title><link rel="icon" href="data:,"><body>${name}</body>`);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const url = (name) => `http://127.0.0.1:${server.address().port}/${name}`;
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [{ id: "a", url: url("a"), title: "A" }],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false, searchSuggestions: false },
});

const HELPERS = `
const C = globalThis.expo.modules.ArdiaCEF;
const M = globalThis.expo.modules.SolaraMedia;
const st = () => ac.store.getState();
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const small = () => Object.values(st().windows).find((w) => w.kind === "small") || null;
const win = (n) => C.chromeWindows().then((ws) => ws.find((w) => w.window === n));
const act = (n, a) => C.devWindow(n, a);
const fibers = (name) => acPerf.findFibers(name, 500).filter((f) => !!f.child);
const hostOf = (fiber) => { let f = fiber; while (f && !(f.stateNode && f.stateNode.measureInWindow)) f = f.child; return f && f.stateNode; };
const measure = (fiber) => new Promise((r) => { const n = hostOf(fiber); return n ? n.measureInWindow((x, y, w, h) => r([x, y, w, h])) : r(null); });
const centre = (f) => [Math.round(f[0] + f[2] / 2), Math.round(f[1] + f[3] / 2)];
const click = (id, n, p) => ac.shell.devSetPointer(id, { x: p[0], y: p[1] }).then(() => act(n, "mouse:moved:" + p[0] + "," + p[1])).then(() => settle(60))
  .then(() => act(n, "mouse:down:" + p[0] + "," + p[1])).then(() => settle(60)).then(() => act(n, "mouse:up:" + p[0] + "," + p[1]));
const bar = (id) => M ? M.probe("littleSolara.bar", id).then(JSON.parse).then((rows) => rows[0] || null) : Promise.resolve(null);
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
const centre = (f) => [Math.round(f[0] + f[2] / 2), Math.round(f[1] + f[3] / 2)];
const bar = (id) => run(`return bar(${JSON.stringify(id)});`);
const near = (a, b) => a && b && a.length === b.length && a.every((v, i) => Math.abs(v - b[i]) <= 0.5);

let little = null;
try {
  app = await launch(resolve(appArg), {
    data, fresh: true, session: fixture, onboarded: true, probe: true,
    env: native ? { ARDIA_NATIVE_MEDIA: "1" } : {},
    ready: "return !!ac.store.getState().windows.w1",
  });

  await rep.check("opens", async () => {
    const before = await run(`return C.chromeWindows().then((ws) => ws.map((w) => w.window));`);
    await run(`ac.runCommand({ command: "newLittleArdia" }); return true;`);
    const id = await until("a Little Solara window", `return small()?.id ?? null;`);
    const tab = await until("its tab", `return st().windows[${JSON.stringify(id)}]?.tabIds[0] ?? null;`);
    await run(`st().navigate(${JSON.stringify(tab)}, ${JSON.stringify(url("b"))}, { userInitiated: true }); return true;`);
    await until("page B", `return st().tabs[${JSON.stringify(tab)}]?.title === "B" && !st().windowUi[${JSON.stringify(id)}]?.panel.open ? true : (st().windowUi[${JSON.stringify(id)}]?.panel.open && st().closePanel(${JSON.stringify(id)}), null);`, 15000);
    const number = await until("its window", `return C.chromeWindows().then((ws) => ws.find((w) => !${JSON.stringify(before)}.includes(w.window) && w.visible)?.window ?? null);`);
    const frame = await run(`return win(${number}).then((w) => w.frame);`);
    const [, , w, h] = frame.match(/[-\d.]+/g).map(Number);
    little = { id, tab, number, width: w, height: h };
    return little;
  });

  await rep.check("shell", async () => {
    const active = await run(`return !!M && !!M.littleActive && M.littleActive(${JSON.stringify(little.id)});`);
    if (active !== native) throw new Error(`littleActive ${active} with the switch ${native ? "on" : "off"}`);
    if (!native) return { active };
    const info = await until("the shell's bar", `return M.describeLittle(${JSON.stringify(little.id)}).then(JSON.parse).then((d) => d && d.barShown && d.backdrop ? d : null);`);
    const slots = info.slots.map(([slot]) => slot).join(",");
    if (slots !== "backdrop,bar,react") throw new Error(`slots ${slots}`);
    const [, , w, h] = info.bounds;
    if (!near(info.card, [6, 38, w - 12, h - 44])) throw new Error(`card ${info.card} in ${info.bounds}`);
    if (!near(info.bar, [0, 0, w, 38])) throw new Error(`bar ${info.bar}`);
    if (info.blankBarHit !== "SolaraUI.LittleSolaraDragStrip") throw new Error(`a click on the bar's blank part reaches ${info.blankBarHit}, not the drag strip`);
    if (info.reactFill !== null) throw new Error(`the RN root keeps its fill over the backdrop and bar: ${info.reactFill}`);
    const bars = await run(`return [fibers("ShellLittleArdiaBar").length, fibers("NativeLittleArdiaBar").length, fibers("RNLittleArdiaBar").length];`);
    if (bars.join() !== "1,0,0") throw new Error(`JS bars (shell, hosted, RN) ${bars}`);
    return { slots, card: info.card, bounds: info.bounds, blankBarHit: info.blankBarHit };
  });

  const fieldRect = async () => {
    if (native) return (await until("native bar frames", `return bar(${JSON.stringify(little.id)}).then((r) => r && r.frames.field ? r.frames : null);`)).field;
    return until("RN field", `const [f] = fibers("PageField"); return f ? measure(f) : null;`);
  };

  await rep.check("bar-layout", async () => {
    const field = await fieldRect();
    const want = [84, 5, little.width - 84 - (6 + 2 * 28 + 2 + 6), 28];
    if (!near(field, want)) throw new Error(`field ${field}, SmallChrome puts it at ${want}`);
    if (native) {
      const frames = (await bar(little.id)).frames;
      if (!near(frames.open, [little.width - 6 - 28, 5, 28, 28]) || !near(frames.copy, [little.width - 6 - 58, 5, 28, 28])) throw new Error(`buttons ${JSON.stringify(frames)}`);
    }
    return { field };
  });

  await rep.check("field-opens-panel", async () => {
    const field = await fieldRect();
    await run(`return click(${JSON.stringify(little.id)}, ${little.number}, ${JSON.stringify(centre(field))}).then(() => true);`);
    await until("command panel open", `return st().windowUi[${JSON.stringify(little.id)}]?.panel.open || null;`, 3000);
    await run(`st().closePanel(${JSON.stringify(little.id)}); return true;`);
    await until("command panel closed", `return !st().windowUi[${JSON.stringify(little.id)}]?.panel.open || null;`, 3000);
    return true;
  });

  await rep.check("panel-frame-and-hits", async () => {
    const field = await fieldRect();
    const id = JSON.stringify(little.id);
    await run(`st().openPanel(${id}, st().tabs[${JSON.stringify(little.tab)}].url); return true;`);
    const grow = await until("the panel's Grow", `const [g] = acPerf.findFibers("Grow", 5); return g ? { from: g.memoizedProps.from, frame: g.memoizedProps.frame, radius: g.memoizedProps.radius } : null;`, 3000);
    const width = Math.min(Math.max(350, field[2] + 137), little.width - field[0] - 12);
    const from = grow.from && [grow.from.left, grow.from.top, grow.from.width, grow.from.height];
    if (!near(from, field)) throw new Error(`grows from ${from}, the field is at ${field}`);
    if (!near([grow.frame.left, grow.frame.top, grow.frame.width], [field[0], field[1], width]) || grow.radius !== 12) throw new Error(`panel ${JSON.stringify(grow)}, RN's dropdown is ${[field[0], field[1], width]} radius 12`);
    await run(`return click(${id}, ${little.number}, [${Math.round(field[0] + width / 2)}, 19]).then(() => settle(300)).then(() => true);`);
    if (!(await run(`return !!st().windowUi[${id}]?.panel.open;`))) throw new Error("a click on the panel's field inside the bar closed the panel");
    await run(`return click(${id}, ${little.number}, [${Math.round(little.width / 2)}, ${Math.round(little.height - 40)}]).then(() => settle(300)).then(() => true);`);
    if (await run(`return !!st().windowUi[${id}]?.panel.open;`)) throw new Error("a click on the card left the panel open");
    return { from, frame: grow.frame, radius: grow.radius };
  });

  await rep.check("blank-bar-click", async () => {
    await run(`return click(${JSON.stringify(little.id)}, ${little.number}, [60, 19]).then(() => settle(300)).then(() => true);`);
    const state = await run(`return { open: !!st().windowUi[${JSON.stringify(little.id)}]?.panel.open, alive: !!st().windows[${JSON.stringify(little.id)}] };`);
    if (state.open || !state.alive) throw new Error(JSON.stringify(state));
    return state;
  });

  await rep.check("open-in-main", async () => {
    if (native) {
      const frames = (await bar(little.id)).frames;
      await run(`return click(${JSON.stringify(little.id)}, ${little.number}, ${JSON.stringify(centre(frames.open))}).then(() => true);`);
    } else {
      await run(`ac.runCommand({ command: "openFile", windowId: ${JSON.stringify(little.id)} }); return true;`);
    }
    await until("the small window closes", `return !st().windows[${JSON.stringify(little.id)}] || null;`, 5000);
    const moved = await until("the tab in the main window", `return st().windows.w1.tabIds.includes(${JSON.stringify(little.tab)}) || null;`, 5000);
    return { moved };
  });


  await rep.check("link-from-another-app", async () => {
    await sleep(1500);
    await app.quit();
    app = null;
    app = await launch(resolve(appArg), {
      data, probe: true, urls: [url("c")],
      env: { ARDIA_ACCEPT_EXTERNAL_URLS: "1", ...(native ? { ARDIA_NATIVE_MEDIA: "1" } : {}) },
      ready: "return !!ac.store.getState().windows.w1",
    });
    const id = await until("Little Solara for the link", `return small()?.id ?? null;`, 15000);
    const tab = await until("page C in it", `const t = st().tabs[st().windows[${JSON.stringify(id)}]?.tabIds[0]]; return t && t.title === "C" ? t.id : null;`, 15000);
    const main = await run(`return st().windows.w1.tabIds.map((t) => st().tabs[t].url);`);
    if (main.includes(url("c"))) throw new Error(`the link opened in the main window too: ${main}`);
    const active = await run(`return !!M && !!M.littleActive && M.littleActive(${JSON.stringify(id)});`);
    if (active !== native) throw new Error(`littleActive ${active} with the switch ${native ? "on" : "off"}`);
    const shell = native ? await until("the shell's bar", `return M.describeLittle(${JSON.stringify(id)}).then(JSON.parse).then((d) => d && d.barShown && d.blankBarHit === "SolaraUI.LittleSolaraDragStrip" ? d : null);`) : null;
    return { id, tab, slots: shell?.slots.map(([slot]) => slot) };
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

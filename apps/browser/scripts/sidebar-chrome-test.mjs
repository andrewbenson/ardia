import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node sidebar-chrome-test.mjs <Debug Solara.app> [--keep-data]

The native sidebar column's own chrome, with the window shell, native sidebar, top strip and profile pager switches on:
the blank header drags the window and a double-click there does what the titlebar's does; the sidebar address bar sits
in the header's slot, survives toggling it out and back and a reload, and opens its dropdown; the header's and the
footer's downloads buttons open the downloads list; the resize handle drags the width live, keeps it on release and
resets it on a double-click; the footer's profile dots switch profiles; a drop on the header or the footer opens a tab,
and a tab dragged over the window lights the native drop glow; with top tabs the column and its chrome go away. A click
on a profile dot after every check makes sure the check left clicks working.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-sidebar-chrome-"));
const rep = reporter(join(scratch, "sidebar-chrome-test.log"), { name: "sidebar-chrome-test" });
const fixture = session({
  profiles: [{ id: "default", name: "Personal" }, { id: "work", name: "Work" }],
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [{ id: "a", url: "about:blank", title: "A" }, { id: "b", url: "about:blank", title: "B" }, { id: "c", url: "about:blank", title: "C" }],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false, addressBar: "sidebar" },
});
const HELPERS = `
const C = globalThis.expo.modules.ArdiaCEF;
const H = globalThis.expo.modules.SolaraHosted;
const st = () => ac.store.getState();
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const win = () => C.chromeWindows().then((ws) => ws.find((w) => w.hasRoot).window);
const act = (a) => win().then((n) => C.devWindow(n, a));
const frame = () => win().then((n) => C.chromeWindows().then((ws) => ws.find((w) => w.window === n).frame));
const col = () => H.sidebarShell("w1").then((d) => JSON.parse(d));
const click = (x, y, n = 1) => act("mouse:down:" + x + "," + y + "," + n).then(() => settle(30)).then(() => act("mouse:up:" + x + "," + y + "," + n)).then(() => settle(60));
`;
const centre = (c, r) => [Math.round(c.frame[0] + r[0] + r[2] / 2), Math.round(c.frame[1] + r[1] + r[3] / 2)];
let inst = null;
const run = (body) => inst.eval(`${HELPERS}\n${body}`, { timeout: 30000 });

const canary = async (after) => {
  const r = await run(`return col().then((c) => { const d = c.chrome.dots.find((d) => d.id === "work"); const x = Math.round(d.rect[0] + d.rect[2] / 2), y = Math.round(d.rect[1] + d.rect[3] / 2);
    return click(x, y).then(() => settle(1000)).then(() => { const p = st().windows.w1.profileId; st().switchProfile("w1", "default"); return settle(1000).then(() => p); }); });`).catch((e) => String(e));
  rep.record("canary after " + after, r === "work" ? { evidence: r } : { error: new Error(String(r)) });
};
try {
  inst = await launch(resolve(appArg), {
    data: join(scratch, "data"),
    fresh: true,
    session: fixture,
    onboarded: true,
    env: { ARDIA_NATIVE_SHELL: "1", ARDIA_NATIVE_SIDEBAR: "1", ARDIA_NATIVE_TOP_STRIP: "1", ARDIA_NATIVE_PROFILE_PAGER: "1" },
    ready: "return !!ac.store.getState().windows.w1",
  });
  await sleep(2500);
  const c0 = await run(`return col();`);
  if (!c0?.chrome) throw new Error(`no native chrome: ${JSON.stringify(c0)}`);

  await canary("launch");
  await rep.check("(a) the blank header drags the window, and a double-click acts as the titlebar's", async () => {
    await run(`st().updateSettings({ addressBar: "toolbar" }); return settle(900);`);
    const out = await run(`const x = 172, y = 20;
      const o = {};
      return act("hit:" + x + "," + y).then((h) => { o.hit = h; return act("windowDrags"); })
        .then(() => click(x, y)).then(() => settle(300)).then(() => act("windowDrags")).then((d) => { o.drags = Number(String(d).split("\\n")[0]); return frame(); })
        .then((f) => { o.before = f; return click(x, y).then(() => click(x, y, 2)); }).then(() => settle(900)).then(frame)
        .then((f) => { o.after = f; return o; });`);
    if (!/SidebarChromeView/.test(out.hit) || out.drags !== 1 || JSON.stringify(out.after) === JSON.stringify(out.before)) throw new Error(JSON.stringify(out));
    await run(`return click(172, 20).then(() => click(172, 20, 2)).then(() => settle(900)).then(() => { st().updateSettings({ addressBar: "sidebar" }); return settle(900); });`);
    return out;
  });
  await canary("(a)");

  await rep.check("(b) the address bar sits in the slot, survives toggling out and back and a reload, and opens the dropdown", async () => {
    const sample = () => run(`return globalThis.expo.modules.SolaraSidebarAddressBar.sample("w1").then((s) => s && JSON.parse(s));`);
    const first = await sample();
    await run(`st().updateSettings({ addressBar: "toolbar" }); return settle(900);`);
    const off = await run(`return col().then((c) => c?.chrome?.header ?? null);`);
    await run(`st().updateSettings({ addressBar: "sidebar" }); return settle(900);`);
    const back = await sample();
    await run(`ac.reload?.(); return settle(3000);`).catch(() => null);
    await sleep(2000);
    const reloaded = await sample();
    const c = await run(`return col();`);
    const opened = await run(`const [x, y] = [${Math.round(c0.frame[0] + 80)}, ${Math.round(c0.frame[1] + 62)}];
      return click(x, y).then(() => settle(700)).then(() => ({ panel: !!st().windowUi.w1?.panel.open }));`);
    await run(`st().closePanel("w1"); return settle(400);`);
    const out = { first, off, back, reloaded, header: c?.chrome?.header, opened };
    for (const s of [first, back, reloaded]) if (!s?.claimed || !s?.inWindow) throw new Error(JSON.stringify(out));
    if (off !== 46 || out.header !== 80 || !opened.panel) throw new Error(JSON.stringify(out));
    return out;
  });
  await canary("(b)");

  await rep.check("(c) the downloads buttons open the downloads list", async () => {
    const out = {};
    await run(`st().upsertDownload({ id: "d1", url: "https://example.com/a.pdf", filename: "a.pdf", path: "/tmp/a.pdf", state: "finished", paused: false, received: 1, total: 1, speed: 0, mimeType: "application/pdf" }); return settle(300).then(() => { st().setDownloadsOpen("w1", false); return settle(900); });`);
    for (const mode of ["sidebar", "toolbar"]) {
      await run(`st().updateSettings({ addressBar: "${mode}" }); return settle(900);`);
      const c = await run(`return col();`);
      const r = c?.chrome?.headerDownloads ?? c?.chrome?.footerDownloads;
      if (!r) { out[mode] = { missing: c?.chrome }; continue; }
      const [x, y] = centre(c, r);
      out[mode] = await run(`return click(${x}, ${y}).then(() => settle(500)).then(() => { const open = !!st().windowUi.w1?.downloadsOpen; st().setDownloadsOpen("w1", false); return open; });`);
    }
    await run(`st().removeDownload("d1"); st().updateSettings({ addressBar: "sidebar" }); return settle(900);`);
    if (out.sidebar !== true || out.toolbar !== true) throw new Error(`seed a download first if a button is missing: ${JSON.stringify(out)}`);
    return out;
  });
  await canary("(c)");

  await rep.check("(d) the resize handle drags the width live, keeps it on release, and a double-click resets it", async () => {
    const c = await run(`return col();`);
    const [x, y] = centre(c, c.chrome.resize);
    const out = await run(`const o = { saved: st().settings.sidebarWidth ?? 190 };
      return act("mouse:down:${x},${y},1").then(() => act("mouse:dragged:${x + 20},${y}")).then(() => act("mouse:dragged:${x + 40},${y}")).then(() => settle(200))
        .then(() => col()).then((c) => { o.live = c.frame[2]; return act("mouse:up:${x + 40},${y},1"); }).then(() => settle(500))
        .then(() => { o.committed = st().settings.sidebarWidth; return col(); }).then((c) => { o.after = c.frame[2]; return click(${x + 40}, ${y}).then(() => click(${x + 40}, ${y}, 2)); })
        .then(() => settle(600)).then(() => { o.reset = st().settings.sidebarWidth; return o; });`);
    if (!(out.live > out.saved + 30) || !(Math.abs(out.committed - out.after) < 1) || out.reset !== 190) throw new Error(JSON.stringify(out));
    return out;
  });
  await canary("(d)");

  await rep.check("(e) the footer's profile dots switch profiles", async () => {
    const c = await run(`return col();`);
    const dot = c.chrome.dots.find((d) => d.id === "work");
    if (!dot) throw new Error(`no dot: ${JSON.stringify(c.chrome.dots)}`);
    const [x, y] = centre(c, dot.rect);
    const out = await run(`return click(${x}, ${y}).then(() => settle(1200)).then(() => st().windows.w1.profileId);`);
    await run(`st().switchProfile("w1", "default"); return settle(1200);`);
    if (out !== "work") throw new Error(`profile ${out}`);
    return out;
  });
  await canary("(e)");

  await rep.check("(f) a drop on the header and on the footer opens a tab, with the native glow", async () => {
    const out = {};
    for (const [name, y] of [["header", 30], ["footer", 800 - 12]]) {
      out[name] = await run(`const FD = ac.shell.devFileDrag; const before = Object.keys(st().tabs).length;
        return FD.drag("w1", "move", 120, ${y}, { urls: ["https://example.com/${name}"] }).then(() => settle(400))
          .then(() => FD.drag("w1", "drop", 120, ${y})).then(() => settle(900)).then(() => ({ added: Object.keys(st().tabs).length - before }));`);
    }
    out.glow = await run(`const T = globalThis.acTabDrag; const was = T.getState();
      T.setState({ overWindow: "w1" }); return settle(400).then(() => col()).then((c) => { const on = c.chrome.dropGlow; T.setState({ overWindow: was.overWindow }); return settle(400).then(() => col()).then((c) => [on, c.chrome.dropGlow]); });`);
    if (out.header.added !== 1 || out.footer.added !== 1 || !(out.glow[0] > 0.9) || !(out.glow[1] < 0.1)) throw new Error(JSON.stringify(out));
    return out;
  });
  await canary("(f)");

  await rep.check("(g) with the column off (top tabs), RN's header, footer and glow are back", async () => {
    await run(`st().updateSettings({ tabLayout: "top" }); return settle(1500);`);
    const off = await run(`return col();`);
    await run(`st().updateSettings({ tabLayout: "sidebar" }); return settle(1500);`);
    const back = await run(`return col();`);
    if (off !== null || !back?.chrome) throw new Error(JSON.stringify({ off, back: !!back }));
    return { off, back: !!back.chrome };
  });
} catch (e) {
  rep.record("run", { error: e });
} finally {
  await inst?.quit().catch(() => {});
  if (!keep && rep.results.every((r) => r.ok)) rmSync(scratch, { recursive: true, force: true });
}
const failed = rep.results.filter((r) => !r.ok);
console.log(`${rep.results.length - failed.length}/${rep.results.length} passed${failed.length ? `; log ${rep.logFile}` : ""}`);
process.exit(failed.length ? 1 : 0);

import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { inflateSync } from "node:zlib";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(
    "usage: node top-strip-test.mjs <Debug Solara.app> [--keep-data] [--only=rn|native]\n\nThe top tab strip with pinned tabs, groups (expanded, collapsed, one holding a nested folder) and a split, once on React Native and once with ARDIA_NATIVE_TOP_STRIP=1: every item's span at the strip's middle within 0.5 pt of RN's, the store's strip entries, a click on a tab selects it, a click on a group's chip collapses it, hovering moves nothing, the two strips' pixels compared, and the peek over a hidden strip: its slide in and out frame for frame at 30 fps, and its downloads button holding it out.",
  );
  process.exit(2);
}
const appPath = resolve(appArg);
const keep = args.includes("--keep-data");
const only = args.find((a) => a.startsWith("--only="))?.slice(7);
const scratch = mkdtempSync(join(tmpdir(), "ac-top-strip-"));
const rep = reporter(join(scratch, "top-strip-test.log"), { name: "top-strip-test" });

const tab = (id, extra = {}) => ({ id, url: `https://${id}.example/`, title: `Tab ${id}`, lastActiveAt: id === "t1" ? 9 : 1, ...extra });
const fixture = () =>
  session({
    settings: { tabLayout: "top" },
    profiles: ["Personal", "Work"],
    windows: [{ id: "w1", activeTabIds: { default: "t1", work: "k1" }, frame: [80, 80, 1600, 800] }],
    tabs: ["p1", "p2"]
      .map((id) => tab(id, { pinned: true }))
      .concat(["t1", "g1a", "g1b", "g2a", "g2b", "s1a", "s1b", "f0", "fa", "fb"].map((id) => tab(id)), [tab("t2", { muted: true })], ["k1", "k2", "k3"].map((id) => tab(id, { profileId: "work" }))),
    groups: [
      { id: "g1", windowId: "w1", profileId: "default", name: "Work", icon: null, color: "blue", collapsed: false, pinned: false, tabIds: ["g1a", "g1b"], createdAt: 1 },
      { id: "g2", windowId: "w1", profileId: "default", name: "", icon: null, color: null, collapsed: true, pinned: false, tabIds: ["g2a", "g2b"], createdAt: 2 },
      { id: "g3", windowId: "w1", profileId: "default", name: "Reading", icon: "symbol:book", color: "green", collapsed: false, pinned: false, tabIds: ["f0", "fa", "fb"], createdAt: 3 },
      { id: "g3c", windowId: "w1", profileId: "default", name: "Docs", icon: null, color: null, collapsed: false, pinned: false, parentId: "g3", tabIds: ["fa", "fb"], createdAt: 4 },
    ],
    splits: [{ id: "s1", windowId: "w1", tabIds: ["s1a", "s1b"], orientation: "horizontal", sizes: [0.5, 0.5] }],
  });

const HELPERS = `
const C = globalThis.expo.modules.ArdiaCEF;
const st = () => ac.store.getState();
const win = (id) => C.chromeWindows().then((ws) => { const f = st().windows[id].frame; const w = ws.filter((w) => w.hasRoot).find((w) => { const r = w.frame.match(/[-\\d.]+/g).map(Number); return Math.abs(r[0] - f[0]) < 2 && Math.abs(r[2] - f[2]) < 2; }); return w && w.window; });
const act = (id, a) => win(id).then((n) => C.devWindow(n, a));
const runs = (id, y) => win(id).then((n) => { const xs = []; for (let x = 60; x < st().windows[id].frame[2] - 90; x += 0.5) xs.push(x);
  return Promise.all(xs.map((x) => C.devWindow(n, "hit:" + x + "," + y))).then((hits) => { const out = []; let cur = null;
    hits.forEach((h, i) => { const on = /ContextMenuArea|ImageView|Symbol|FadeLabel|Strip(TabChip|PinnedCell|GroupHeader|FolderChip|SplitPart|IconButton|NewTabButton)/.test(h);
      const kind = /^SolaraUI.StripIconButton < NSView < SolaraUI.StripGroupView/.test(h) ? "groupClose" : h.split(/[ :<(]/)[0];
      if (on && !cur) cur = [xs[i], xs[i], kind]; else if (on) cur[1] = xs[i]; else if (cur) { out.push(cur); cur = null; } });
    if (cur) out.push(cur); return out; }); });
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
`;

function readPng(path) {
  const buf = readFileSync(path);
  let width = 0, height = 0, channels = 4;
  const idat = [];
  for (let at = 8; at < buf.length; ) {
    const length = buf.readUInt32BE(at), type = buf.toString("ascii", at + 4, at + 8);
    if (type === "IHDR") {
      width = buf.readUInt32BE(at + 8);
      height = buf.readUInt32BE(at + 12);
      channels = { 2: 3, 6: 4 }[buf[at + 17]];
    } else if (type === "IDAT") idat.push(buf.subarray(at + 8, at + 8 + length));
    at += 12 + length;
  }
  const raw = inflateSync(Buffer.concat(idat));
  const stride = width * channels;
  const data = Buffer.alloc(stride * height);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    for (let x = 0; x < stride; x++) {
      const v = raw[y * (stride + 1) + 1 + x];
      const a = x >= channels ? data[y * stride + x - channels] : 0;
      const b = y ? data[(y - 1) * stride + x] : 0;
      const c = x >= channels && y ? data[(y - 1) * stride + x - channels] : 0;
      const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
      const pred = [0, a, b, (a + b) >> 1, pa <= pb && pa <= pc ? a : pb <= pc ? b : c][filter];
      data[y * stride + x] = (v + pred) & 255;
    }
  }
  return { width, height, channels, data };
}

function stripDiff(a, b, top, bottom) {
  let differ = 0, total = 0, worst = 0;
  const columns = [];
  for (let y = top * 2; y < bottom * 2; y++)
    for (let x = 0; x < Math.min(a.width, b.width); x++) {
      const i = (y * a.width + x) * a.channels, j = (y * b.width + x) * b.channels;
      const d = Math.max(Math.abs(a.data[i] - b.data[j]), Math.abs(a.data[i + 1] - b.data[j + 1]), Math.abs(a.data[i + 2] - b.data[j + 2]));
      total++;
      if (d > 24) {
        differ++;
        columns[x >> 1] = (columns[x >> 1] ?? 0) + 1;
      }
      worst = Math.max(worst, d);
    }
  const hot = columns.flatMap((n, x) => (n > 4 ? [x] : []));
  return { share: differ / total, worst, hot: hot.length ? `${hot[0]}..${hot.at(-1)} (${hot.length} columns)` : "" };
}

const SWIPE = [{ phase: "began", dx: 0, dy: 0 }, ...[-30, -30, -30, -30].map((dx) => ({ phase: "changed", dx, dy: 0 }))].map((step, i) => ({ ...step, atMs: i * 16, timestampMs: i * 16 }));
const LOOKS = [
  [
    "paging",
    `globalThis.acSwipe.strip("w1").devSimulate(${JSON.stringify(SWIPE)}, { ignorePreference: true });`,
    `globalThis.acSwipe.strip("w1").devSimulate([{ phase: "changed", dx: 60, dy: 0, atMs: 0, timestampMs: 0 }, { phase: "ended", dx: 0, dy: 0, atMs: 16, timestampMs: 16 }], { ignorePreference: true }); st().switchProfile("w1", "default");`,
  ],
  ["flipped", `st().updateSettings({ appearance: st().ui.appDark ? "light" : "dark" });`, `st().updateSettings({ appearance: "auto" });`],
  [
    "bands",
    `st().updateSettings({ extendWebsiteColor: true }); st().updateLive("t1", { themeColor: "#2b6cb0" }); st().updateLive("g1a", { themeColor: "#f6e05e" }); st().updateLive("t2", { themeColor: "#1a202c" });`,
    `st().updateSettings({ extendWebsiteColor: false }); for (const id of ["t1", "g1a", "t2"]) st().updateLive(id, { themeColor: null });`,
  ],
  [
    "peek",
    `st().toggleSidebar("w1"); setTimeout(() => globalThis.acLayout.peek["strip:w1"].show(), 450);`,
    `globalThis.acLayout.peek["strip:w1"].hide(); st().toggleSidebar("w1");`,
    56,
  ],
];

async function measure(native) {
  const data = join(scratch, native ? "native" : "rn", "data");
  const app = await launch(appPath, { data, session: fixture(), env: native ? { ARDIA_NATIVE_TOP_STRIP: "1" } : {} });
  const run = (body) => app.eval(`${HELPERS}\n${body}`);
  try {
    await sleep(2500);
    const kinds = await run(`return globalThis.expo.modules.SolaraHosted.kinds();`);
    assert.equal(kinds.includes("topStrip"), native, `topStrip kind registered: ${kinds}`);
    const out = { spans: await run(`return runs("w1", 21);`) };
    if (native) {
      out.items = JSON.parse(await run(`return globalThis.expo.modules.SolaraTopStrip.items("w1");`));
      out.keys = await run(`return globalThis.expo.modules.SolaraTopStrip.keys("w1", "default");`);
    }
    const png = join(scratch, native ? "native.png" : "rn.png");
    out.snapshot = (await run(`return ac.shell.devSnapshotWindow("w1", ${JSON.stringify(png)});`)) ? png : null;
    out.looks = {};
    for (const [look, setup, undo] of LOOKS) {
      const shot = join(scratch, `${native ? "native" : "rn"}-${look}.png`);
      await run(`${setup} return settle(900);`);
      out.looks[look] = (await run(`return ac.shell.devSnapshotWindow("w1", ${JSON.stringify(shot)});`)) ? shot : null;
      if (look === "peek") out.peekHit = await run(`return act("w1", "hit:200,22");`);
      await run(`${undo} return settle(600);`);
    }
    out.peekMotion = await run(`
      const peek = () => globalThis.acLayout.peek["strip:w1"];
      st().toggleSidebar("w1");
      return settle(600).then(() => peek().trace()).then(() => settle(50)).then(() => peek().show()).then(() => settle(500))
        .then(() => peek().hide()).then(() => settle(600)).then(() => peek().samples())
        .then((samples) => { st().toggleSidebar("w1"); return settle(600).then(() => samples); });`);
    out.peekHeld = await run(`
      const peek = () => globalThis.acLayout.peek["strip:w1"];
      const seen = {};
      st().toggleSidebar("w1");
      return settle(600).then(() => peek().show()).then(() => settle(400))
        .then(() => act("w1", "hit:1569,27")).then((hit) => (seen.hit = hit))
        .then(() => act("w1", "click:1569,27")).then(() => settle(400)).then(() => { seen.open = !!st().windowUi.w1?.downloadsOpen; seen.panel = !!st().windowUi.w1?.panel.open; st().closePanel("w1"); })
        .then(() => peek().hide()).then(() => settle(500)).then(() => (seen.heldLive = peek().live))
        .then(() => { st().setDownloadsOpen("w1", false); return settle(800); }).then(() => (seen.afterClose = peek().live))
        .then(() => { st().toggleSidebar("w1"); return settle(600); }).then(() => seen);`);
    out.peekFile = await run(`
      const peek = () => globalThis.acLayout.peek["strip:w1"];
      const drag = (action, x, payload) => globalThis.expo.modules.ArdiaFileDrop.devDrag("w1", action, x, 27, payload);
      const before = st().windows.w1.tabIds.slice();
      const seen = {};
      st().toggleSidebar("w1");
      return settle(600).then(() => peek().show()).then(() => settle(400))
        .then(() => drag("move", 200, { urls: ["https://dropped.example/"] })).then((r) => (seen.over = r)).then(() => settle(100))
        .then(() => drag("move", 300)).then(() => settle(300))
        .then(() => drag("drop", 300)).then((r) => (seen.drop = r)).then(() => settle(800))
        .then(() => {
          const ids = st().windows.w1.tabIds;
          const added = ids.find((id) => !before.includes(id));
          seen.after = added ? ids[ids.indexOf(added) - 1] ?? null : "none";
          if (added) st().closeTab(added);
          st().activate("t1");
          st().toggleSidebar("w1");
          return settle(600);
        }).then(() => seen);`);
    out.peekFrames = {};
    for (const value of [0.25, 0.5, 0.75]) {
      const shot = join(scratch, `${native ? "native" : "rn"}-peek-${value}.png`);
      await run(`st().toggleSidebar("w1"); return settle(600).then(() => globalThis.acLayout.peek["strip:w1"].show()).then(() => settle(400)).then(() => globalThis.acLayout.peek["strip:w1"].pin(${value})).then(() => settle(200));`);
      out.peekFrames[value] = (await run(`return ac.shell.devSnapshotWindow("w1", ${JSON.stringify(shot)});`)) ? shot : null;
      await run(`globalThis.acLayout.peek["strip:w1"].pin(1); globalThis.acLayout.peek["strip:w1"].hide(); return settle(600).then(() => { st().toggleSidebar("w1"); return settle(600); });`);
    }
    out.downloadsAt = await run(`
      const peek = () => globalThis.acLayout.peek["strip:w1"];
      st().toggleSidebar("w1");
      return settle(600).then(() => peek().show()).then(() => settle(400))
        .then(() => act("w1", "click:1569,27")).then(() => settle(100)).then(() => st().closePanel("w1")).then(() => settle(600)).then(() => win("w1"))
        .then((n) => {
          const points = [];
          for (let y = 60; y < 700; y += 4) points.push([1500, y]);
          for (let x = 1100; x < 1600; x += 4) points.push([x, 140]);
          return Promise.all(points.map(([x, y]) => C.devWindow(n, "hit:" + x + "," + y))).then((hits) => {
            const edges = []; let prev = null;
            hits.forEach((h, i) => { if (i === 160 || h !== prev) edges.push(points[i].join(",") + " " + h); prev = h; });
            return edges;
          });
        })
        .then((edges) => { st().setDownloadsOpen("w1", false); return settle(600).then(() => { st().toggleSidebar("w1"); return settle(600); }).then(() => edges); });`);
    if (native) {
      out.hiddenTop = await run(`
        const flick = [["began", 0], ["changed", -18], ["changed", -22], ["changed", -22], ["ended", 0]].map(([phase, dx], i) => ({ phase, dx, dy: 0, atMs: i * 16, timestampMs: i * 16, dispatch: "app" }));
        const points = [[600, 2], [600, 24], [1569, 27]];
        const seen = { points: [] };
        st().toggleSidebar("w1");
        return settle(800).then(() => win("w1")).then((n) => points.reduce((chain, [x, y]) => chain.then(() => {
            const at = { x, y };
            return act("w1", "hit:" + x + "," + y).then((hit) => (at.hit = hit))
              .then(() => globalThis.expo.modules.ArdiaFileDrop.devDrag("w1", "move", x, y, { urls: ["https://dropped.example/"] })).then((r) => (at.drag = r))
              .then(() => globalThis.expo.modules.ArdiaFileDrop.devDrag("w1", "cancel", x, y, {}))
              .then(() => globalThis.expo.modules.ArdiaSwipe.devSimulate(x, y, n, flick, true)).then((r) => (at.swipe = r.where))
              .then(() => settle(500)).then(() => { at.profile = st().windows.w1.profileId; at.live = globalThis.acLayout.peek["strip:w1"]?.live ?? null; st().switchProfile("w1", "default"); seen.points.push(at); return settle(300); });
          }), Promise.resolve()))
          .then(() => { st().toggleSidebar("w1"); return settle(600); }).then(() => seen);`);
      const live = `globalThis.acLayout.peek["strip:w1"]?.live ?? null`;
      out.peekHover = await run(`
        const seen = {};
        st().toggleSidebar("w1");
        return settle(500)
          .then(() => globalThis.acLayout.peek["strip:w1"].show()).then(() => settle(500)).then(() => (seen.shown = ${live}))
          .then(() => act("w1", "mouse:moved:300,24")).then(() => settle(150)).then(() => act("w1", "mouse:moved:520,30")).then(() => settle(500))
          .then(() => { seen.overStrip = ${live}; seen.hit = null; return act("w1", "hit:520,30"); }).then((hit) => (seen.hit = hit))
          .then(() => act("w1", "mouse:moved:520,160")).then(() => settle(600)).then(() => (seen.away = ${live}))
          .then(() => globalThis.expo.modules.SolaraTopStrip.peekMonitors()).then((n) => (seen.afterHide = n))
          .then(() => globalThis.acLayout.peek["strip:w1"].show()).then(() => settle(500)).then(() => globalThis.expo.modules.SolaraTopStrip.peekMonitors()).then((n) => (seen.whileOut = n))
          .then(() => { st().toggleSidebar("w1"); return settle(700); }).then(() => globalThis.expo.modules.SolaraTopStrip.peekMonitors()).then((n) => (seen.afterStripBack = n))
          .then(() => { seen.w2 = st().createWindow({ frame: [200, 160, 1200, 700] }); return settle(2500); })
          .then(() => { st().toggleSidebar(seen.w2); return settle(600); }).then(() => globalThis.acLayout.peek["strip:" + seen.w2]?.show()).then(() => settle(500))
          .then(() => globalThis.expo.modules.SolaraTopStrip.peekMonitors()).then((n) => (seen.secondOut = n))
          .then(() => { st().closeWindow(seen.w2); return settle(1500); }).then(() => globalThis.expo.modules.SolaraTopStrip.peekMonitors()).then((n) => (seen.afterClose = n))
          .then(() => seen);`);
    }
    const t2 = out.spans.filter(([, , k]) => k !== "SolaraUI.StripNewTabButton").at(-1);
    await run(`return act("w1", "click:${t2[0] + 70},21").then(() => settle(400));`);
    out.clicked = await run(`return st().windows.w1.activeTabIds.default;`);
    out.motion = await run(`
      const size = ${native ? `() => globalThis.expo.modules.SolaraTopStrip.groupSize("w1", "g1")` : `() => Promise.resolve(globalThis.acStrip.groupSize("g1"))`};
      const arm = ${native ? `() => globalThis.expo.modules.SolaraTopStrip.traceGroup("w1", "g1")` : `() => Promise.resolve(globalThis.acStrip.traceGroup("g1"))`};
      const trace = ${native ? `() => globalThis.expo.modules.SolaraTopStrip.groupTrace("w1")` : `() => Promise.resolve(globalThis.acStrip.groupTrace())`};
      return size().then((open) => arm().then(() => {
        st().updateGroup("g1", { collapsed: true });
        return settle(800).then(trace).then((samples) => { st().updateGroup("g1", { collapsed: false }); return settle(800).then(() => ({ open, samples })); });
      }));`);
    out.room = await run(`
      const key = "g1a,g1b";
      const trace = ${native ? `() => globalThis.expo.modules.SolaraTopStrip.slotTrace("w1")` : `() => Promise.resolve(globalThis.acStrip.slotTrace(key))`};
      const arm = ${native ? `globalThis.expo.modules.SolaraTopStrip.traceSlot("w1", key)` : `Promise.resolve(globalThis.acStrip.traceSlot(key))`};
      const path = ["222,21", "232,21", "640,21", ...Array(4).fill("640,21")].join(";");
      return arm.then(() => act("w1", "drag:" + path)).then(() => settle(150 + 74 * 16 + 700)).then(trace).then((samples) => {
        const moved = st().windows.w1.tabIds.indexOf("t1") > st().windows.w1.tabIds.indexOf("g1b");
        st().placeTabs(["t1"], { pinned: false, beforeId: "g1a" });
        return settle(500).then(() => ({ moved, samples }));
      });`);
    return { ...out, run, app };
  } catch (e) {
    await app.quit();
    throw e;
  }
}

let rn = null;
let native = null;
try {
  if (only !== "native") {
    rn = await measure(false);
    rep.log(`rn spans ${JSON.stringify(rn.spans)}`);
    await rn.app.quit();
  }
  if (only !== "rn") {
    native = await measure(true);
    rep.log(`native spans ${JSON.stringify(native.spans)}`);
    rep.log(`native items ${JSON.stringify(native.items)}`);
  }
  if (native) {
    await rep.check("native strip entries are the store's", async () => {
      assert.deepEqual(native.keys.slice(0, 4), ["pinned:p1", "pinned:p2", "tab:t1:", "group:g1:0"]);
      assert.ok(native.keys.includes("folder:g3c:fa,fb:g3"), native.keys.join(" "));
      assert.ok(native.keys.includes("split:s1:s1a,s1b:"), native.keys.join(" "));
    });
    await rep.check("a click on a tab selects it", async () => assert.equal(native.clicked, "t2"));
    await rep.check("a click on a group's chip collapses it", async () => {
      const g1 = native.items.items.find((i) => i.kind === "groupChip" && i.id === "g1");
      await native.run(`return act("w1", "click:${g1.windowX + g1.width / 2},21").then(() => settle(500));`);
      assert.equal(await native.run(`return st().groups.g1.collapsed;`), true);
      await native.run(`st().updateGroup("g1", { collapsed: false }); return settle(500);`);
    });
    await rep.check("hovering moves nothing", async () => {
      const result = JSON.parse(await native.run(`return globalThis.expo.modules.SolaraTopStrip.hoverShifts("w1");`));
      assert.ok(result.hovered.length > 5, `hovered ${result.hovered.length}`);
      assert.deepEqual(result.shifts, []);
    });
  }
  if (rn && native) {
    await rep.check("every item spans where RN's does, within 0.5 pt", async () => {
      const show = (s) => s.map(([a, b, k]) => `${a}-${b} ${k}`).join("\n");
      const pressables = native.spans.filter(([, , k]) => k === "groupClose" || k === "SolaraUI.StripNewTabButton");
      assert.equal(pressables.length, 3, show(native.spans));
      const joined = (spans) => spans.reduce((out, s) => (out.length && s[0] - out.at(-1)[1] <= 1 ? (out.at(-1)[1] = s[1], out) : [...out, [...s]]), []);
      const ours = joined(native.spans.filter((s) => !pressables.includes(s)));
      const theirs = joined(rn.spans);
      assert.equal(ours.length, theirs.length, `runs:\nrn\n${show(theirs)}\nnative\n${show(ours)}`);
      const off = ours.flatMap((s, i) => (Math.abs(s[0] - theirs[i][0]) > 0.5 || Math.abs(s[1] - theirs[i][1]) > 0.5 ? [`#${i} rn ${theirs[i]} native ${s}`] : []));
      assert.deepEqual(off, []);
    });
    await rep.check("a click on a tab selects it on RN too", async () => assert.equal(rn.clicked, "t2"));
    await rep.check("the peek's downloads button opens the list and holds the peek out until it closes, as on RN", async () => {
      rep.log(`peek held rn ${JSON.stringify(rn.peekHeld)} native ${JSON.stringify(native.peekHeld)}`);
      assert.match(native.peekHeld.hit, /^SolaraUI\.StripIconButton < SolaraUI\.StripControlsView/, `the native button is under the pointer: ${native.peekHeld.hit}`);
      for (const [name, seen] of [["rn", rn.peekHeld], ["native", native.peekHeld]]) {
        assert.equal(seen.open, true, `${name}: the click opened the downloads list`);
        assert.equal(seen.heldLive, true, `${name}: the open list holds the peek out`);
        assert.equal(seen.afterClose, false, `${name}: closing the list lets the peek go`);
      }
    });
    await rep.check("a link dropped on the peek opens where RN's peek puts it", async () => {
      rep.log(`peek file rn ${JSON.stringify(rn.peekFile)} native ${JSON.stringify(native.peekFile)}`);
      assert.match(native.peekFile.over, /FileDropView/, `the drag is over the peek's drop area: ${native.peekFile.over}`);
      assert.notEqual(rn.peekFile.after, "none", "RN opened the link");
      assert.equal(native.peekFile.after, rn.peekFile.after, "the link lands after the same tab");
      assert.notEqual(rn.peekFile.after, "t2", "RN puts it at the pointer, not at the end");
    });
    await rep.check("the downloads list opens from the peek's button where RN's does", async () => {
      const shown = (edges) => edges.filter((e) => !/^\d+,(60|64) /.test(e)).join("\n");
      assert.ok(rn.downloadsAt.length > 2, `RN's list shows: ${shown(rn.downloadsAt)}`);
      assert.equal(shown(native.downloadsAt), shown(rn.downloadsAt));
    });
    for (const value of [0.25, 0.5, 0.75]) {
      if (!rn.peekFrames?.[value] || !native.peekFrames?.[value]) continue;
      await rep.check(`the peek's pixels match RN's ${value * 100}% of the way out, shadow included`, async () => {
        const diff = stripDiff(readPng(rn.peekFrames[value]), readPng(native.peekFrames[value]), 0, 80);
        rep.log(`peek at ${value} pixel diff ${JSON.stringify(diff)}`);
        assert.ok(diff.share < 0.01, `${(diff.share * 100).toFixed(2)}% of the peek's pixels differ (worst ${diff.worst}, ${diff.hot})`);
      });
    }
    await rep.check("the peek slides in and out on RN's 180 ms out-cubic, frame for frame at 30 fps", async () => {
      const show = (samples) => JSON.stringify(samples.map(([t, x]) => [Math.round(t), Math.round(x * 1000) / 1000]));
      rep.log(`rn peek ${show(rn.peekMotion)}`);
      rep.log(`native peek ${show(native.peekMotion)}`);
      const phases = (samples) => {
        const top = samples.findIndex(([, x]) => x >= 0.9999);
        const last = samples.findLastIndex(([, x]) => x >= 0.9999);
        return { in: samples.slice(0, top + 1).filter(([, x], i) => i === 0 || x > 0), out: samples.slice(last) };
      };
      const cubic = (p) => 1 - Math.pow(1 - Math.min(1, Math.max(0, p)), 3);
      const models = { in: (ms) => cubic(ms / 180), out: (ms) => 1 - cubic(ms / 180) };
      const fit = (samples, model) => {
        let best = null;
        const moving = samples[1][0];
        for (let start = moving - 200; start <= moving + 20; start += 0.25) {
          const error = Math.max(...samples.slice(1).map(([t, x]) => Math.abs(x - model(t - start))));
          if (!best || error < best.error) best = { start, error };
        }
        return best;
      };
      const at = (samples, t) => {
        const i = samples.findIndex(([u]) => u >= t);
        if (i <= 0) return i === 0 ? samples[0][1] : samples.at(-1)[1];
        const [ta, xa] = samples[i - 1], [tb, xb] = samples[i];
        return xa + ((xb - xa) * (t - ta)) / (tb - ta);
      };
      for (const phase of ["in", "out"]) {
        const theirs = phases(rn.peekMotion)[phase], ours = phases(native.peekMotion)[phase];
        assert.ok(theirs.length > 3 && ours.length > 3, `${phase}: traced rn ${theirs.length} native ${ours.length}`);
        const a = fit(theirs, models[phase]), b = fit(ours, models[phase]);
        const frames = Array.from({ length: 6 }, (_, k) => Math.abs(at(theirs, a.start + ((k + 1) * 1000) / 30) - at(ours, b.start + ((k + 1) * 1000) / 30)));
        rep.log(`peek ${phase}: RN within ${a.error.toFixed(3)} of the curve, native within ${b.error.toFixed(3)}; 30 fps frames differ by ${frames.map((d) => d.toFixed(3)).join(" ")}`);
        assert.ok(b.error <= 0.02, `native's slide ${phase} is ${b.error.toFixed(3)} off RN's 180 ms out-cubic`);
        assert.ok(Math.max(...frames) <= 0.05, `${phase}: a 30 fps frame differs by ${Math.max(...frames).toFixed(3)} of the slide`);
      }
    });
    await rep.check("a collapsing group closes on RN's spring, frame for frame", async () => {
      const ours = native.motion.samples, theirs = rn.motion.samples;
      rep.log(`rn motion ${JSON.stringify(theirs.map(([t, x]) => [Math.round(t), Math.round(x * 10) / 10]))}`);
      rep.log(`native motion ${JSON.stringify(ours.map(([t, x]) => [Math.round(t), Math.round(x * 10) / 10]))}`);
      assert.equal(native.motion.open, rn.motion.open, "the same open width");
      assert.ok(theirs.length > 3 && ours.length > 3, `traced: rn ${theirs.length} native ${ours.length}`);
      const omega = (2 * Math.PI) / 0.3, zeta = 0.82, damped = omega * Math.sqrt(1 - zeta * zeta);
      const fit = (samples) => {
        const from = samples[0][1], to = samples.at(-1)[1];
        const group = (ms) => (ms <= 0 ? from : to + (from - to) * Math.exp((-zeta * omega * ms) / 1000) * (Math.cos((damped * ms) / 1000) + ((zeta * omega) / damped) * Math.sin((damped * ms) / 1000)));
        let best = null;
        for (let start = 0; start <= 120; start += 0.25) {
          const error = Math.max(...samples.map(([t, x]) => Math.abs(x - group(t - start))));
          if (!best || error < best.error) best = { start, error };
        }
        return best;
      };
      const a = fit(theirs), b = fit(ours);
      rep.log(`motion: RN's spring starts at ${a.start} ms and keeps within ${a.error.toFixed(2)} pt of GROUP_SPRING; native's at ${b.start} ms, within ${b.error.toFixed(2)} pt`);
      assert.ok(Math.abs(ours.at(-1)[1] - theirs.at(-1)[1]) < 0.05, `both settle at the same width: rn ${theirs.at(-1)[1]} native ${ours.at(-1)[1]}`);
      assert.ok(a.error <= 2, `RN's own curve is ${a.error.toFixed(2)} pt off GROUP_SPRING`);
      assert.ok(b.error <= 2, `native's curve is ${b.error.toFixed(2)} pt off RN's GROUP_SPRING`);
      assert.ok(b.start - a.start <= 25, `native starts ${b.start - a.start} ms after RN: more than a frame and a half`);
    });
    await rep.check("the strip makes room for a dragged tab on RN's spring, frame for frame", async () => {
      const ours = native.room.samples, theirs = rn.room.samples;
      rep.log(`rn room ${JSON.stringify(theirs.map(([t, x]) => [Math.round(t), Math.round(x * 10) / 10]))}`);
      rep.log(`native room ${JSON.stringify(ours.map(([t, x]) => [Math.round(t), Math.round(x * 10) / 10]))}`);
      assert.ok(rn.room.moved && native.room.moved, `the tab landed past the group: rn ${rn.room.moved} native ${native.room.moved}`);
      assert.ok(theirs.length > 3 && ours.length > 3, `traced: rn ${theirs.length} native ${ours.length}`);
      const far = (samples) => samples.reduce((m, [, x]) => (Math.abs(x) > Math.abs(m) ? x : m), 0);
      assert.ok(Math.abs(far(theirs)) > 100 && Math.abs(far(ours) - far(theirs)) < 0.05, `the same room: rn ${far(theirs)} native ${far(ours)}`);
      const room = far(theirs);
      const slide = (t) => (t <= 0 ? 0 : room * (1 - (1 + 0.09 * t) * Math.exp(-0.09 * t)));
      const fit = (samples) => {
        let best = null;
        for (let start = -30; start <= 30; start += 0.25) {
          const error = Math.max(...samples.map(([t, x]) => Math.abs(x - slide(t - start))));
          if (!best || error < best.error) best = { start, error };
        }
        return best;
      };
      const a = fit(theirs), b = fit(ours);
      rep.log(`room: RN's spring starts at ${a.start} ms and keeps within ${a.error.toFixed(2)} pt of SLIDE; native's at ${b.start} ms, within ${b.error.toFixed(2)} pt`);
      assert.ok(a.error <= 2, `RN's own curve is ${a.error.toFixed(2)} pt off SLIDE`);
      assert.ok(b.error <= 2, `native's curve is ${b.error.toFixed(2)} pt off RN's SLIDE spring`);
      assert.ok(Math.abs(a.start - b.start) <= 25, `RN starts ${a.start - b.start} ms after native: more than a frame and a half`);
    });
    if (rn.snapshot && native.snapshot) {
      await rep.check("the strips' pixels match RN's", async () => {
        const diff = stripDiff(readPng(rn.snapshot), readPng(native.snapshot), 0, 42);
        rep.log(`pixel diff ${JSON.stringify(diff)}`);
        assert.ok(diff.share < 0.01, `${(diff.share * 100).toFixed(2)}% of the strip's pixels differ (worst ${diff.worst}, ${diff.hot})`);
      });
    }
    await rep.check("with the peek hidden, a drop, a swipe and a click at the top of the window reach what is under it", async () => {
      for (const at of native.hiddenTop.points) {
        rep.log(`hidden peek at ${at.x},${at.y}: ${JSON.stringify(at).slice(0, 400)}`);
        assert.doesNotMatch(at.hit, /StripPeek|SolaraHostedView|FileDropView|SwipeArea/, `the click at ${at.x},${at.y} reaches ${at.hit}`);
        assert.doesNotMatch(at.drag, /FileDropView/, `the drop at ${at.x},${at.y} goes to ${at.drag}`);
        assert.doesNotMatch(String(at.swipe?.hit), /StripPeek|SolaraHostedView|FileDropView|SwipeArea/, `the swipe at ${at.x},${at.y} hits ${at.swipe?.hit}`);
        assert.equal(at.profile, "default", `the swipe at ${at.x},${at.y} paged the strip's profiles`);
        assert.equal(at.live, false, "the peek stayed hidden");
      }
    });
    await rep.check("the peek stays out while the pointer is over its native strip, and slides away once it leaves the panel", async () => {
      const seen = native.peekHover;
      rep.log(`peek hover ${JSON.stringify(seen)}`);
      assert.equal(seen.shown, true, "the peek came out");
      assert.match(seen.hit, /^SolaraUI\.Strip/, `the pointer is over the native strip: ${seen.hit}`);
      assert.equal(seen.overStrip, true, "still out over the native strip");
      assert.equal(seen.away, false, "gone once the pointer left the panel");
      assert.deepEqual([seen.afterHide, seen.whileOut, seen.afterStripBack, seen.secondOut, seen.afterClose], [1, 1, 0, 1, 0], "one pointer monitor per window while its strip is hidden, none once the strip comes back or its window closes");
    });
    for (const [look, , , bottom = 42] of LOOKS) {
      if (!rn.looks?.[look] || !native.looks?.[look]) continue;
      await rep.check(`the strips' pixels match RN's, ${{ paging: "halfway through a swipe to the next profile", flipped: "in the other appearance", bands: "with website colour bands", peek: "in the peek over a hidden strip" }[look]}`, async () => {
        if (look === "peek") assert.match(native.peekHit, /^SolaraUI\.Strip/, `the peek holds the native strip: ${native.peekHit}`);
        const diff = stripDiff(readPng(rn.looks[look]), readPng(native.looks[look]), 0, bottom);
        rep.log(`${look} pixel diff ${JSON.stringify(diff)}`);
        assert.ok(diff.share < 0.01, `${(diff.share * 100).toFixed(2)}% of the strip's pixels differ (worst ${diff.worst}, ${diff.hot})`);
      });
    }
  }
} finally {
  if (native) await native.app.quit();
  if (!keep && rep.results.every((r) => r.ok)) for (const name of ["rn", "native", "rn.png", "native.png", ...LOOKS.flatMap(([look]) => [`rn-${look}.png`, `native-${look}.png`]), ...[0.25, 0.5, 0.75].flatMap((v) => [`rn-peek-${v}.png`, `native-peek-${v}.png`])]) rmSync(join(scratch, name), { recursive: true, force: true });
  else rep.say(`kept ${scratch}`);
}
process.exit(rep.summary() ? 0 : 1);

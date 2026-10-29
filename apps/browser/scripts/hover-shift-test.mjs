import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const [appArg, port] = process.argv.slice(2);
if (!appArg) {
  console.error("usage: node hover-shift-test.mjs <Debug Solara.app> [cdpPort]");
  process.exit(2);
}
const passes = {
  rn: { ARDIA_NATIVE_OMNIBOX: "0", ARDIA_NATIVE_NEWTAB: "0" },
  native: { ARDIA_NATIVE_OMNIBOX: "1", ARDIA_NATIVE_NEWTAB: "1" },
};
const pass = process.env.HOVER_SHIFT_PASS;
if (!pass) {
  const failed = Object.keys(passes).filter((name) =>
    spawnSync(process.execPath, [fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: "inherit", env: { ...process.env, HOVER_SHIFT_PASS: name } }).status !== 0);
  process.exit(failed.length ? 1 : 0);
}
if (!passes[pass]) {
  console.error(`HOVER_SHIFT_PASS is ${Object.keys(passes).join(" or ")}`);
  process.exit(2);
}
const scratch = mkdtempSync(join(tmpdir(), "ac-hover-shift-"));
const data = join(scratch, "data");
mkdirSync(data);
const rep = reporter(join(scratch, "hover-shift-test.log"), { name: `hover-shift-test ${pass}` });
const file = join(data, "report.pdf");
writeFileSync(file, "%PDF-1.4\n");

const ids = ["pin1", "pin2", "a1", "a2", "a3", "b1", "b2", ...Array.from({ length: 12 }, (_, i) => `t${i}`)];
const tab = (id) => {
  const pinned = id.startsWith("pin");
  return { id, url: `https://example.com/?${id}`, title: `Tab ${id} with a title long enough to fade`, pinned,
    pinnedUrl: pinned ? `https://example.com/?${id}` : null };
};

let app;
try {
  app = await launch(resolve(appArg), {
    data, port,
    session: session({ profiles: ["Personal", "Work"], windows: [{ id: "w1", tabIds: ids, activeTabIds: { default: "t2" } }], tabs: ids.map(tab) }),
    ready: "return !!ac.hoverShift",
    env: passes[pass],
  });
  const ac = (body) => app.eval(body, { timeout: 120000 });
  const nativeDownloadShifts = async () => {
    const r = JSON.parse(await ac(`return globalThis.expo.modules.SolaraDownloads.devHoverShifts();`));
    if (!r.hosts) throw new Error("the native downloads list isn't shown");
    return { hovered: r.hovered, shifts: r.shifts };
  };

  await ac(`
    const s = ac.store.getState();
    s.createGroup(["a1", "a2", "a3"], { name: "Open group" });
    const shut = s.createGroup(["b1", "b2"], { name: "Shut group", color: "blue" });
    s.updateGroup(shut, { collapsed: true });
    const { store, engine } = ac.live;
    const folder = store.createFolder("default", "pullRequests");
    const pr = (n, extra) => ({ number: n, repo: "ardia/app", author: "a", authorAvatar: null, draft: false, headRef: "h" + n, baseRef: "main",
      review: null, mergeable: "mergeable", checks: [], comments: 0, unresolvedThreads: 0, additions: 1, deletions: 1, changedFiles: 1, ...extra });
    const item = (n, extra) => ({ id: "pr" + n, source: "github", url: "https://example.com/pr/" + n, title: "Pull request " + n + " with a long title",
      subtitle: "", icon: null, updatedAt: Date.now() - n, section: "authored", pr: pr(n, extra) });
    const items = [item(1, { review: "approved" }), item(2, {}), item(3, { mergeable: "conflicting" })];
    store.applyFetch(folder, items, {});
    store.setStatus(folder, { state: "idle", lastFetch: Date.now(), error: null });
    engine.openLiveItem("w1", folder, items[1], { background: true });
    engine.openLiveItem("w1", folder, items[2], { background: true });
    s.upsertDownload({ id: "d1", url: "https://example.com/report.pdf", filename: "report.pdf", path: ${JSON.stringify(file)},
      state: "finished", paused: false, received: 9, total: 9, speed: 0, mimeType: "application/pdf" });
    s.setDownloadsOpen("w1", false);
    return true;
  `);
  await sleep(1500);

  const surfaces = [
    ["sidebar", `ac.store.getState().updateSettings({ tabLayout: "sidebar" });`, ["Sidebar"]],
    ["tab strip", `ac.store.getState().updateSettings({ tabLayout: "top" });`, ["TopTabStrip"]],
    ["downloads", `ac.store.getState().updateSettings({ tabLayout: "sidebar" }); ac.store.getState().setDownloadsOpen("w1", true);`, ["DownloadsPopover"]],
  ];
  for (const [name, setup, scopes] of surfaces) {
    await rep.check(name, async () => {
      await ac(`${setup} return true;`);
      await sleep(1200);
      const native = name === "sidebar" && (await ac(`return globalThis.expo.modules.SolaraHosted.kinds().includes("sidebar");`));
      const nativeStrip = name === "tab strip" && (await ac(`return globalThis.expo.modules.SolaraHosted.kinds().includes("topStrip");`));
      const nativeDownloads = name === "downloads" && (pass === "native" || !!JSON.parse(await ac(`return globalThis.expo.modules.SolaraDownloads.devHoverShifts();`)).hosts);
      const { hovered, shifts } = nativeDownloads
        ? await nativeDownloadShifts()
        : native
        ? await ac(`return globalThis.expo.modules.SolaraHosted.sidebarHoverShifts("w1").then((json) => JSON.parse(json)).then((r) => ({ hovered: r.hovered, shifts: r.shifts.map((s) => ({ hovered: s, view: "native row", before: [], after: [] })) }));`)
        : nativeStrip
        ? await ac(`return globalThis.expo.modules.SolaraTopStrip.hoverShifts("w1").then((json) => JSON.parse(json)).then((r) => ({ hovered: r.hovered.length, shifts: r.shifts.map((s) => ({ hovered: s, view: "native strip item", before: [], after: [] })) }));`)
        : await ac(`return ac.hoverShift.check({ scopes: ${JSON.stringify(scopes)} });`);
      if (!hovered) throw new Error("nothing hover-tracked found");
      if (shifts.length) {
        throw new Error([`${shifts.length} views moved or resized (${hovered} hovered)`,
          ...shifts.slice(0, 20).flatMap((s) => [`hovering ${s.hovered}`, `  ${s.view}: ${s.before.join(", ")} -> ${s.after.join(", ")}`])].join("\n"));
      }
      return `${hovered} hovered views, nothing moved`;
    });
  }
} catch (error) {
  rep.record("setup", { error });
} finally {
  await app?.quit();
  rmSync(data, { recursive: true, force: true });
}
process.exit(rep.summary() ? 0 : 1);

import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { devtools, launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node pane-prompts-test.mjs <Debug Solara.app> [--keep-data]

The pooled pane's prompts drawn from pool page events with ARDIA_NATIVE_PANE_PROMPTS=1 (page pool on), against the
same page with the switch off. Password: a real form submission brings Chrome's save prompt; with the switch on RN
mounts no PasswordPrompt and the native popover sits 8 points from the pane's top right at 350 wide, with Never on
This Site, Not Now and Save; a click on Save, after the input guard's delay, saves the login and closes it; a second
submission's prompt goes when the page navigates to another page. With the switch off the RN wrapper still draws it.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-pane-prompts-"));
const rep = reporter(join(scratch, "pane-prompts-test.log"), { name: "pane-prompts-test" });

const page = (title, body) => `<!doctype html><title>${title}</title><link rel="icon" href="data:,"><body>${body}</body>`;
const server = createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/html" });
  const url = new URL(req.url, "http://x");
  if (url.pathname === "/login")
    return res.end(page("Login", `<form action="/done" method="get"><input name="u" id="u" autocomplete="username"><input type="password" name="p" id="p" autocomplete="current-password"><button id="go">Sign in</button></form>`));
  if (url.pathname === "/done") return res.end(page("Done", "signed in"));
  res.end(page("Other", "other"));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}`;
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [{ id: "a", url: `${base}/login`, title: "Login" }],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
});

const HELPERS = `
const C = globalThis.expo.modules.ArdiaCEF;
const M = globalThis.expo.modules.SolaraMedia;
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const act = (n, a) => C.devWindow(n, a);
const click = (n, p) => act(n, "mouse:moved:" + Math.round(p[0]) + "," + Math.round(p[1])).then(() => settle(60))
  .then(() => act(n, "mouse:down:" + Math.round(p[0]) + "," + Math.round(p[1]))).then(() => settle(60)).then(() => act(n, "mouse:up:" + Math.round(p[0]) + "," + Math.round(p[1])));
const native = () => M.describePaneOverlays("w1").then(JSON.parse);
const rnPrompt = () => acPerf.findFibers("PasswordPrompt", 5).filter((f) => !!f.child).length;
`;
let app = null;
const run = (body, timeout = 20000) => app.eval(`${HELPERS}\n${body}`, { timeout });
const until = async (what, test, ms = 8000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await (typeof test === "string" ? run(test) : test()).catch((e) => ({ error: String(e.message ?? e) }));
    if (last && !last.error) return last;
    await sleep(150);
  }
  throw new Error(`${what}: never true (last ${JSON.stringify(last)})`);
};
const centre = (f) => [f[0] + f[2] / 2, f[1] + f[3] / 2];
const POOL = { ARDIA_NATIVE_SHELL: "1", ARDIA_NATIVE_PAGES_POOL: "1", ARDIA_SHELL_PANES: "1", ARDIA_TAB_POOL: "1" };
const LEGS = [
  { tag: "rn", env: { ...POOL, ARDIA_NATIVE_PANE_PROMPTS: "0" } },
  { tag: "native", env: { ...POOL, ARDIA_NATIVE_PANE_PROMPTS: "1" } },
];

async function submit(user, pass) {
  await until("the login page", `return ac.store.getState().tabs.a?.title === "Login" && !ac.store.getState().live.a?.isLoading || null;`, 10000);
  const target = await until("its DevTools target", async () => (await app.pageTarget(`${base}/login`)) ?? null, 5000);
  const cdp = await devtools(target);
  try {
    for (const [field, text] of [["u", user], ["p", pass]]) {
      await cdp.send("Runtime.evaluate", { expression: `document.getElementById('${field}').focus()` });
      await cdp.send("Input.insertText", { text });
    }
    const box = JSON.parse(await cdp.eval("JSON.stringify(document.getElementById('go').getBoundingClientRect())"));
    const at = { x: box.x + box.width / 2, y: box.y + box.height / 2, button: "left", clickCount: 1 };
    await cdp.send("Input.dispatchMouseEvent", { type: "mousePressed", ...at, buttons: 1 });
    await cdp.send("Input.dispatchMouseEvent", { type: "mouseReleased", ...at, buttons: 0 });
  } finally {
    cdp.close();
  }
}

try {
  for (const { tag, env } of LEGS) {
    const nativePrompts = tag === "native";
    app = await launch(resolve(appArg), {
      data: join(scratch, `data-${tag}`), fresh: true, session: fixture, onboarded: true, probe: true, env,
      ready: "return !!ac.store.getState().windows.w1",
    });
    await until("page A", `return ac.store.getState().tabs.a?.title === "Login" || null;`, 15000);
    const number = await until("window w1", `const id = Object.entries(ac.pageState.getState().browsers ?? {}).find(([, t]) => t === "a")?.[0]; return id ? C.devWindowNumber(Number(id)) : null;`, 15000);
    const served = await run(`return !!globalThis.expo.modules.SolaraTabPool?.available?.() && !!ac.webviews.get("a") && !acPerf.findFibers("TabWebView", 5).length;`);
    if (!served) throw new Error(`${tag}: the pool doesn't serve page A`);
    const kinds = await run(`return globalThis.expo.modules.SolaraHosted.kinds();`);
    if (kinds.includes("panePrompts") !== nativePrompts) throw new Error(`${tag}: hosted kinds ${JSON.stringify(kinds)}`);

    await rep.check(`${tag}-password-save`, async () => {
      await submit("ada", "s3cret-pass");
      await until("the prompt reaches the store", `return ac.pageState.getState().pages.a?.passwordPrompt?.state === "save" || null;`, 10000);
      if (!nativePrompts) {
        await until("RN draws the prompt", `return rnPrompt() || null;`, 4000);
        await run(`ac.pageState.setState((s) => ({ pages: { ...s.pages, a: { ...s.pages.a, passwordPrompt: null } } })); return true;`);
        return "rn";
      }
      const shown = await until("the native prompt", `return native().then((d) => d && d.tabs.a && d.tabs.a.password && !d.tabs.a.password.hidden && d.tabs.a.password.controls.Save ? d.tabs.a.password : null);`, 6000);
      if (await run(`return rnPrompt();`)) throw new Error("RN still draws the password prompt");
      const [fx, fy, fw] = shown.frame;
      const [cx, cy, cw] = shown.card;
      if (Math.abs(cw - 350) > 0.5 || Math.abs(fx + fw - 8 - (cx + cw)) > 0.5 || Math.abs(fy + 8 - cy) > 0.5)
        throw new Error(`card ${JSON.stringify(shown.card)} in pane ${JSON.stringify(shown.frame)}`);
      for (const title of ["Never on This Site", "Not Now", "Save"]) if (!shown.controls[title]) throw new Error(`no ${title}: ${Object.keys(shown.controls)}`);
      await sleep(800);
      await run(`return click(${number}, ${JSON.stringify(centre(shown.controls.Save))}).then(() => true);`);
      await until("the prompt closes", `return native().then((d) => !d || !d.tabs.a || !d.tabs.a.password || null);`, 3000);
      await until("the store's prompt clears", `return !ac.pageState.getState().pages.a?.passwordPrompt || null;`, 3000);
      const saved = await until("the saved login", `return C.listPasswords("").then((l) => (l.passwords || []).find((x) => x.username === "ada") || null);`, 8000);
      return { card: shown.card, saved: !!saved };
    });

    await rep.check(`${tag}-password-gone-on-navigation`, async () => {
      await run(`ac.store.getState().navigate("a", ${JSON.stringify(`${base}/login`)}, { userInitiated: true }); return true;`);
      await submit("grace", "an0ther-pass");
      await until("a second prompt", `return ac.pageState.getState().pages.a?.passwordPrompt || null;`, 10000);
      if (nativePrompts) await until("the native prompt", `return native().then((d) => d && d.tabs.a && d.tabs.a.password || null);`, 6000);
      await run(`ac.store.getState().navigate("a", ${JSON.stringify(`${base}/other`)}, { userInitiated: true }); return true;`);
      await until("the store's prompt clears", `return !ac.pageState.getState().pages.a?.passwordPrompt || null;`, 8000);
      if (nativePrompts) await until("the native prompt goes", `return native().then((d) => !d || !d.tabs.a || !d.tabs.a.password || null);`, 4000);
      return true;
    });

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

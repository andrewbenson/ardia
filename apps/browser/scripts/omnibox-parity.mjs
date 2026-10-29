const HELP = `Drives the same omnibox scripts through the RN bar and the native one and compares their state after every step.

  node apps/browser/scripts/omnibox-parity.mjs <Debug Solara.app> [--only name,…] [--keep DIR]

Two hidden instances run side by side, one with ARDIA_NATIVE_OMNIBOX=0 and one with =1, each with the same seeded
history. Each script opens a bar (the command panel, the sidebar dropdown or the New Tab bar), drives it through the
ac.omnibox driver and reads typed, value, completion, selection, the rows and the selected row after every step.
Prints one line per script and exits 1 on any difference.`;

import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, sleep } from "../../../scripts/lib/instance.mjs";

const argv = process.argv.slice(2);
if (!argv.length || argv.includes("-h") || argv.includes("--help")) {
  console.log(HELP);
  process.exit(argv.length ? 0 : 2);
}
const app = resolve(argv[0]);
const only = argv.includes("--only") ? argv[argv.indexOf("--only") + 1].split(",") : null;
const scratch = argv.includes("--keep") ? resolve(argv[argv.indexOf("--keep") + 1]) : mkdtempSync(join(tmpdir(), "ac-omnibox-parity-"));

const now = Date.now();
const history = [
  ["https://github.com/", "GitHub", 30],
  ["https://github.com/mantrakp04/ardia", "mantrakp04/ardia", 6],
  ["https://mail.google.com/mail/u/0/", "Inbox - Gmail", 20],
  ["https://news.ycombinator.com/", "Hacker News", 12],
  ["https://www.youtube.com/", "YouTube", 9],
  ["https://developer.apple.com/documentation/swiftui", "SwiftUI | Apple Developer Documentation", 4],
  ["https://en.wikipedia.org/wiki/Main_Page", "Wikipedia, the free encyclopedia", 3],
  ["https://localhost:3000/", "Local app", 2],
].map(([url, title, visits], i) => ({ url, title, visits, lastVisit: now - (i + 1) * 60_000 }));

const t = (text) => ["type", text];
const k = (key, mods = {}) => ["key", key, mods];
const typing = (word) => [...word].map((c) => ["keys", c]);
const del = (n = 1) => ["keys", "\u007f".repeat(n)];

const scripts = {
  "inline completion while typing": { bar: "panel", steps: typing("git") },
  "deleting drops the completion": { bar: "panel", steps: [...typing("git"), del(), del()] },
  "a paste does not complete": { bar: "panel", steps: [t("git")] },
  "typing again after a paste completes": { bar: "panel", steps: [t("git"), ...typing("h")] },
  "trailing space": { bar: "panel", steps: [...typing("git"), ["keys", " "]] },
  "arrows wrap, page keys jump": { bar: "panel", steps: [...typing("hacker"), k("ArrowDown"), k("ArrowDown"), k("ArrowUp"), k("ArrowUp"), k("ArrowUp"), k("PageDown"), k("PageUp")] },
  "control n and p": { bar: "panel", steps: [...typing("you"), k("n", { ctrlKey: true }), k("p", { ctrlKey: true })] },
  "tab enters site search, backspace leaves": { bar: "panel", steps: [...typing("youtube"), k("Tab"), ...typing("ca"), del(2), k("Backspace")] },
  "space after a keyword enters site search": { bar: "panel", steps: [t("youtube.com"), ["keys", " "]] },
  "shift tab moves back": { bar: "panel", steps: [...typing("gi"), k("Tab", { shiftKey: true })] },
  "calculator": { bar: "panel", steps: [t("12*12"), ...typing("+1")] },
  "bang": { bar: "panel", steps: [t("!w cats"), t("cats !yt")] },
  "escape leaves a scope first": { bar: "panel", steps: [t("youtube.com"), ["keys", " "], k("Escape")] },
  "the dropdown starts with recent pages": { bar: "sidebar", steps: [["noop"], ...typing("wik")] },
  "the new tab bar lists open tabs": { bar: "newTab", steps: [["noop"], k("ArrowDown"), k("ArrowUp"), ...typing("hack"), del(4)] },
  "right arrow accepts the completion": { bar: "panel", steps: [...typing("git"), ["keys", "\uF703"]] },
  "backspace after accepting deletes": { bar: "panel", steps: [...typing("git"), ["keys", "\uF703"], del()] },
  "no completion with the caret before the end": { bar: "panel", steps: [...typing("gi"), ["keys", "\uF702"], ...typing("x")] },
  "typing over a selection completes": { bar: "panel", steps: [...typing("gi"), ["select", 0, 2], ...typing("g")] },
  "shift delete removes a history row": { bar: "panel", steps: [...typing("hacker"), k("ArrowDown"), k("Delete", { shiftKey: true })] },
  "tab accepts the inline completion": { bar: "panel", steps: [...typing("mai"), k("Tab")] },
  "a pasted newline becomes a space": { bar: "panel", steps: [t("hacker\nnews")] },
  "localhost and urls": { bar: "panel", steps: [t("localhost:3000"), t("foo/"), t("münchen.de"), t("a.b")] },
  "command return opens the row in a new tab": { bar: "panel", nav: true, steps: [t("localhost:3000/x"), k("Enter", { metaKey: true })] },
  "option return opens the row in a new tab": { bar: "panel", nav: true, steps: [t("localhost:3000/x"), k("Enter", { altKey: true })] },
  "shift command return searches what was typed": { bar: "panel", nav: true, steps: [t("hacker"), k("Enter", { metaKey: true, shiftKey: true })] },
  "shift return opens a new window": { bar: "panel", nav: true, steps: [t("localhost:3000/x"), k("Enter", { shiftKey: true })] },
  "control return adds www and com": { bar: "panel", nav: true, steps: [t("example"), k("Enter", { ctrlKey: true })] },
};

const pick = (s) => ({
  typed: s.typed,
  value: s.value,
  completion: s.completion,
  selected: s.selected,
  scope: s.scope ? `${s.scope.kind}:${s.scope.name}` : null,
  tabScope: s.tabScope ? s.tabScope.name : null,
  items: (s.items ?? []).map((i) => `${i.kind}:${i.url ?? i.query ?? i.id ?? i.value ?? ""}${i.tabId ? " (tab)" : ""}`),
});

async function start(native) {
  const data = join(scratch, native ? "native" : "rn");
  const instance = await launch(app, { data, fresh: true, onboarded: true, env: { ARDIA_NATIVE_OMNIBOX: native ? "1" : "0", ARDIA_NATIVE_NEWTAB: "0" } });
  await instance.eval(`const s = ac.store.getState(); const w = Object.keys(s.windows)[0];
    s.importHistory(s.windows[w].profileId, ${JSON.stringify(history)});
    s.updateSettings({ searchSuggestions: false });
    s.newTab(w, { url: "https://example.com/", background: true });
    s.newTab(w, { url: "https://open.example.net/", background: true });
    return 1;`);
  await sleep(1500);
  return instance;
}

const navState = `(() => { const S = ac.store.getState(); const w = Object.keys(S.windows)[0]; const win = S.windows[w];
  const norm = (u) => { try { const x = new URL(u); const q = x.searchParams.get("q"); return x.origin + x.pathname + (q ? "?q=" + q : ""); } catch { return u; } };
  const active = norm(S.tabs[win.activeTabIds[win.profileId]]?.url ?? "");
  const opened = Object.values(S.tabs).filter((t) => !globalThis.__parityTabs.includes(t.id)).map((t) => \`\${t.windowId === w ? "same" : "other"} \${norm(t.url)}\`).sort();
  return { windows: Object.keys(S.windows).length, active, opened }; })()`;

async function run(instance, script) {
  const states = [];
  if (script.nav) await instance.eval(`globalThis.__parityTabs = Object.keys(ac.store.getState().tabs); return 1;`);
  const opened = await instance.eval(`
    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
    const S = () => ac.store.getState();
    const w = Object.keys(S().windows)[0];
    S().closePanel(w);
    const bar = ${JSON.stringify(script.bar)};
    S().updateSettings({ addressBar: bar === "sidebar" ? "sidebar" : "toolbar", newTabOpens: bar === "newTab" ? "commandBar" : "page" });
    return sleep(300).then(() => {
      if (bar === "newTab") {
        const page = Object.values(S().tabs).find((t) => t.windowId === w && t.url);
        if (page) S().activate(page.id);
        return sleep(500).then(() => ac.runCommand({ command: "newTab", arg: null, windowId: w }));
      }
      S().openPanel(w);
    }).then(() => sleep(900)).then(() => ({ w, ids: ac.omnibox.ids() }));`);
  const id = `${opened.w}:${script.bar === "sidebar" ? "sidebar" : "panel"}`;
  if (!opened.ids.includes(id)) throw new Error(`${instance.data.endsWith("native") ? "native" : "rn"}: no driver ${id} (have ${opened.ids.join(", ")})`);

  for (const [kind, a, b] of script.steps) {
    const call =
      kind === "type" ? `d.type(${JSON.stringify(a)})`
      : kind === "key" ? `d.key(${JSON.stringify(a)}, ${JSON.stringify(b)})`
      : kind === "keys" ? `ac.shell.devTypeKeys(${JSON.stringify(opened.w)}, ${JSON.stringify(a)}, 40)`
      : kind === "select" ? `d.select(${a}, ${b})`
      : "0";
    const s = await instance.eval(`const d = ac.omnibox.get(${JSON.stringify(id)}); return Promise.resolve(${call})
      .then(() => new Promise((r) => setTimeout(r, ${script.nav ? 900 : 300}))).then(() => ${script.nav ? navState : `ac.omnibox.get(${JSON.stringify(id)})?.state() ?? null`});`);
    states.push(script.nav ? s : s ? pick(s) : null);
  }
  if (script.nav) await instance.eval(`const S = ac.store.getState(); const w = Object.keys(S.windows)[0];
    for (const t of Object.values(S.tabs)) if (!globalThis.__parityTabs.includes(t.id)) S.closeTab(t.id);
    for (const id of Object.keys(S.windows)) if (id !== w) S.closeWindow?.(id);
    return new Promise((r) => setTimeout(r, 600)).then(() => 1);`);
  await instance.eval(`const S = ac.store.getState(); const w = Object.keys(S.windows)[0]; S.closePanel(w);
    for (const t of Object.values(S.tabs)) if (t.windowId === w && !t.url && Object.values(S.tabs).filter((x) => x.windowId === w).length > 2) S.closeTab(t.id);
    return 1;`);
  return states;
}

const [rn, native] = await Promise.all([start(false), start(true)]);
let failures = 0;
try {
  for (const [name, script] of Object.entries(scripts)) {
    if (only && !only.includes(name)) continue;
    try {
      const [a, b] = await Promise.all([run(rn, script), run(native, script)]);
      const diffs = [];
      if (name === "the new tab bar lists open tabs") {
        const row = "page:https://open.example.net/ (tab)";
        if (!a[0]?.items.includes(row)) diffs.push(`step 1 missing open tab in rn: ${JSON.stringify(a[0]?.items)}`);
        if (!b[0]?.items.includes(row)) diffs.push(`step 1 missing open tab in native: ${JSON.stringify(b[0]?.items)}`);
      }
      a.forEach((sa, i) => {
        const sb = b[i];
        for (const key of Object.keys(sa ?? {})) {
          const va = JSON.stringify(sa?.[key]), vb = JSON.stringify(sb?.[key]);
          if (va !== vb) diffs.push(`step ${i + 1} ${JSON.stringify(script.steps[i])} ${key}: rn ${va} native ${vb}`);
        }
      });
      if (diffs.length) {
        failures++;
        console.log(`FAIL ${name}`);
        for (const d of diffs.slice(0, 8)) console.log(`  ${d}`);
      } else console.log(`PASS ${name}${script.nav ? `  ${JSON.stringify(b[b.length - 1])}` : ""}`);
    } catch (e) {
      failures++;
      console.log(`FAIL ${name}: ${e.message.split("\n")[0]}`);
    }
  }
} finally {
  await Promise.all([rn.quit(), native.quit()]);
}
console.log(failures ? `${failures} scripts differ` : "every script matches");
process.exit(failures ? 1 : 0);

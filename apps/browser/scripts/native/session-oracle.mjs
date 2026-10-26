#!/usr/bin/env node
import { existsSync, readFileSync } from "node:fs";
import { registerHooks } from "node:module";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HELP = `usage: node scripts/native/session-oracle.mjs <data folder> [--now <ms>] [--seed <n>]

Loads <data folder>/session.json and downloads.json the way the app does today
(persist.ts loadSession, then the store's hydrate) and prints what persist.ts
would write back: {"memory": {launch, counter, now}, "memoryAfter", "launchBackdrop",
"session", "sessionText", "downloads", "downloadsText"}, as canonical JSON (keys sorted;
the two texts keep persist.ts's own key order). The Swift importer
(solara-store session-oracle) given the same memory must print the same bytes.
The folder is only read.`;

const args = process.argv.slice(2);
if (!args.length || args.includes("--help")) {
  console.log(HELP);
  process.exit(args.length ? 0 : 2);
}
const option = (name, fallback) => {
  const at = args.indexOf(name);
  if (at < 0) return fallback;
  const value = args[at + 1];
  args.splice(at, 2);
  return value;
};
const now = Number(option("--now", String(Date.UTC(2026, 9, 26, 12))));
const seed = Number(option("--seed", "24301"));
const folder = resolve(args[0]);
const app = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

let state = seed;
Math.random = () => {
  state = (state + 0x6d2b79f5) | 0;
  let t = Math.imul(state ^ (state >>> 15), 1 | state);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
};
Date.now = () => now;
globalThis.__DEV__ = false;

await import(pathToFileURL(join(app, "src/test-loader.mjs")).href);
registerHooks({
  load(url, context, next) {
    const loaded = next(url, context);
    const extra = url.endsWith("/src/lib/persist.ts")
      ? "globalThis.__oracleDocs = DOCS;"
      : url.endsWith("/src/store/model.ts")
        ? "globalThis.__oracleModel = { read: () => ({ launch, counter, navSeq }) };"
        : null;
    if (!extra || loaded.source == null) return loaded;
    const source = typeof loaded.source === "string" ? loaded.source : new TextDecoder().decode(loaded.source);
    return { ...loaded, source: `${source}\n${extra}\n` };
  },
});

const { docs } = await import(pathToFileURL(join(app, "src/test-native/shell.ts")).href);
for (const name of ["session.json", "downloads.json"]) {
  const file = join(folder, name);
  if (existsSync(file)) docs.set(name, readFileSync(file, "utf8"));
}
const { useBrowser } = await import(pathToFileURL(join(app, "src/store/browser.ts")).href);
const { loadSession } = await import(pathToFileURL(join(app, "src/lib/persist.ts")).href);
const { launchBackdrop } = await import(pathToFileURL(join(app, "src/lib/launchBackdrop.ts")).href);
const memory = { ...globalThis.__oracleModel.read(), now };
useBrowser.getState().hydrate(loadSession() ?? {});
const s = useBrowser.getState();
const [downloadsDoc, sessionDoc] = globalThis.__oracleDocs;
const focused = s.ui.focusOrder.find((id) => s.windows[id] && !s.windows[id].incognito && s.windows[id].kind !== "small") ?? null;

const canonical = (value) =>
  Array.isArray(value)
    ? `[${value.map(canonical).join(",")}]`
    : value && typeof value === "object"
      ? `{${Object.keys(value)
          .filter((k) => value[k] !== undefined)
          .sort()
          .map((k) => `${JSON.stringify(k)}:${canonical(value[k])}`)
          .join(",")}}`
      : JSON.stringify(value);

const after = globalThis.__oracleModel.read();
const sessionText = sessionDoc.json(s);
const downloadsText = downloadsDoc.json(s);
process.stdout.write(
  canonical({
    memory,
    memoryAfter: { counter: after.counter, navSeq: after.navSeq },
    launchBackdrop: launchBackdrop(s, focused) ?? null,
    launchBackdropText: JSON.stringify(launchBackdrop(s, focused) ?? null),
    session: JSON.parse(sessionText),
    sessionText,
    downloads: JSON.parse(downloadsText),
    downloadsText,
  }) + "\n",
);

#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HELP = `usage: node scripts/native/oracle-check.mjs <solara-store binary> <data folder | folder of data folders>...

Runs session-oracle.mjs (the JS loader) and solara-store session-oracle (the Swift importer) on each data
folder with the same clock and id counter, once straight from the files and once through a scratch
solara.sqlite (--via-db), and fails unless the outputs are identical. Both sides also print the documents' own
text; a difference only in key order is reported but doesn't fail, since no reader depends on it. A folder is
searched one level down for data folders (any folder holding session.json, downloads.json or oracle.json).
A data folder's oracle.json can declare an expected difference: {"jsFails": "why"} when the JS loader
throws (Swift must still load it), {"wellFormed": "why"} when JS keeps lone surrogates that Swift
writes as U+FFFD, or {"normalizes": "why"} when Swift drops an unreadable value JS carries (windows,
tabs, settings and downloads must still match). No data folders at all is a failure.`;

const args = process.argv.slice(2);
if (args.length < 2 || args.includes("--help")) {
  console.log(HELP);
  process.exit(args.includes("--help") ? 0 : 2);
}
const [binary, ...roots] = args;
const here = dirname(fileURLToPath(import.meta.url));
const app = resolve(here, "../..");
const markers = ["session.json", "downloads.json", "oracle.json"];
const folders = roots.flatMap((root) => {
  const full = resolve(root);
  const has = (dir) => readdirSync(dir).some((name) => markers.includes(name));
  if (has(full)) return [full];
  return readdirSync(full).map((name) => join(full, name)).filter((dir) => statSync(dir).isDirectory() && has(dir));
});
const expectation = (folder) => (existsSync(join(folder, "oracle.json")) ? JSON.parse(readFileSync(join(folder, "oracle.json"), "utf8")) : {});
const fixSurrogates = (v) =>
  typeof v === "string"
    ? v.toWellFormed()
    : Array.isArray(v)
      ? v.map(fixSurrogates)
      : v && typeof v === "object"
        ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k.toWellFormed(), k.endsWith("Text") ? JSON.stringify(fixSurrogates(JSON.parse(x))) : fixSurrogates(x)]))
        : v;
const wellFormed = (text) => canonical(fixSurrogates(JSON.parse(text)));
const kept = (text) => {
  const { session, downloads } = JSON.parse(text);
  return canonical({ windows: session.windows, tabs: session.tabs, settings: session.settings, downloads });
};
const withoutTexts = (text) => {
  const { sessionText, downloadsText, launchBackdropText, ...rest } = JSON.parse(text);
  return canonical(rest);
};
const canonical = (value) =>
  Array.isArray(value)
    ? `[${value.map(canonical).join(",")}]`
    : value && typeof value === "object"
      ? `{${Object.keys(value)
          .sort()
          .map((k) => `${JSON.stringify(k)}:${canonical(value[k])}`)
          .join(",")}}`
      : JSON.stringify(value);

function firstDifference(a, b) {
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) if (a[i] !== b[i]) return i;
  return a.length === b.length ? -1 : n;
}

function runSwift(folder, memory, launchBackdropText, extra) {
  return spawnSync(
    binary,
    [
      "session-oracle",
      folder,
      "--now",
      String(memory.now),
      "--launch",
      memory.launch,
      "--counter",
      String(memory.counter),
      "--nav-seq",
      String(memory.navSeq),
      "--launch-backdrop",
      launchBackdropText,
      ...extra,
    ],
    { encoding: "utf8", maxBuffer: 1 << 28 },
  );
}

let failed = 0;
let orderOnly = 0;
for (const folder of folders) {
  const expected = expectation(folder);
  const js = spawnSync(process.execPath, ["--no-warnings", join(here, "session-oracle.mjs"), folder], { cwd: app, encoding: "utf8", maxBuffer: 1 << 28 });
  if (expected.jsFails) {
    const swift = runSwift(folder, { now: 0, launch: "x", counter: 0, navSeq: 0 }, "null", []);
    if (js.status === 0 || swift.status !== 0) {
      failed++;
      console.log(`${folder}: expected the JS loader to fail and Swift to load it (${expected.jsFails}); js exit ${js.status}, swift exit ${swift.status}\n${swift.stderr}`);
    } else {
      console.log(`${folder}: JS fails as expected, Swift loads it`);
    }
    continue;
  }
  if (js.status !== 0) {
    failed++;
    console.log(`${folder}: the JS oracle failed\n${js.stderr}`);
    continue;
  }
  const parsed = JSON.parse(js.stdout);
  const want = expected.wellFormed ? wellFormed(js.stdout) : js.stdout;
  for (const extra of [[], ["--via-db"]]) {
    const label = extra.length ? " via the database" : "";
    const swift = runSwift(folder, parsed.memory, parsed.launchBackdropText, extra);
    if (swift.status !== 0) {
      failed++;
      console.log(`${folder}${label}: the Swift importer failed\n${swift.stderr}`);
      continue;
    }
    if (expected.normalizes) {
      const same = kept(js.stdout) === kept(swift.stdout);
      if (!same) failed++;
      console.log(`${folder}${label}: ${same ? "windows, tabs, settings and downloads identical; the rest differs as declared" : "windows, tabs, settings or downloads differ"} (${expected.normalizes})`);
      continue;
    }
    const got = expected.wellFormed ? wellFormed(swift.stdout) : swift.stdout;
    const at = firstDifference(want, got);
    if (at < 0) {
      console.log(`${folder}${label}: identical, key order included (${js.stdout.length} bytes)${expected.wellFormed ? " after U+FFFD for lone surrogates" : ""}`);
      continue;
    }
    const content = firstDifference(withoutTexts(want), withoutTexts(got)) < 0;
    if (content) {
      orderOnly++;
      console.log(`${folder}${label}: identical content; key order differs at byte ${at} of the texts\n  js:    …${want.slice(Math.max(0, at - 120), at + 160)}\n  swift: …${got.slice(Math.max(0, at - 120), at + 160)}`);
      continue;
    }
    failed++;
    console.log(`${folder}${label}: differs at byte ${at}\n  js:    …${want.slice(Math.max(0, at - 120), at + 160)}\n  swift: …${got.slice(Math.max(0, at - 120), at + 160)}`);
  }
}
console.log(`${folders.length} folders: ${failed} differing checks, ${orderOnly} checks identical except key order`);
process.exit(failed || !folders.length ? 1 : 0);

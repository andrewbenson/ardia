#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { readdirSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HELP = `usage: node scripts/native/oracle-check.mjs <solara-store binary> <data folder | folder of data folders>...

Runs session-oracle.mjs (the JS loader) and solara-store session-oracle (the Swift importer) on each data
folder with the same clock and id counter, and fails unless their outputs are byte-identical. A folder
holding no session.json is searched one level down for folders that do.`;

const args = process.argv.slice(2);
if (args.length < 2 || args.includes("--help")) {
  console.log(HELP);
  process.exit(args.includes("--help") ? 0 : 2);
}
const [binary, ...roots] = args;
const here = dirname(fileURLToPath(import.meta.url));
const app = resolve(here, "../..");
const folders = roots.flatMap((root) => {
  const full = resolve(root);
  const has = (dir) => readdirSync(dir).includes("session.json");
  if (has(full)) return [full];
  return readdirSync(full).map((name) => join(full, name)).filter((dir) => statSync(dir).isDirectory() && has(dir));
});

function firstDifference(a, b) {
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) if (a[i] !== b[i]) return i;
  return a.length === b.length ? -1 : n;
}

let failed = 0;
for (const folder of folders) {
  const js = spawnSync(process.execPath, ["--no-warnings", join(here, "session-oracle.mjs"), folder], { cwd: app, encoding: "utf8", maxBuffer: 1 << 28 });
  if (js.status !== 0) {
    failed++;
    console.log(`${folder}: the JS oracle failed\n${js.stderr}`);
    continue;
  }
  const expected = JSON.parse(js.stdout);
  const swift = spawnSync(
    binary,
    [
      "session-oracle",
      folder,
      "--now",
      String(expected.memory.now),
      "--launch",
      expected.memory.launch,
      "--counter",
      String(expected.memory.counter),
      "--nav-seq",
      String(expected.memory.navSeq),
      "--launch-backdrop",
      JSON.stringify(expected.launchBackdrop),
    ],
    { encoding: "utf8", maxBuffer: 1 << 28 },
  );
  if (swift.status !== 0) {
    failed++;
    console.log(`${folder}: the Swift importer failed\n${swift.stderr}`);
    continue;
  }
  const at = firstDifference(js.stdout, swift.stdout);
  if (at < 0) {
    console.log(`${folder}: identical (${js.stdout.length} bytes)`);
    continue;
  }
  failed++;
  console.log(`${folder}: differs at byte ${at}\n  js:    …${js.stdout.slice(Math.max(0, at - 120), at + 160)}\n  swift: …${swift.stdout.slice(Math.max(0, at - 120), at + 160)}`);
}
console.log(`${folders.length - failed} of ${folders.length} identical`);
process.exit(failed ? 1 : 0);

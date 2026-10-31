#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { launch, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const runsAt = args.indexOf("--runs");
const RUNS = runsAt >= 0 ? Number(args[runsAt + 1]) : 6;
const variantsAt = args.indexOf("--variants");
const ONLY = variantsAt >= 0 ? args[variantsAt + 1].split(",") : null;
const [app, scratch] = args
  .filter((a, i) => !a.startsWith("--") && i !== runsAt + 1 && i !== variantsAt + 1)
  .map((p) => path.resolve(p));
if (!app || !scratch || app.startsWith("/Applications/")) {
  console.log("usage: settings-bench.mjs <Solara.app under apps/browser/build-*> <scratch dir> [--runs N]");
  process.exit(64);
}

const PANES = ["tabs", "appearance", "privacy", "search", "advanced", "engines"];
const VARIANTS = [
  { name: "native", env: {} },
  { name: "native-unwarmed", env: { SOLARA_SETTINGS_PREWARM: "0" } },
].filter((v) => !ONLY || ONLY.includes(v.name));
const SETTLE_MS = 8000;

const inApp = (inst, body) => inst.eval(body);

const timingsCall = () => "return globalThis.expo.modules.SolaraSettings.devTimings().then((t) => JSON.parse(t))";

async function waitFor(inst, variant, pane, since, seen, timeout = 10000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    seen.push(...(await inApp(inst, timingsCall(variant))));
    const hit = seen.find((m) => m.pane === pane && m.appeared >= since);
    if (hit) return hit;
    await sleep(50);
  }
  return null;
}

function footprint(pid) {
  try {
    const out = execFileSync("footprint", ["-p", String(pid), "--noCategories"], { encoding: "utf8", timeout: 20000 });
    const match = out.match(/phys_footprint:\s*([\d.]+)\s*([KMG])B/i) ?? out.match(/Footprint:\s*([\d.]+)\s*([KMG])B/i);
    if (!match) return null;
    return Number(match[1]) * { K: 1 / 1024, M: 1, G: 1024 }[match[2].toUpperCase()];
  } catch {
    return null;
  }
}

async function oneRun(variant, run) {
  const data = path.join(scratch, `${variant.name}-${run}`, "data");
  fs.rmSync(path.dirname(data), { recursive: true, force: true });
  const inst = await launch(app, { data, js: "none", probe: true, onboarded: true, env: variant.env });
  const result = { variant: variant.name, run, panes: {} };
  const seen = [];
  try {
    await sleep(SETTLE_MS);
    result.memoryBefore = footprint(inst.pid);
    const opened = await inApp(inst, `const t = Date.now(); ac.openSettings("general"); return t;`);
    const general = await waitFor(inst, variant.name, "general", opened, seen);
    result.open = general ? { laidOut: general.appeared - opened, committed: general.committed - opened } : null;
    await sleep(1500);
    for (let round = 0; round < 2; round++) {
      for (const pane of PANES) {
        const at = await inApp(inst, `const t = Date.now(); ac.openSettings(${JSON.stringify(pane)}); return t;`);
        const hit = await waitFor(inst, variant.name, pane, at, seen);
        (result.panes[pane] ??= []).push(hit ? hit.committed - at : null);
        await sleep(400);
      }
    }
    await inApp(inst, `ac.openSettings("general"); return true`);
    await sleep(2000);
    result.memoryWithSettings = footprint(inst.pid);
  } finally {
    await inst.quit().catch(() => {});
  }
  return result;
}

const median = (xs) => {
  const v = xs.filter((x) => typeof x === "number").sort((a, b) => a - b);
  if (!v.length) return null;
  const mid = Math.floor(v.length / 2);
  return v.length % 2 ? v[mid] : (v[mid - 1] + v[mid]) / 2;
};

fs.mkdirSync(scratch, { recursive: true });
const results = [];
for (let run = 0; run < RUNS; run++) {
  for (const variant of run % 2 ? [...VARIANTS].reverse() : VARIANTS) {
    const r = await oneRun(variant, run);
    results.push(r);
    console.log(`${variant.name} #${run}: open ${r.open?.committed?.toFixed(0) ?? "—"} ms, footprint ${r.memoryBefore?.toFixed(0) ?? "—"} → ${r.memoryWithSettings?.toFixed(0) ?? "—"} MB`);
  }
}
fs.writeFileSync(path.join(scratch, "settings-bench.json"), JSON.stringify(results, null, 2));

const f = (x, d = 0) => (x == null || !Number.isFinite(x) ? "—" : x.toFixed(d));
console.log("\nvariant | open → laid out | open → committed | pane switch (median, max) | footprint with Settings | Settings' share | missing");
for (const variant of VARIANTS.map((v) => v.name)) {
  const mine = results.filter((r) => r.variant === variant);
  const switches = mine.flatMap((r) => Object.values(r.panes).flat());
  const shares = mine.map((r) => (r.memoryWithSettings != null && r.memoryBefore != null ? r.memoryWithSettings - r.memoryBefore : null));
  const missing = switches.filter((x) => x == null).length + mine.filter((r) => !r.open).length;
  const max = Math.max(...switches.filter((x) => typeof x === "number"));
  console.log(
    `${variant} | ${f(median(mine.map((r) => r.open?.laidOut)))} ms | ${f(median(mine.map((r) => r.open?.committed)))} ms | ${f(median(switches))} ms, ${f(max)} ms | ${f(median(mine.map((r) => r.memoryWithSettings)))} MB | ${f(median(shares), 1)} MB | ${missing}`,
  );
}

console.log(`\npane switch by pane (median ms, first visit / second) | ${VARIANTS.map((v) => v.name).join(" | ")}`);
for (const pane of PANES) {
  const cells = VARIANTS.map((v) => {
    const mine = results.filter((r) => r.variant === v.name);
    return [0, 1].map((round) => f(median(mine.map((r) => r.panes[pane]?.[round])))).join(" / ");
  });
  console.log(`${pane} | ${cells.join(" | ")}`);
}

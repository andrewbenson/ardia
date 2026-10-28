#!/usr/bin/env node
// Captures every onboarding page, in light and dark, from the RN overlay and from the native one in the same Debug
// build (ARDIA_NATIVE_ONBOARDING=0 for RN), for a side-by-side diff. Each page is reached with the model's own go(step, sub)
// and captured with screencapture -l on its window after it settles (devSnapshotWindow drops shadows and doubles text
// opacity, so it can't compare the two).
//
//   node packages/settings/scripts/onboarding-compare.mjs <Debug Solara.app> <out dir> [--variants rn,native]
//        [--pages intro:0,layout:1] [--settle MS]
//
// Writes <out>/<variant>/<appearance>/<step>-<sub>.png.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { launch, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const option = (name) => {
  const at = args.indexOf(name);
  return at >= 0 ? args[at + 1] : null;
};
const positional = args.filter((a, i) => !a.startsWith("--") && !args[i - 1]?.startsWith("--"));
const [app, out] = positional.map((p) => path.resolve(p));
if (!app || !out || app.startsWith("/Applications/")) {
  console.log("usage: onboarding-compare.mjs <Debug Solara.app under apps/browser/build-*> <out dir> [--variants rn,native] [--pages step:sub,…] [--settle MS]");
  process.exit(64);
}
const VARIANTS = (option("--variants") ?? "rn,native").split(",");
const SETTLE = Number(option("--settle") ?? 1800);
const COUNTS = { intro: 1, source: 1, layout: 3, tabs: 6, look: 4, searchPrivacy: 3, pins: 1, home: 2, outro: 1 };
const PAGES = option("--pages")?.split(",") ?? Object.entries(COUNTS).flatMap(([step, n]) => Array.from({ length: n }, (_, sub) => `${step}:${sub}`));
const inApp = (inst, body) => inst.eval(body);

for (const variant of VARIANTS) {
  const data = path.join(out, `${variant}-data`);
  fs.rmSync(data, { recursive: true, force: true });
  const env = { ARDIA_DRAW_WINDOWS: "1", ARDIA_ONBOARDING: "1", ARDIA_NATIVE_ONBOARDING: variant === "native" ? "1" : "0" };
  const inst = await launch(app, { data, env });
  try {
    await inst.ready({ test: "return !!globalThis.acOnboarding?.store.getState().windowId" });
    await sleep(2500);
    for (const appearance of ["light", "dark"]) {
      await inApp(inst, `ac.store.getState().updateSettings({ appearance: ${JSON.stringify(appearance)} }); return true`);
      await sleep(800);
      const dir = path.join(out, variant, appearance);
      fs.mkdirSync(dir, { recursive: true });
      for (const page of PAGES) {
        const [step, sub] = page.split(":");
        const go = variant === "native"
          ? `globalThis.expo.modules.SolaraSettings.devOnboarding("go", ${JSON.stringify(`${step}:${sub}`)})`
          : `acOnboarding.store.getState().go(${JSON.stringify(step)}, ${Number(sub)})`;
        await inApp(inst, `${go}; return true`);
        await sleep(SETTLE);
        const file = path.join(dir, `${step}-${sub}.png`);
        const number = await inApp(inst, "return globalThis.expo.modules.ArdiaCEF.chromeWindows().then((ws) => ws.find((w) => w.hasRoot)?.window)");
        let saved = false;
        try {
          execFileSync("timeout", ["20", "screencapture", "-x", "-o", "-l", String(number), file]);
          saved = fs.existsSync(file);
        } catch {}
        console.log(`${variant} ${appearance} ${page}: ${saved ? "saved" : "FAILED"}`);
      }
    }
  } finally {
    await inst.quit().catch(() => {});
  }
}

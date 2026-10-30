const HELP = `Records the browser's launch backdrop for SolaraStore's differential test.

  node native/SolaraKit/Scripts/launch-backdrop-fixtures.mts [--out <file>] [--verify]

Runs the production launchBackdrop function over fixture profiles, custom looks, appearance modes and
space appearance settings. --verify compares regenerated output without changing the accepted fixture.`;

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

await import("../../../apps/browser/src/test-loader.mjs");
const { launchBackdrop } = await import("../../../apps/browser/src/lib/launchBackdrop.ts");
const { PROFILE_COLORS } = await import("../../../apps/browser/src/lib/theme.ts");
const { startingTheme } = await import("../../../apps/browser/src/lib/profileTheme.ts");

const args = process.argv.slice(2);
if (args.includes("--help") || args.includes("-h")) {
  console.log(HELP);
  process.exit(0);
}
const outFlag = args.indexOf("--out");
const output = outFlag < 0 ? join(dirname(fileURLToPath(import.meta.url)), "../Tests/Fixtures/launch-backdrop.json") : args[outFlag + 1]!;
const stop = (r: number, g: number, b: number, a = 1) => ({ x: 0.5, y: 0.5, color: { r, g, b, a } });
const look = (stops: ReturnType<typeof stop>[], texture = "grain", intensity = 0.6, translucency = 1, grain = 0.5, angle?: number) =>
  ({ stops, texture, intensity, translucency, grain, ...(angle === undefined ? {} : { angle }) });
const cream = look([stop(1, 0.94, 0.8)]);
const night = look([stop(0.015, 0.025, 0.05)], "denim", 0.3, 0.2, 0.8, 280);
const gradient = look([stop(0.3, 0.75, 0.45), stop(0.85, 0.3, 0.65), stop(0.2, 0.4, 0.9, 0.8)], "sand", 0.8, 0.65, 0.6, 32);
const wide = look([stop(-0.25, 1.2, 0.4), stop(1.5, -0.3, 0.75)], "tweed", 1, 0, 1, 315);
const themes = [
  null,
  { ...cream, mode: "auto" },
  { ...cream, mode: "light" },
  { ...cream, mode: "dark" },
  { ...night, mode: "auto" },
  { ...gradient, mode: "auto" },
  { ...wide, mode: "auto" },
  { ...cream, mode: "auto", dark: night },
  { ...gradient, mode: "light", dark: { ...night, angle: undefined } },
  { ...startingTheme("#4691C3"), mode: "auto" },
];
const cases: unknown[] = [];
for (const color of [...Object.keys(PROFILE_COLORS), "unknown"]) {
  for (const [themeIndex, theme] of themes.entries()) {
    for (const appDark of [false, true]) {
      for (const spacesFollowAppearance of [false, true]) {
        const profile = { id: "default", name: "Fixture", color, ...(theme ? { theme } : {}) };
        const state = {
          profiles: { default: profile },
          windows: { window: { id: "window", profileId: "default", incognito: false, kind: "normal" } },
          settings: { spacesFollowAppearance },
          ui: { appDark },
        };
        cases.push({ name: `${color}/${themeIndex}/${appDark}/${spacesFollowAppearance}`, profile, appDark, spacesFollowAppearance, expected: launchBackdrop(state as never, "window") });
      }
    }
  }
}
const text = `{"cases":[\n${cases.map((c) => JSON.stringify(c)).join(",\n")}\n]}\n`;
if (args.includes("--verify")) {
  if (readFileSync(output, "utf8") !== text) throw new Error("launch backdrop fixture changed");
} else {
  mkdirSync(dirname(output), { recursive: true });
  writeFileSync(output, text);
}
console.log(`${cases.length} launch backdrop cases ${args.includes("--verify") ? "verified" : "recorded"}`);
process.exit(0);

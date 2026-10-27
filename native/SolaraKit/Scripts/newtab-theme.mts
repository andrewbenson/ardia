const HELP = `Writes SolaraUI's New Tab theme tokens, Sources/SolaraUI/NewTab/NewTabThemeTokens.swift, from the dark and
light themes in apps/browser/src/lib/theme.ts.

  node native/SolaraKit/Scripts/newtab-theme.mts           write the file
  node native/SolaraKit/Scripts/newtab-theme.mts --check   exit 1 if the file is out of date

Run it after any edit to those two themes. The live values still come from JS (profile themes override them);
these are what the hero shows before JS has sent a theme, and what the tests use.`;

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

if (process.argv.includes("-h") || process.argv.includes("--help")) {
  console.log(HELP);
  process.exit(0);
}

const here = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(here, "../../../apps/browser/src/lib/theme.ts"), "utf8");
const keys = [
  "textPrimary", "textSecondary", "textTertiary", "placeholder", "selection", "chipBorder", "chipText", "rowHover", "rowSelected",
  "commandBarSelected", "commandBarHover", "goButton", "goButtonText", "goButtonIdle", "ntpBarSolid", "ntpBarBorder", "toolbarHover",
  "toolbarPressed", "icon", "iconDisabled",
];

function theme(name: string): Record<string, string> {
  const start = source.search(new RegExp(`^const ${name}(: [^=]+)? = \\{$`, "m"));
  if (start < 0) throw new Error(`no \`const ${name} = {\` in theme.ts`);
  const end = source.indexOf("\n};", start);
  const body = source.slice(start, end);
  const out: Record<string, string> = {};
  for (const m of body.matchAll(/^ {2}(\w+): "([^"]*)",$/gm)) out[m[1]!] = m[2]!;
  for (const key of keys) if (!(key in out)) throw new Error(`theme.ts's ${name} has no string ${key}`);
  return out;
}

const swiftString = (s: string) => JSON.stringify(s);
const table = (name: string, t: Record<string, string>) =>
  [`  static let ${name}: [String: String] = [`, ...keys.map((k) => `    "${k}": ${swiftString(t[k]!)},`), "  ]"].join("\n");

const text = [
  "enum NewTabThemeTokens {",
  `  static let keys = [${keys.map((k) => `"${k}"`).join(", ")}]`,
  "",
  table("dark", theme("dark")),
  "",
  table("light", theme("light")),
  "}",
  "",
].join("\n");

const out = join(here, "../Sources/SolaraUI/NewTab/NewTabThemeTokens.swift");
if (process.argv.includes("--check")) {
  let current = "";
  try {
    current = readFileSync(out, "utf8");
  } catch {}
  if (current !== text) {
    console.error(`${out} is out of date: run node native/SolaraKit/Scripts/newtab-theme.mts`);
    process.exit(1);
  }
  process.exit(0);
}
writeFileSync(out, text);

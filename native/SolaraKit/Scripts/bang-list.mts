const HELP = `Writes SolaraOmnibox's bundled bang list, Sources/SolaraOmnibox/BangList.swift, from packages/core/src/bangList.ts.

  node native/SolaraKit/Scripts/bang-list.mts

Run it after packages/core/scripts/bangs.ts refreshes bangList.ts. The lists go in as raw string literals,
so the target needs no resource bundle.`;

import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { BANG_LIST, BANG_LIST_ETAG, BANG_LIST_GENERATED_AT, BANG_LIST_UNICODE } from "../../../packages/core/src/bangList.ts";

if (process.argv.includes("-h") || process.argv.includes("--help")) {
  console.log(HELP);
  process.exit(0);
}

const raw = (text: string) => {
  if (text.includes("\r")) throw new Error("a carriage return would not survive a Swift multi-line literal");
  let hashes = "#";
  while (text.includes(`"${hashes}`) || text.includes(`\\${hashes}`)) hashes += "#";
  return `${hashes}"""\n${text}\n"""${hashes}`;
};
const out = join(dirname(fileURLToPath(import.meta.url)), "../Sources/SolaraOmnibox/BangList.swift");
writeFileSync(
  out,
  [
    `let bundledBangListEtag = ${raw(BANG_LIST_ETAG)}`,
    `let bundledBangListGeneratedAt = ${raw(BANG_LIST_GENERATED_AT)}`,
    `let bundledBangList = ${raw(BANG_LIST)}`,
    `let bundledBangListUnicode = ${raw(BANG_LIST_UNICODE)}`,
    "",
  ].join("\n\n"),
);
console.log(`${out}: ${BANG_LIST.split("\n").length} + ${BANG_LIST_UNICODE.split("\n").length} bangs`);

import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";

const root = new URL("../../../", import.meta.url);
const pinsFile = new URL("native/SolaraKit/Tests/SolaraSyncTests/sources.json", root);

export const sourceHash = (path) => createHash("sha256").update(readFileSync(new URL(path, root))).digest("hex");

function readPins() {
  try {
    return JSON.parse(readFileSync(pinsFile, "utf8"));
  } catch {
    return {};
  }
}

export function pinSources(fixture, paths) {
  const pins = readPins();
  pins[fixture] = Object.fromEntries(paths.map((path) => [path, sourceHash(path)]));
  writeFileSync(pinsFile, JSON.stringify(Object.fromEntries(Object.entries(pins).sort(([a], [b]) => (a < b ? -1 : 1))), null, 2) + "\n");
}

export function changedSources(fixture) {
  const pinned = readPins()[fixture];
  if (!pinned) return ["(no pins recorded)"];
  return Object.entries(pinned)
    .filter(([path, hash]) => sourceHash(path) !== hash)
    .map(([path]) => path);
}

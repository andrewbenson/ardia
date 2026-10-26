import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const script = fileURLToPath(new URL("../identity.sh", import.meta.url));
let settings;

function readSettings() {
  const out = execFileSync("bash", ["-c", '. "$1" && printf "%s\\n" "$ac_identity_settings"', "identity", script], { encoding: "utf8", maxBuffer: 64 << 20 });
  const found = new Map();
  for (const [, key, value] of out.matchAll(/^ *(\w+) = (.*)$/gm)) if (!found.has(key)) found.set(key, value);
  return found;
}

export function identity(key) {
  settings ??= readSettings();
  const value = settings.get(key);
  if (!value) throw new Error(`the app's identity has no ${key} (scripts/identity.sh)`);
  return value;
}

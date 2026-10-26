import { spawn, spawnSync } from "node:child_process";
import { closeSync, mkdtempSync, openSync, readSync, rmSync, writeSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const binary = process.env.SOLARA_STORE_BIN;
if (!binary) throw new Error("bridge-loopback: set SOLARA_STORE_BIN to a built solara-store");

const dir = mkdtempSync(join(process.env.TMPDIR ?? tmpdir(), "solara-loopback-"));
const requests = join(dir, "requests");
const responses = join(dir, "responses");
spawnSync("mkfifo", [requests, responses]);
const child = spawn("sh", ["-c", 'exec "$0" serve --launch loop < "$1" > "$2"', binary, requests, responses], { stdio: ["ignore", "ignore", "inherit"] });
child.unref();
const writer = openSync(requests, "w");
const reader = openSync(responses, "r");
let pending = "";

function ask(request) {
  writeSync(writer, JSON.stringify({ ...request, now: Date.now() }) + "\n");
  const chunk = Buffer.alloc(1 << 16);
  while (!pending.includes("\n")) {
    const read = readSync(reader, chunk, 0, chunk.length, null);
    if (read === 0) throw new Error("bridge-loopback: solara-store serve exited");
    pending += chunk.toString("utf8", 0, read);
  }
  const at = pending.indexOf("\n");
  const line = pending.slice(0, at);
  pending = pending.slice(at + 1);
  return line;
}

process.on("exit", () => {
  try {
    closeSync(writer);
    closeSync(reader);
  } catch {}
  child.kill();
  rmSync(dir, { recursive: true, force: true });
});

globalThis.acTestNativeModules = {
  ...(globalThis.acTestNativeModules ?? {}),
  ArdiaStore: {
    status: () => ({ active: true, scope: "everything" }),
    snapshot: () => ask({ op: "snapshot" }),
    dispatch: (commandJSON, sinceRev) => ask({ op: "dispatch", commands: JSON.parse(commandJSON), sinceRev }),
    catchUp: (sinceRev) => ask({ op: "catchUp", sinceRev }),
    flush: () => true,
    addListener: () => ({ remove() {} }),
  },
};

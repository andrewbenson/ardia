import { execFileSync } from "node:child_process";
import { appendFileSync, existsSync, readFileSync, rmSync } from "node:fs";
import { fileURLToPath } from "node:url";

const run = (cmd, args) => { try { return execFileSync(cmd, args, { encoding: "utf8", timeout: 3000 }); } catch { return ""; } };
const alive = (pid) => { try { process.kill(pid, 0); return true; } catch (e) { return e.code === "EPERM"; } };
const folded = (path) => path.normalize("NFC").toLowerCase();
export const executableOf = (pid) => run("ps", ["-ww", "-o", "comm=", "-p", String(pid)]).trim();

export function parseFront(info) {
  const pid = Number(/\bpid = (\d+)/.exec(info)?.[1] ?? 0);
  return pid ? { pid, executable: /executable path="([^"]*)"/.exec(info)?.[1] ?? "", name: /^"([^"]*)"/m.exec(info.trim())?.[1] ?? "" } : null;
}
export const secureInputPid = (ioreg) => Number(/"kCGSSessionSecureInputPID"=(\d+)/.exec(ioreg)?.[1] ?? 0) || null;

export function readState(text) {
  const state = { owners: new Set(), watched: new Map(), binaries: new Set(), frontBefore: null };
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    let entry;
    try { entry = JSON.parse(line); } catch { continue; }
    if (entry.owner) state.owners.add(entry.owner);
    if (entry.binary) state.binaries.add(folded(entry.binary));
    if (entry.watch) state.watched.set(entry.watch, entry.data ?? null);
    if (entry.unwatch) state.watched.delete(entry.unwatch);
    if (entry.frontBefore !== undefined && state.frontBefore === null) state.frontBefore = entry.frontBefore;
  }
  return state;
}

export const launchedBinary = (state, executable) => !!executable && state.binaries.has(folded(executable));
export function violation(state, front, secure) {
  if (front && launchedBinary(state, front.executable)) return { pid: front.pid, executable: front.executable, data: state.watched.get(front.pid) ?? null, what: "became the frontmost, active app" };
  if (secure && state.watched.has(secure.pid) && launchedBinary(state, secure.executable))
    return { pid: secure.pid, executable: secure.executable, data: state.watched.get(secure.pid), what: "holds macOS Secure Event Input" };
  return null;
}

export const stillNeeded = (state, isAlive = alive) => [...state.owners, ...state.watched.keys()].some(isAlive);
export function prune(state, isAlive = alive, programOf = executableOf) {
  const runsOther = (pid, ours) => {
    const program = programOf(pid);
    return !!program && !ours(program);
  };
  for (const pid of state.watched.keys()) if (!isAlive(pid) || runsOther(pid, (p) => launchedBinary(state, p))) state.watched.delete(pid);
  for (const pid of state.owners) if (!isAlive(pid) || runsOther(pid, (p) => /(^|\/)node$/.test(p))) state.owners.delete(pid);
  return state;
}

function banner(found, frontBefore) {
  return `\n!!! UI GATE: test instance pid ${found.pid}${found.data ? ` (${found.data})` : ""} ${found.what}.\n` +
    `!!! It was killed at once. Before the launch the owner's frontmost app was ${frontBefore ? `${frontBefore.name || "?"} (pid ${frontBefore.pid})` : "unknown"}.\n` +
    `!!! A test instance must never take the owner's keyboard: find what activated it before running UI tests again.\n\n`;
}

async function stop(pid) {
  try { process.kill(pid, "SIGTERM"); } catch {}
  for (const end = Date.now() + 1500; alive(pid) && Date.now() < end; await new Promise((r) => setTimeout(r, 50)));
  if (alive(pid)) try { process.kill(pid, "SIGKILL"); } catch {}
}

async function main(stateFile, interval) {
  process.stdout.on("error", () => {});
  process.stderr.on("error", () => {});
  const log = `${stateFile}.log`;
  const say = (text) => {
    try { appendFileSync(log, text); } catch {}
    try { process.stderr.write(text); } catch {}
  };
  process.stdout.write("held\n");
  for (let tick = 0; ; tick++) {
    const state = prune(readState(existsSync(stateFile) ? readFileSync(stateFile, "utf8") : ""));
    if (tick > 0 && !stillNeeded(state)) {
      await new Promise((r) => setTimeout(r, interval));
      if (!stillNeeded(prune(readState(existsSync(stateFile) ? readFileSync(stateFile, "utf8") : "")))) break;
      continue;
    }
    const front = parseFront(run("lsappinfo", ["info", run("lsappinfo", ["front"]).trim()]));
    const securePid = secureInputPid(run("ioreg", ["-l", "-w", "0", "-d", "1", "-k", "IOConsoleUsers"]));
    const found = violation(state, front, securePid ? { pid: securePid, executable: executableOf(securePid) } : null);
    if (found && launchedBinary(state, executableOf(found.pid))) {
      await stop(found.pid);
      say(banner(found, state.frontBefore));
      if (found.data) try { appendFileSync(`${found.data}/ui-gate-violation.log`, banner(found, state.frontBefore)); } catch {}
      try { appendFileSync(stateFile, `${JSON.stringify({ violation: found, at: new Date().toISOString() })}\n`); } catch {}
      try { process.stdout.write(`violation ${JSON.stringify(found)}\n`); } catch {}
    }
    await new Promise((r) => setTimeout(r, interval));
  }
  rmSync(stateFile, { force: true });
  rmSync(log, { force: true });
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) await main(process.argv[2], Number(process.argv[3] ?? 500));

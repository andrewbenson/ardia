import { execFileSync } from "node:child_process";
import { appendFileSync, existsSync, readFileSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const run = (cmd, args) => { try { return execFileSync(cmd, args, { encoding: "utf8", timeout: 3000 }); } catch { return ""; } };
const alive = (pid) => { try { process.kill(pid, 0); return true; } catch (e) { return e.code === "EPERM"; } };
const folded = (path) => path.normalize("NFC").toLowerCase();
export const executableOf = (pid) => run("ps", ["-ww", "-o", "comm=", "-p", String(pid)]).trim();

export function parseFront(info) {
  const pid = Number(/\bpid = (\d+)/.exec(info)?.[1] ?? 0);
  return pid ? { pid, executable: /executable path="([^"]*)"/.exec(info)?.[1] ?? "", name: /^"([^"]*)"/m.exec(info.trim())?.[1] ?? "" } : null;
}
export const suppressedLog = (data) => `${data}/secure-input-suppressed.log`;
export function newSuppressed(text, seen) {
  const lines = text.split("\n").filter(Boolean);
  return { lines: lines.slice(seen), seen: lines.length };
}

export function readState(text) {
  const state = { owners: new Set(), watched: new Map(), holds: new Map(), binaries: new Set(), frontBefore: null };
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    let entry;
    try { entry = JSON.parse(line); } catch { continue; }
    if (entry.owner) state.owners.add(entry.owner);
    if (entry.binary) state.binaries.add(folded(entry.binary));
    if (entry.watch) {
      state.watched.set(entry.watch, entry.data ?? null);
      state.holds.set(entry.watch, { at: entry.at ?? null, maxHold: entry.maxHold ?? null, who: entry.who ?? null, by: entry.by ?? null });
    }
    if (entry.unwatch) state.watched.delete(entry.unwatch);
    if (entry.frontBefore !== undefined && state.frontBefore === null) state.frontBefore = entry.frontBefore;
  }
  return state;
}

export const launchedBinary = (state, executable) => !!executable && state.binaries.has(folded(executable));
export function violation(state, front) {
  if (front && launchedBinary(state, front.executable)) return { pid: front.pid, executable: front.executable, data: state.watched.get(front.pid) ?? null, what: "became the frontmost, active app" };
  return null;
}

export const orphanMaxHold = 10;
export const liveMaxHold = 60;
export function overHeld(state, now, firstSeen = new Map(), isAlive = alive) {
  const over = [];
  for (const [pid, data] of state.watched) {
    const hold = state.holds.get(pid) ?? {};
    const since = hold.at ?? firstSeen.get(pid) ?? now;
    const raised = Number(hold.maxHold) > 0 ? Number(hold.maxHold) : 0;
    const launcherAlive = !!hold.by && isAlive(hold.by);
    const minutes = launcherAlive ? Math.max(raised, liveMaxHold) : raised || orphanMaxHold;
    if (now - since > minutes * 60000)
      over.push({ pid, data, who: hold.who ?? "unknown", by: hold.by ?? null, launcherAlive, heldMinutes: Math.floor((now - since) / 60000), maxHold: minutes });
  }
  return over;
}

export function waitingOthers(waiters, key, self, isAlive = alive, commandOf = executableOf) {
  return waiters.filter((w) => w.pid !== self && (!key || w.key !== key) && isAlive(w.pid) && /(^|\/)node$/.test(commandOf(w.pid)));
}

export const joinWouldExtend = (state, self, isAlive = alive) =>
  ![...state.owners].some((pid) => pid !== self && isAlive(pid)) && ![...state.watched.keys()].some(isAlive);

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

export function capBanner(held) {
  const cap = held.launcherAlive
    ? `its launcher (pid ${held.by}) is still running, so this is the ${held.maxHold} min backstop for a hung test`
    : `its launcher${held.by ? ` (pid ${held.by})` : ""} has exited, so this is the ${held.maxHold} min cap for a left-open instance`;
  return `\n!!! UI GATE: test instance pid ${held.pid}${held.data ? ` (${held.data})` : ""}, launched by ${held.who}, held the uitest lock for ` +
    `${held.heldMinutes} min; ${cap}. The gate quit it so other agents' UI tests can run.\n` +
    `!!! Quit instances when done (ac quit <data dir>); a longer test sets AC_UITEST_MAX_HOLD=<minutes> before it launches.\n\n`;
}
export function instanceRecordPid(data) {
  try { return Number(JSON.parse(readFileSync(`${data}/instance.json`, "utf8")).pid) || null; } catch { return null; }
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
  const suppressedSeen = new Map();
  const firstSeen = new Map();
  const capped = new Set();
  const acTool = join(dirname(fileURLToPath(import.meta.url)), "..", "agent", "ac");
  for (let tick = 0; ; tick++) {
    const state = prune(readState(existsSync(stateFile) ? readFileSync(stateFile, "utf8") : ""));
    if (tick > 0 && !stillNeeded(state)) {
      await new Promise((r) => setTimeout(r, interval));
      if (!stillNeeded(prune(readState(existsSync(stateFile) ? readFileSync(stateFile, "utf8") : "")))) break;
      continue;
    }
    const front = parseFront(run("lsappinfo", ["info", run("lsappinfo", ["front"]).trim()]));
    for (const data of new Set([...state.watched.values()].filter(Boolean))) {
      let text = "";
      try { text = readFileSync(suppressedLog(data), "utf8"); } catch {}
      const { lines, seen } = newSuppressed(text, suppressedSeen.get(data) ?? 0);
      suppressedSeen.set(data, seen);
      if (lines.length) say(`ui gate: ${data}: a password field took focus in a test instance; Secure Event Input was prevented (${suppressedLog(data)}):\n${lines.map((l) => `  ${l}`).join("\n")}\n`);
    }
    for (const pid of state.watched.keys()) if (!firstSeen.has(pid)) firstSeen.set(pid, Date.now());
    for (const held of overHeld(state, Date.now(), firstSeen)) {
      if (capped.has(held.pid) || !launchedBinary(state, executableOf(held.pid))) continue;
      capped.add(held.pid);
      say(capBanner(held));
      if (held.data) try { appendFileSync(`${held.data}/ui-gate-violation.log`, capBanner(held)); } catch {}
      try { appendFileSync(stateFile, `${JSON.stringify({ capQuit: held, at: new Date().toISOString() })}\n`); } catch {}
      if (held.launcherAlive) try { process.stdout.write(`capped ${JSON.stringify(held)}\n`); } catch {}
      if (held.data && instanceRecordPid(held.data) === held.pid) try { execFileSync(acTool, ["quit", held.data], { stdio: "ignore", timeout: 30000 }); } catch {}
      if (alive(held.pid) && launchedBinary(state, executableOf(held.pid))) await stop(held.pid);
    }
    const found = violation(state, front);
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

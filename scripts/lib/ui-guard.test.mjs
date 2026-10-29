import assert from "node:assert/strict";
import { test } from "node:test";
import { capBanner, joinWouldExtend, liveMaxHold, newSuppressed, orphanMaxHold, overHeld, waitingOthers, parseFront, prune, readState, stillNeeded, violation } from "./ui-guard.mjs";

const lsappinfo = (name, pid, executable) => `"${name}" ASN:0x0-0xb2db2d: (in front) \n    bundleID="x"\n    bundle path="${executable.replace(/\/Contents\/MacOS\/.*$/, "")}"\n    executable path="${executable}"\n    pid = ${pid} token=[sess=1 pid=${pid}] type="Foreground" flavor=3\n`;
const build = "/Users/me/Developer/Personal/ardia/apps/browser/build-x/Build/Products/Debug/Solara.app/Contents/MacOS/Solara";
const state = (lines) => readState(lines.map((l) => JSON.stringify(l)).join("\n"));

test("the front app's pid, executable and name come from lsappinfo info", () => {
  assert.deepEqual(parseFront(lsappinfo("Dia", 92862, "/Applications/Dia.app/Contents/MacOS/Dia")),
    { pid: 92862, executable: "/Applications/Dia.app/Contents/MacOS/Dia", name: "Dia" });
  assert.equal(parseFront(""), null);
  assert.equal(parseFront('[ NULL ] ASN:0x0-0x1: (in front)\n    pid = 0 !cgsConnection\n'), null);
});

test("suppressed secure input lines are reported once each, as the log grows", () => {
  const first = newSuppressed("a\nb\n", 0);
  assert.deepEqual(first, { lines: ["a", "b"], seen: 2 });
  assert.deepEqual(newSuppressed("a\nb\n", first.seen).lines, []);
  assert.deepEqual(newSuppressed("a\nb\nc\n", first.seen).lines, ["c"]);
  assert.deepEqual(newSuppressed("", 0), { lines: [], seen: 0 });
});

test("the owner's own front app is never a violation", () => {
  const s = state([{ owner: 10 }, { binary: build, frontBefore: { pid: 92862, name: "Dia" } }, { watch: 500, data: "/tmp/ac-x" }]);
  assert.equal(violation(s, parseFront(lsappinfo("Dia", 92862, "/Applications/Dia.app/Contents/MacOS/Dia")), null), null);
  assert.equal(violation(s, parseFront(lsappinfo("Solara", 77, "/Applications/Solara.app/Contents/MacOS/Solara")), null), null);
});

test("a watched instance in front is a violation, with its data dir", () => {
  const s = state([{ owner: 10 }, { binary: build }, { watch: 500, data: "/tmp/ac-x" }]);
  assert.deepEqual(violation(s, { pid: 500, executable: build, name: "Solara" }, null),
    { pid: 500, executable: build, data: "/tmp/ac-x", what: "became the frontmost, active app" });
});

test("an instance of a launched binary in front before its pid is known is a violation, whatever the path's case", () => {
  const s = state([{ owner: 10 }, { binary: build }]);
  const found = violation(s, { pid: 600, executable: build.replace("/Personal/", "/personal/"), name: "Solara" }, null);
  assert.equal(found.pid, 600);
  assert.equal(found.data, null);
});

test("a watched pid that now runs another program is never a violation (pid reuse)", () => {
  const s = state([{ owner: 10 }, { binary: build }, { watch: 500, data: "/tmp/ac-x" }]);
  assert.equal(violation(s, { pid: 500, executable: "/Applications/Dia.app/Contents/MacOS/Dia", name: "Dia" }, null), null);
  assert.equal(violation(s, { pid: 500, executable: "", name: "" }), null);
});

test("a watched pid in front running the launched binary is a violation", () => {
  const s = state([{ owner: 10 }, { binary: build }, { watch: 500, data: "/tmp/ac-x" }]);
  assert.equal(violation(s, { pid: 500, executable: build, name: "Solara" }, null).data, "/tmp/ac-x");
});

test("an unwatched pid is no longer watched, and a later watch of it counts again", () => {
  assert.equal(state([{ watch: 500 }, { unwatch: 500 }]).watched.has(500), false);
  assert.equal(state([{ watch: 500 }, { unwatch: 500 }, { watch: 500 }]).watched.has(500), true);
});

test("the gate is needed while an owner or a watched instance lives", () => {
  const s = state([{ owner: 10 }, { owner: 11 }, { watch: 500 }]);
  assert.equal(stillNeeded(s, (pid) => pid === 500), true);
  assert.equal(stillNeeded(s, (pid) => pid === 11), true);
  assert.equal(stillNeeded(s, () => false), false);
});

test("a live pid reused by another program no longer keeps the gate (and the lock) held", () => {
  const programs = { 10: "/usr/sbin/cfprefsd", 500: "/Applications/Dia.app/Contents/MacOS/Dia", 501: build, 11: "/Users/me/.nvm/versions/node/v24/bin/node" };
  const s = prune(state([{ owner: 10 }, { owner: 11 }, { binary: build }, { watch: 500 }, { watch: 501 }]), () => true, (pid) => programs[pid] ?? "");
  assert.deepEqual([...s.watched.keys()], [501]);
  assert.deepEqual([...s.owners], [11]);
  const reused = prune(state([{ owner: 10 }, { binary: build }, { watch: 500 }]), () => true, (pid) => programs[pid] ?? "");
  assert.equal(stillNeeded(reused, () => true), false);
});

test("a live pid whose program can't be read (ps failed or timed out) is kept, not dropped", () => {
  const s = prune(state([{ owner: 11 }, { binary: build }, { watch: 501 }]), () => true, () => "");
  assert.deepEqual([...s.watched.keys()], [501]);
  assert.deepEqual([...s.owners], [11]);
  assert.equal(stillNeeded(s, () => true), true);
});

test("state keeps the first frontBefore and skips lines it can't read", () => {
  const s = readState(`${JSON.stringify({ frontBefore: { pid: 1 } })}\nnot json\n${JSON.stringify({ frontBefore: { pid: 2 } })}\n`);
  assert.equal(s.frontBefore.pid, 1);
});

const minute = 60000, now = 1000 * minute;
const dead = () => false;
const liveOnly = (...pids) => (pid) => pids.includes(pid);

test("a left-open instance whose launcher exited is over-held past 10 min, named by who launched it", () => {
  const s = state([{ owner: 10 }, { binary: build }, { watch: 500, data: "/tmp/ac-x", at: now - (orphanMaxHold + 1) * minute, who: "settings-ui", by: 77 },
    { watch: 501, data: "/tmp/ac-y", at: now - 2 * minute, who: "port-core", by: 78 }]);
  assert.deepEqual(overHeld(s, now, new Map(), dead),
    [{ pid: 500, data: "/tmp/ac-x", who: "settings-ui", by: 77, launcherAlive: false, heldMinutes: orphanMaxHold + 1, maxHold: orphanMaxHold }]);
  assert.match(capBanner(overHeld(s, now, new Map(), dead)[0]), /launcher \(pid 77\) has exited.*10 min cap/);
});

test("an instance whose launcher still runs is not over-held at 30 min, and is past the 60 min backstop", () => {
  const s = state([{ owner: 10 }, { binary: build }, { watch: 500, data: "/tmp/ac-x", at: now - 30 * minute, who: "acceptance", by: 77 }]);
  assert.deepEqual(overHeld(s, now, new Map(), liveOnly(77)), []);
  const late = overHeld(s, now + 31 * minute, new Map(), liveOnly(77));
  assert.equal(late.length, 1);
  assert.equal(late[0].maxHold, liveMaxHold);
  assert.equal(late[0].launcherAlive, true);
  assert.match(capBanner(late[0]), /still running.*60 min backstop/);
});

test("AC_UITEST_MAX_HOLD raises both caps", () => {
  const s = state([{ owner: 10 }, { binary: build }, { watch: 500, data: "/tmp/ac-x", at: now - 50 * minute, who: "bench", by: 77, maxHold: 90 }]);
  assert.deepEqual(overHeld(s, now, new Map(), dead), []);
  assert.deepEqual(overHeld(s, now + 30 * minute, new Map(), liveOnly(77)), []);
  assert.equal(overHeld(s, now + 41 * minute, new Map(), liveOnly(77))[0].maxHold, 90);
});

test("an entry from older code (no launch time, no launcher) counts from when the guard first saw it, under the 10 min cap", () => {
  const s = state([{ owner: 10 }, { binary: build }, { watch: 500, data: "/tmp/ac-x" }]);
  assert.deepEqual(overHeld(s, now, new Map(), dead), []);
  const over = overHeld(s, now, new Map([[500, now - 11 * minute]]), dead);
  assert.equal(over[0].who, "unknown");
  assert.equal(over[0].maxHold, orphanMaxHold);
  assert.deepEqual(overHeld(s, now, new Map([[500, now - 9 * minute]]), dead), []);
});

test("an unwatched instance is never over-held", () => {
  const s = state([{ owner: 10 }, { binary: build }, { watch: 500, data: "/tmp/ac-x", at: 0, who: "x", by: 77 }, { unwatch: 500 }]);
  assert.deepEqual(overHeld(s, now, new Map(), dead), []);
});

test("a join yields only to other agents' live node waiters", () => {
  const node = "/Users/me/.nvm/versions/node/v24/bin/node";
  const waiters = [{ pid: 1, key: "test-health" }, { pid: 2, key: "settings-ui" }, { pid: 3, key: "port-core" }, { pid: 4, key: null }, { pid: 5, key: "gone" }, { pid: 6, key: "reused" }];
  const isAlive = (pid) => pid !== 5;
  const commandOf = (pid) => (pid === 6 ? "/bin/zsh" : node);
  assert.deepEqual(waitingOthers(waiters, "test-health", 3, isAlive, commandOf).map((w) => w.pid), [2, 4]);
  assert.deepEqual(waitingOthers(waiters, "test-health", 99, isAlive, commandOf).map((w) => w.pid), [2, 3, 4]);
  assert.deepEqual(waitingOthers([{ pid: 1, key: "test-health" }], "test-health", 99, isAlive, commandOf), []);
  assert.deepEqual(waitingOthers([], "test-health", 99, isAlive, commandOf), []);
});

test("a join yields only when the hold has no live work left besides the joiner", () => {
  const isAlive = (pid) => [10, 500, 42].includes(pid);
  assert.equal(joinWouldExtend(state([{ owner: 10 }, { binary: build }, { watch: 500, data: "/tmp/ac-x" }]), 42, isAlive), false);
  assert.equal(joinWouldExtend(state([{ owner: 11 }, { binary: build }, { watch: 500, data: "/tmp/ac-x" }]), 42, isAlive), false);
  assert.equal(joinWouldExtend(state([{ owner: 10 }, { binary: build }]), 42, isAlive), false);
  assert.equal(joinWouldExtend(state([{ owner: 11 }, { binary: build }, { watch: 501, data: "/tmp/ac-x" }]), 42, isAlive), true);
  assert.equal(joinWouldExtend(state([{ owner: 42 }, { binary: build }, { watch: 501 }]), 42, isAlive), true);
});

test("a second ac launch beside the agent's own live instance still joins while another agent waits", () => {
  const node = "/Users/me/.nvm/versions/node/v24/bin/node";
  const isAlive = (pid) => [500, 7].includes(pid);
  const waiting = waitingOthers([{ pid: 7, key: "settings-ui" }], "port-core", 42, isAlive, () => node);
  assert.equal(waiting.length, 1);
  const ownHold = state([{ owner: 11 }, { binary: build }, { watch: 500, data: "/tmp/ac-a" }]);
  assert.equal(joinWouldExtend(ownHold, 42, isAlive), false);
  const finished = state([{ owner: 11 }, { binary: build }, { watch: 501, data: "/tmp/ac-a" }]);
  assert.equal(joinWouldExtend(finished, 42, isAlive), true);
});

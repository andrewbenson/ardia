import assert from "node:assert/strict";
import { test } from "node:test";
import { parseFront, readState, secureInputPid, stillNeeded, violation } from "./ui-guard.mjs";

const lsappinfo = (name, pid, executable) => `"${name}" ASN:0x0-0xb2db2d: (in front) \n    bundleID="x"\n    bundle path="${executable.replace(/\/Contents\/MacOS\/.*$/, "")}"\n    executable path="${executable}"\n    pid = ${pid} token=[sess=1 pid=${pid}] type="Foreground" flavor=3\n`;
const build = "/Users/me/Developer/Personal/ardia/apps/browser/build-x/Build/Products/Debug/Solara.app/Contents/MacOS/Solara";
const state = (lines) => readState(lines.map((l) => JSON.stringify(l)).join("\n"));

test("the front app's pid, executable and name come from lsappinfo info", () => {
  assert.deepEqual(parseFront(lsappinfo("Dia", 92862, "/Applications/Dia.app/Contents/MacOS/Dia")),
    { pid: 92862, executable: "/Applications/Dia.app/Contents/MacOS/Dia", name: "Dia" });
  assert.equal(parseFront(""), null);
  assert.equal(parseFront('[ NULL ] ASN:0x0-0x1: (in front)\n    pid = 0 !cgsConnection\n'), null);
});

test("the secure input holder comes from ioreg, and none is null", () => {
  assert.equal(secureInputPid('| "IOConsoleUsers" = ({"kCGSSessionSecureInputPID"=4242,"kCGSSessionUserIDKey"=501})'), 4242);
  assert.equal(secureInputPid('| "IOConsoleUsers" = ({"kCGSSessionUserIDKey"=501})'), null);
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

test("a watched instance holding Secure Event Input is a violation; another process holding it isn't ours", () => {
  const s = state([{ owner: 10 }, { binary: build }, { watch: 500, data: "/tmp/ac-x" }]);
  assert.equal(violation(s, null, { pid: 500, executable: build }).what, "holds macOS Secure Event Input");
  assert.equal(violation(s, null, { pid: 1234, executable: build }), null);
});

test("a watched pid that now runs another program is never a violation (pid reuse)", () => {
  const s = state([{ owner: 10 }, { binary: build }, { watch: 500, data: "/tmp/ac-x" }]);
  assert.equal(violation(s, { pid: 500, executable: "/Applications/Dia.app/Contents/MacOS/Dia", name: "Dia" }, null), null);
  assert.equal(violation(s, null, { pid: 500, executable: "/Applications/Dia.app/Contents/MacOS/Dia" }), null);
  assert.equal(violation(s, null, { pid: 500, executable: "" }), null);
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

test("state keeps the first frontBefore and skips lines it can't read", () => {
  const s = readState(`${JSON.stringify({ frontBefore: { pid: 1 } })}\nnot json\n${JSON.stringify({ frontBefore: { pid: 2 } })}\n`);
  assert.equal(s.frontBefore.pid, 1);
});

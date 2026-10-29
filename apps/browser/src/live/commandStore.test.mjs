import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { documentWrites } from "../test-native/shell.ts";

const calls = [];
const listeners = new Map();
let current = { revision: 0, replicaJSON: JSON.stringify({ folders: {}, folderOrder: [], items: {}, known: {}, unread: {}, hidden: {}, completed: {}, expandedStacks: {}, accounts: {}, config: {}, calendar: {}, meetingGroups: {}, dismissedAlerts: [] }) };
globalThis.acTestNativeModules = {
  SolaraSettings: {
    liveInitialReplica: () => current,
    liveCommand: async (name, payloadJSON) => {
      calls.push({ name, payload: JSON.parse(payloadJSON) });
      return JSON.stringify({ revision: current.revision, folderId: name === "createFolder" ? "f" : undefined });
    },
    addListener: (name, listener) => { listeners.set(name, listener); return { remove: () => listeners.delete(name) }; },
  },
};

const store = await import("./store.ts");

test("each persisted store action sends one command and never writes live.json", async () => {
  const actions = [
    ["createFolder", () => store.createFolder("p", "pullRequests", ["github"]), { profileId: "p", kind: "pullRequests", sources: ["github"] }],
    ["updateFolder", () => store.updateFolder("f", { name: "Renamed" }), { folderId: "f", patch: { name: "Renamed" } }],
    ["removeFolder", () => store.removeFolder("f"), { folderId: "f" }],
    ["arrangeFolders", () => store.arrangeFolders([{ id: "f", after: null }]), { placed: [{ id: "f", after: null }] }],
    ["applyFetch", () => store.applyFetch("f", [], {}), { folderId: "f", items: [], gone: {} }],
    ["setStatus", () => store.setStatus("f", { state: "idle" }), { folderId: "f", status: { state: "idle" } }],
    ["markRead", () => store.markRead("f", ["i"]), { folderId: "f", itemIds: ["i"] }],
    ["markUnread", () => store.markUnread("f", "i"), { folderId: "f", itemId: "i" }],
    ["hideItems", () => store.hideItems("f", []), { folderId: "f", items: [] }],
    ["unhide", () => store.unhide("f"), { folderId: "f" }],
    ["setExpandedStack", () => store.setExpandedStack("i", true), { key: "i", expanded: true }],
    ["updateConfig", () => store.updateConfig({ githubClientId: "x" }), { patch: { githubClientId: "x" } }],
    ["updateCalendarSettings", () => store.updateCalendarSettings({ prompted: true }), { patch: { prompted: true } }],
    ["setCalendarHidden", () => store.setCalendarHidden("c", true), { id: "c", hidden: true }],
    ["dismissAlert", () => store.dismissAlert("o"), { occurrence: "o" }],
    ["setMeetingGroup", () => store.setMeetingGroup(null, "g"), { group: null, groupId: "g" }],
  ];
  for (const [name, run, payload] of actions) {
    const before = calls.length;
    await run();
    assert.deepEqual(calls.slice(before), [{ name, payload }]);
  }
  assert.equal(documentWrites.includes("live.json"), false);
});

test("replicas apply only increasing revisions, preserve showAll and unchanged fields", () => {
  store.setLive({ showAll: { "f:x": true } });
  const before = store.live();
  current = { revision: 2, replicaJSON: JSON.stringify({ folders: { f: { id: "f", profileId: "p", kind: "pullRequests", name: "Pull Requests", sources: ["github"] } }, folderOrder: ["f"] }) };
  listeners.get("onLiveReplica")(current);
  const applied = store.live();
  assert.equal(applied.showAll["f:x"], true);
  assert.equal(applied.accounts, before.accounts);
  listeners.get("onLiveReplica")({ revision: 1, replicaJSON: JSON.stringify({ folderOrder: [] }) });
  assert.equal(store.live(), applied);
  listeners.get("onLiveReplica")({ revision: 3, replicaJSON: JSON.stringify({ folderOrder: ["f"] }) });
  assert.equal(store.live(), applied);
  assert.equal(documentWrites.includes("live.json"), false);
});

test("source tree has no live.json write through a literal or alias", () => {
  const root = fileURLToPath(new URL("../", import.meta.url));
  const visit = (dir) => readdirSync(dir, { withFileTypes: true }).flatMap((entry) => entry.isDirectory() ? visit(`${dir}/${entry.name}`) : [`${dir}/${entry.name}`]);
  for (const path of visit(root).filter((path) => /\.(?:[cm]?[jt]sx?)$/.test(path))) {
    const source = readFileSync(path, "utf8");
    const aliases = [...source.matchAll(/(?:const|let)\s+(\w+)\s*=\s*["']live\.json["']/g)].map((match) => match[1]);
    const writes = [...source.matchAll(/writeDocument\s*\(\s*([A-Za-z_$][\w$]*|"[^"]*"|'[^']*')/g)];
    for (const match of writes) assert.equal(match[1] === '"live.json"' || match[1] === "'live.json'" || aliases.includes(match[1]), false, path);
  }
});

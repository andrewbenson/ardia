import assert from "node:assert/strict";
import { test } from "node:test";
const { fixedBy } = await import("../switchOn.mjs");
const shell = await import("../../../test-native/index.ts");
const host = await import("../../../sync/journalHost.ts");
const { unionFallback } = await import("../../../sync/editJournal.ts");
const h = (ms) => `${ms.toString(36).padStart(9, "0")}.0000.dev1`;
const quiet = (vv) => ({ app: { unapplied: [], pending: 0, damaged: {}, outbox: [], vv } });

test("GEN-ahead-apply: a sync apply between the backup and T doesn't move g, so the fallback is anchored on T", fixedBy("step 4"), () => {
  shell.docs.clear();
  host.forgetEditJournal();
  const j = host.editJournal();
  j.record("app", "set:theme", { v: "light", h: h(1000), seen: null });
  shell.docs.set("session.json", JSON.stringify({ version: 2, settings: { theme: "light" }, ...host.journalAnchor() }));
  const backup = { journal: shell.docs.get("sync-edits.json"), session: shell.docs.get("session.json") };
  shell.docs.set("session.json", JSON.stringify({ version: 2, settings: { theme: "dark" }, ...host.journalAnchor() }));
  host.noteInStep(quiet({ B: 1 }), 10_000);
  j.record("app", "set:other", { v: 1, h: h(20_000), seen: null });
  shell.docs.set("session.json", JSON.stringify({ version: 2, settings: { theme: "dark", other: 1 }, ...host.journalAnchor() }));
  shell.docs.set("sync-edits.json", backup.journal);
  shell.docs.set("session.json", backup.session);
  host.forgetEditJournal();
  const opened = host.editJournal();
  assert.equal(opened.lost, true);
  if (opened.fallback !== "union") return;
  const { publish } = unionFallback({
    scope: "app", T: opened.inStep.T, vvT: opened.inStep.vv,
    local: new Map([["set:theme", "light"]]),
    records: new Map([["set:theme", { v: "dark", o: ["B", 1] }]]),
    everSeen: new Set(["set:theme"]), tombstoned: new Set(),
  });
  assert.equal(publish.has("set:theme"), false, `the restored light is published over B's dark (fallback ${opened.fallback})`);
});

test("GEN-T-control: a store saved after T, then the journal lost, still gets the union fallback", fixedBy("step 4"), () => {
  shell.docs.clear();
  host.forgetEditJournal();
  const j = host.editJournal();
  j.record("app", "set:theme", { v: "light", h: h(1000), seen: null });
  host.noteInStep(quiet({ B: 1 }), 10_000);
  shell.docs.set("session.json", JSON.stringify({ version: 2, ...host.journalAnchor() }));
  shell.docs.set("sync-edits.json", "{broken");
  host.forgetEditJournal();
  const opened = host.editJournal();
  assert.deepEqual([opened.lost, opened.fallback], [true, "union"]);
});

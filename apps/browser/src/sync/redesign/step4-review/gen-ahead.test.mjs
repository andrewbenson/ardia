import assert from "node:assert/strict";
import { test } from "node:test";
const { fixedBy } = await import("../switchOn.mjs");
const shell = await import("../../../test-native/index.ts");
const host = await import("../../../sync/journalHost.ts");
const { unionFallback } = await import("../../../sync/editJournal.ts");
const h = (ms) => `${ms.toString(36).padStart(9, "0")}.0000.dev1`;

test("GEN-ahead: the journal and the store docs rolled back together under a current gen doc publish nothing sync applied after the backup", fixedBy("step 4"), () => {
  shell.docs.clear();
  host.forgetEditJournal();
  const j = host.editJournal();
  j.record("app", "set:theme", { v: "light", h: h(1000), seen: null });
  host.noteInStep({ app: { unapplied: [], pending: 0, damaged: {}, outbox: [], vv: { B: 1 } } }, 10_000);
  shell.docs.set("session.json", JSON.stringify({ version: 2, settings: { theme: "light" }, ...host.journalAnchor() }));
  const backup = { journal: shell.docs.get("sync-edits.json"), session: shell.docs.get("session.json") };
  j.record("app", "set:other", { v: 1, h: h(2000), seen: null });
  host.noteInStep({ app: { unapplied: [], pending: 0, damaged: {}, outbox: [], vv: { B: 2 } } }, 20_000);
  shell.docs.set("session.json", JSON.stringify({ version: 2, settings: { theme: "dark" }, ...host.journalAnchor() }));
  shell.docs.set("sync-edits.json", backup.journal);
  shell.docs.set("session.json", backup.session);
  host.forgetEditJournal();
  const opened = host.editJournal();
  assert.equal(opened.lost, true, "control: the journal is behind the gen doc, so it's lost");
  assert.equal(opened.fallback, "nothing", "the store predates the in-step time, so no union fallback");
  if (opened.fallback !== "union") return;
  const { publish } = unionFallback({
    scope: "app",
    T: opened.inStep.T,
    vvT: opened.inStep.vv,
    local: new Map([["set:theme", "light"]]),
    records: new Map([["set:theme", { v: "dark", o: ["B", 2] }]]),
    everSeen: new Set(["set:theme"]),
    tombstoned: new Set(),
  });
  assert.equal(publish.has("set:theme"), false, `B's dark, which this Mac applied after the backup, isn't overwritten by the restored light (fallback ${opened.fallback}, vv(T) ${JSON.stringify(opened.inStep.vv)})`);
});

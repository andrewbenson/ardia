import assert from "node:assert/strict";
import { test } from "node:test";
const { fixedBy } = await import("../switchOn.mjs");
const shell = await import("../../../test-native/index.ts");
const host = await import("../../../sync/journalHost.ts");
const h = (ms) => `${ms.toString(36).padStart(9, "0")}.0000.dev1`;
const quiet = (vv) => ({ app: { unapplied: [], pending: 0, damaged: {}, outbox: [], vv } });

test("T-relaunch: a save during a 'nothing' launch doesn't stamp the restored store with the gen doc's T", fixedBy("step 4"), () => {
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
  const first = host.editJournal();
  assert.equal(first.fallback, "nothing", "control: the restored store predates T");
  shell.docs.set("session.json", JSON.stringify({ version: 2, settings: { theme: "light" }, ...host.journalAnchor() }));
  host.forgetEditJournal();
  const second = host.editJournal();
  assert.equal(second.lost, true, "control: no command ran, so the journal is still behind");
  assert.equal(second.fallback, "nothing", `the store still holds the pre-T light, yet the relaunch opens with ${second.fallback}`);
});

test("T-backwards: with the clock stepped back, T still moves forward, so a store saved before it can't pass for one saved after", fixedBy("step 4"), () => {
  shell.docs.clear();
  host.forgetEditJournal();
  const j = host.editJournal();
  j.record("app", "set:theme", { v: "light", h: h(1000), seen: null });
  host.noteInStep(quiet({ B: 1 }), 10_000);
  shell.docs.set("session.json", JSON.stringify({ version: 2, ...host.journalAnchor() }));
  const savedAtFirstT = shell.docs.get("session.json");
  host.noteInStep(quiet({ B: 2 }), 9_000);
  assert.ok(j.lastInStepT > 10_000, `T moves past the earlier one (${j.lastInStepT})`);
  shell.docs.set("sync-edits.json", "{broken");
  shell.docs.set("session.json", savedAtFirstT);
  host.forgetEditJournal();
  assert.equal(host.editJournal().fallback, "nothing", "a store saved at the earlier T predates the later one");
});

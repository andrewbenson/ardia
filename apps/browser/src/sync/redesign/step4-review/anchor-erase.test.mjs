import assert from "node:assert/strict";
import { test } from "node:test";
const { fixedBy } = await import("../switchOn.mjs");
const shell = await import("../../../test-native/index.ts");
const host = await import("../../../sync/journalHost.ts");
const h = (ms) => `${ms.toString(36).padStart(9, "0")}.0000.dev1`;

function lastSession() {
  shell.docs.clear();
  host.forgetEditJournal();
  const j = host.editJournal();
  j.record("app", "set:a", { v: 1, h: h(1000), seen: null });
  j.record("app", "set:b", { v: 2, h: h(2000), seen: null });
  host.noteSeen("app", "set:gone", ["dev2", 4]);
  shell.docs.set("session.json", JSON.stringify({ version: 2, ...host.journalAnchor() }));
  host.forgetEditJournal();
}

test("ERASE-seen: a session save at launch, before the first sync cycle reads the ever-seen keys, keeps them", fixedBy("step 4"), () => {
  lastSession();
  const anchor = host.journalAnchor();
  shell.docs.set("session.json", JSON.stringify({ version: 2, ...anchor }));
  host.forgetEditJournal();
  assert.deepEqual(host.seenOrigin("app", "set:gone"), ["dev2", 4], `the ever-seen key survives the save (anchor was ${JSON.stringify(anchor)})`);
});

test("ERASE-g: a session save before the journal opens keeps journalG, so a rolled-back journal still opens as lost", fixedBy("step 4"), () => {
  lastSession();
  const backup = [shell.docs.get("sync-edits.json"), shell.docs.get("sync-edits.gen")];
  const anchor = host.journalAnchor();
  shell.docs.set("session.json", JSON.stringify({ version: 2, ...anchor }));
  const j = JSON.parse(backup[0]);
  j.g = 1;
  shell.docs.set("sync-edits.json", JSON.stringify(j));
  const g = JSON.parse(backup[1]);
  g.g = 1;
  shell.docs.set("sync-edits.gen", JSON.stringify(g));
  host.forgetEditJournal();
  assert.equal(host.editJournal().lost, true, `journal at g 1 under a store that reflected g 2 is lost (anchor was ${JSON.stringify(anchor)})`);
});

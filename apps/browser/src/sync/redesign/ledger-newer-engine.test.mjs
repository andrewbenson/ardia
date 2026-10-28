import assert from "node:assert/strict";
import { test } from "node:test";
import { fixedBy } from "./switchOn.mjs";
import { shell, settle, reset, onAndSynced, passwordMac, native, realReadPasswords, appMac } from "./harness.mjs";

const host = await import("../journalHost.ts");
const SITE = "https://site.example";

test("LEDGER-newer: a password ledger from a newer version stops password sync with a reason and doesn't hold up the other types", fixedBy("step 3"), async () => {
  reset();
  const here = new Map();
  shell.passwordStores.set(null, here);
  native.readPasswords = async () => [...here.values()];
  try {
    const engine = await onAndSynced();
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const newer = JSON.stringify({ v: 3, profiles: {} });
    shell.docs.set("sync-pw-ledger.json", newer);
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    b.store.set(`pw:${SITE}\nme`, { o: SITE, u: "me", p: "from B" });
    await b.sync();
    const settings = appMac("set:");
    await settings.sync();
    settings.store.set("set:appearance", { v: "dark" });
    await settings.sync();
    const before = host.editJournal().lastInStepT;
    await engine.syncNow();
    await settle(60);
    await engine.syncNow();
    await settle(60);
    assert.equal(here.size, 0, "B's password isn't saved here");
    assert.match(engine.useSync.getState().passwordsError ?? "", /newer version/, "the Sync pane says why passwords stopped");
    assert.ok(host.editJournal().lastInStepT > before, "the edit journal still reaches step for the other types");
    assert.equal(shell.docs.get("sync-pw-ledger.json"), newer, "the newer ledger is left alone");
    shell.docs.set("sync-pw-ledger.json", JSON.stringify({ v: 1, profiles: {} }));
    await engine.syncNow();
    await settle(60);
    assert.equal(engine.useSync.getState().passwordsError, null, "control: with a ledger it can read, the reason goes away");
    assert.equal(JSON.parse(shell.docs.get("sync-pw-ledger.json")).v, 2, "and the older ledger is migrated to sealed digests");
  } finally {
    native.readPasswords = realReadPasswords;
  }
});

# Sync redesign: the edit journal and publishing chains

Status: proposal, revised after the design review (D1–D11, against 9f61ca29) and the re-review
(ten items, against b916ad7c). It replaces
the load guard described in docs/sync.md (§ After a load) as of 095f633c. Four reviews and the
convergence oracle kept finding new holes in that guard because it decides "changed here" by
comparing snapshots of the store (notes and baselines). Those snapshots are taken at the wrong time,
from the wrong inputs, or are lost with the state. This design removes that inference.

## The problem in one paragraph

A Mac's sync state (`sync-state.nns`: records, base, version vectors, seq) can come back lost
(unreadable, foreign, malformed) or older than the folder (a lost save, a restored backup, a
corrupted journal). Then two things go wrong:
- Base no longer says what this Mac last published or applied. Any local value that differs from
  it looks like an edit, and goes out stamped "now", over newer edits made elsewhere.
- The seq no longer says which numbers this Mac has used. The next batch can reuse one with
  different contents.

The current guard guesses which differences are real edits, and every guess has a counterexample.

## Invariants

1. **Only the edit journal says "changed here".** A local value or deletion is published only if
   the journal holds an entry for its `(scope, key)`. The op carries the entry's stamp. A
   difference with no entry is never published: the folder's value is applied over it, and apply
   never touches a key that has a live entry (any adapter, `adoptRemoteOnJoin` ones included). The
   one exception is a journal proven lost (§ 1, Durability). Then differences are published as a
   union bounded by the last time this Mac was in step with the folder. Device observations
   (`tabs:` of this device, pin titles and favicons) aren't edits; they're published by diff.
2. **A seq is used once per chain.** This Mac publishes under a chain id. When a load can't prove
   that its state knows every seq the chain has used, it mints a new chain before writing anything.
3. **Every hold has an age limit**, counted from when the file was first seen and kept with the file
   whatever the listing later says (pending, damaged or gone).
4. **Settling is per data type.** A type that's off isn't part of a rebuild. When it's turned on, it
   is judged by the journal.

Consequence: what a rolled-back or rebuilt Mac sends is only what its user changed, stamped by one
monotonic clock. It can't collide with a batch already written.

## 1. The local edit journal

**Entry.** `(scope, key) → { v: value | null, h: HLC, seen: digest of the record's value when the
edit was made, or null if there was no record }`, holding the latest user edit to that key. A
deletion is `v: null`.

**Which profiles** (D10, lead's rule).
- A profile deleted on this Mac drops its entries when it retires, and nothing of it is published.
- A profile whose sync is turned off, but which is kept, goes on journaling as normal.
- When its sync is turned back on, each entry publishes under the same conflict rule as passwords:
  - **No conflict:** the record's digest still equals the entry's `seen`. The edit or deletion goes
    out with its edit-time stamp.
  - **Conflict:** the record changed since. The entry goes out stamped at its edit time, and last
    writer wins. So a deletion made while off holds only if nobody touched the item elsewhere after
    it, and a rename made while off loses only to a later one.
- The same rule covers a rejoin after Stop Syncing, since the journal kept running.

**What's journaled: user commands only** (re-review 9). These are the store commands a user
action runs: settings, profiles, bookmarks, pins, groups, a history delete, and imports.
- Device observations stay outside the journal and are published by diff, as today: `tabs:<this
  device>`, and a pin's page title and favicon. No observation writes the journal, so a navigation
  never does synchronous IO.
- `tabs:<this device>` is owned by this device. A diff of it can't send another Mac's choice back.
- **Pins mix both** (final review 5). A `pin:t:` record holds observations (`ti` page title, `i`
  favicon) and choices (`g` group, `pos` position, `u` home, `t` custom title).
  - When only observation fields differ from the record, the record is published by diff, with the
    record's own choice fields.
  - When a choice field differs too and there's no journal entry, nothing is published. The
    folder's value lands first, and the next cycle publishes the observation over it.
  - So a title change never carries a stale group or position over a move made elsewhere, and a
    rolled-back Mac can't either.

**Where it lives: three files in Solara's data folder, outside `sync-state.nns`.**

| File | Holds | Written |
| --- | --- | --- |
| `sync-edits.json` | the entries; the journal generation `g`; the newest `h` | synchronously on each user command, before its gen doc |
| `sync-edits.gen` | `g`; the last in-step time `T`, with the version vector of every synced scope at `T` | right after `sync-edits.json` (same `g`), and after each in-step cycle (new `T` and vv) |
| `sync-pw-ledger.json` | per key: the last 4 digests, `h`, `modified`; the ledger generation `L`; Login Data's inode and creation time | after every apply or publish that touches passwords, right after the meta row |

The fourth piece lives in Login Data itself: a row `solara_sync_ledger = L` in its `meta` table,
written through ArdiaCore **before** `sync-pw-ledger.json` (final review 1).

- **Journal check at load.**
  - `sync-edits.json` unreadable, or its `g` below the gen doc's, means a lost journal.
  - A journal ahead by one is a crash between the two writes, and it's fine.
  - A missing `sync-edits.gen` with a readable journal means the journal is valid, so no fallback
    runs. The gen doc is rewritten from it.
- **Ledger check on each read.** The meta row and the logins are read from the same copy of Login
  Data, one read of the file, so a restore between the two can't mix them.
  - **Row equal to `L`:** consistent.
  - **Row at `L + 1`:** a crash between the row write and the ledger's, or between Chrome's write
    and the ledger's. It isn't a mismatch, but the in-between write can't be trusted, so each key is
    judged against the folder:
    - a local digest equal to its record is seeded, not published;
    - a local digest that differs is handled by the edit rules below.
    The ledger is then rewritten at `L + 1`.
  - **Row below `L`, missing, or a different inode:** always a restore, a raze or a replacement, so
    a mismatch, and the passwords type rebuilds.
  - **The order matters.** The row goes first, so a backup taken between the two writes carries
    the new row with the old ledger state (`L + 1`, handled above), never an old row that would pass.
    Most backups carry `L - 1`, which is exactly a restore.

**Durability** (D4, re-review 4).
- Write-through, in the order in the table above. The reverse order would turn a crash into a lost
  journal.
- **Last in-step time.** The end of the last cycle in which a pull completed with nothing unapplied,
  for every synced type. It's saved in `sync-edits.gen` after each such cycle, together with each
  scope's version vector at that moment, `vv(T)`.
- **Fallback on a lost journal: a union bounded by what this Mac had seen at `T`** (final review 3).
  - **A local value that differs from its record** is published at `Clock.at(T)`, but only where the
    record's origin `(device, seq)` is covered by `vv(T)`. That means this Mac had already applied
    that record when it was last in step, so the difference was made here after `T`.
  - **A record whose origin isn't covered** wins, and its value is applied, whatever its stamp says.
    That includes a late file: Mac C's 9:00 rename arriving at 10:30, after A's `T` of 10:00, still
    beats A's stale title.
  - **A local item the folder lacks** is kept and published at `Clock.at(T)` only if its key has
    never been seen in this Mac's records (the ever-seen set, below) and has no tombstone. An
    ever-seen key the folder lacks was deleted or collected, so the item is removed.
  - Nothing is published as deleted.

**How it's written.** The store's command layer writes entries for commands not tagged
`fromSync`:
- Each command's changed entities are compared by value with what they were before, in their
  extracted form. Each changed entity maps to its sync key through the key functions the adapters
  use, moved to a shared module so they can't disagree.
- Sync applies run under `fromSync`. Settings and pins already do; bookmarks, history and profiles
  get the flag.
- **Ordering in applies** (re-review 6). A history apply does its `fromSync` store update before it
  calls `addHistoryVisits` and `deleteHistoryUrls` (adapters.ts:438-439, today it's after). The
  engine's echo then finds the store already matching, and nothing is journaled.
- **NativeStore** (D11). When it owns the workspace, the journal lives on the Swift side, which sees
  each command and its per-key `fromSync` flag. Replica revs that reach JS carry a tag per changed
  key.
- **One clock** (D9): stamps come from the sync clock.

**History** (re-review 6).
- Visits are append-only, carry their own times, and are published by the history adapter as today.
- A history delete the user makes is journaled.
- Two removals are not deletions and must never be journaled or published:
  - the store's 5,000-entry cap (store/history.ts:53, lib/history.ts `setView`);
  - Chrome's 90-day expiry. ArdiaCore passes `DeletionInfo::is_from_expiration()` through, and
    expired URLs go to the adapter's ignore rule (adapters.ts:397-401), which already ignores entries
    older than the window or below the floor.

**Bookmarks: Chrome's model is the source** (D5, re-review 5). User edits made inside Chrome (the
extension `chrome.bookmarks` API, Chrome's importers) arrive only when `lib/bookmarks.ts` re-reads
the tree, and so does the echo of sync's pushes.
- **The shadow** is Chrome's tree as last read or pushed (`state.shadow`, lib/bookmarks.ts:252,
  256, 266), not the store's tree.
- Each read journals `diff(fetched, shadow)` per node, by value. The diff is taken before `readTree`
  replays pending store edits over the fetched tree (:249-251), so a concurrent extension edit is
  journaled and isn't hidden.
- **Echo filter.** A pushed-values table records `node → value sync last pushed`. A fetched node
  equal to its pushed value isn't journaled. Entries clear after the next successful read.
- **The first read at launch** is journaled like any other, so an extension edit made before it
  isn't lost. To keep the diff truthful, the shadow cache is saved synchronously after each apply
  and push. Today it's debounced by 2 s, so a quit could leave it stale.
- **The shadow and the pushed values are saved together.** The shadow cache and the pushed-values
  table go to disk in one synchronous write (`bookmarks-cache.json`), after each apply and push.
  - **The gap this closes.** A crash between a push and that write leaves a shadow from before the
    push. At launch, the value this Mac pushed and already published then differs from the shadow.
    It would be journaled as a fresh edit and resent with a launch-time stamp, over a newer edit
    from another Mac.
  - **The rule.** A launch diff that equals a value in the pushed-values table isn't journaled. The
    table and the shadow land together, so after any crash one of them covers the pushed value.

**Passwords: Chrome's Login Data is the source** (D1–D3, re-review 1–3).
- **Ledger.** `pwLedger`, kept in Solara's data folder:
  - `key → { digests: the last 4 digests seen for this key, newest first; h: the record's h when
    last published or applied; modified }`, where `modified` is `date_password_modified` read back
    after sync's write;
  - plus a ledger generation.
- **Login Data generation.** Whenever the ledger changes, its generation is also written into Login
  Data's own `meta` table (`solara_sync_ledger`), through a new ArdiaCore call
  (`ac_passwords_mark`). Each read compares the two.
  - A mismatch means Login Data was restored, replaced or razed under the ledger. The inode and
    creation time can't see an in-place restore (`cp`, `rsync --inplace`); the meta row can.
  - On a mismatch the passwords type rebuilds. Nothing is claimed as an edit, and each key is
    judged against the folder: equal is re-seeded; different takes the folder's value; missing
    locally is applied from the folder. Nothing is published as deleted.
- **Detection by ledger**, on each read:
  - **Addition:** a key not in the ledger.
  - **Deletion:** a ledger key missing locally.
  - **Edit:** a key whose digest isn't the ledger's newest.
  - **A digest matching an older one of the last 4** (final review 2) can be either case:
    - **A rollback:** an older copy of Login Data carries its old date, so `date_password_modified`
      is at or before the ledger's `modified`. It takes the folder's value.
    - **A deliberate revert:** a user going back to an earlier password gets `Now()` from Chrome,
      later than the ledger's `modified`. It's an edit like any other.
    Both dates come from this Mac's own clock, so skew doesn't enter.
- **Conflicts are decided by value** (re-review 3). For a deletion or an edit:
  - **No conflict** when the record's current digest equals the ledger's newest, meaning nothing
    elsewhere changed it since this Mac last agreed. The change is stamped
    `max(Clock.at(min(modified, now)), successor of the record's h)`. For a deletion, `modified` is
    the time of the read that noticed it.
  - **Conflict** when the record's digest differs. An edit is then stamped `Clock.at(modified)` (its
    real time) and merged by last writer wins against the record. A password changed here on day 1
    while unreadable loses to B's change on day 2.
  - **A conflicting deletion is dropped**: the login is applied back from the folder. A deletion
    goes out only over the value it removed. Another Mac republishing that same value (same digest,
    new `h`) is not a conflict, and the deletion still goes out.
- **Mass changes** (re-review 2). A read is judged per key.
  - The first time a read drops or edits more than half the ledger's keys (and more than 5),
    those keys are held, not published.
  - The Sync pane asks: "N passwords were removed or changed on this Mac. Remove or change them on
    your other Macs too, or restore them here?" The default is restore. Restore applies the folder's
    values; confirm publishes the held changes.
  - Keys under the threshold are published as usual. There's no "couldn't be read" message for this
    case.
- **Apply uses the ledger** (D3). `passwordsAdapter.apply` (adapters.ts:521) skips a login only
  while the ledger says it has an unpublished change here, never because of base.
- **Upgrade** (re-review 3).
  - A login equal to its record is seeded into the ledger.
  - A login that differs is claimed as an edit only if its `date_password_modified` is later than the
    record's wall time, from `h`; it's stamped `Clock.at(modified)`. Otherwise it takes the folder's
    value.
  - A login with no record is an addition.

**Extensions** already record intents (`host.intents()`). Those become their journal entries.

**Clearing an entry.** An entry is cleared when the op carrying exactly its `(key, h)` has been
written to the folder. A newer edit replaces the entry, so the clear leaves it alone. A crash between
the write and the clear re-sends the same op, which changes nothing.

**Publishing.** For each entry of an adapter's prefix, `publishAdapter` publishes `{k, h: entry.h,
v: current value or null}`. If the record already has `h >= entry.h`, the entry is stale and is
cleared. Observation keys (above) are still published by diff.
- **Bookmark positions** (D6, re-review 10) come from the records first and fall back to base, so a
  lost base never renumbers.

**Applying.** Every key with a difference and no live entry takes the folder's value. A key with a
live entry is never applied over, in any adapter (D11).
- **Bookmarks apply** (D7, re-review 10, final review 4) rebuilds the tree from what's visible. A
  local node that isn't visible is removed only when one of these holds:
  - its key has a tombstone in the records;
  - its key is in the **ever-seen set** with a saved origin `(device, seq)` that the current vv
    covers, and the record is gone. The set holds each key this Mac's bookmark records have ever
    held, with that record's last origin, kept per profile beside the journal and outside the sync
    state.
  Any other invisible node is kept: one never seen, or one whose origin's file hasn't arrived yet.
- So after a state loss:
  - a bookmark deleted elsewhere is removed once the file or snapshot that covers it has arrived,
    even when compaction collected its tombstone (45 days);
  - a bookmark whose file is still downloading is kept, however long the hold lasted;
  - a new local bookmark nobody has seen is kept.

**Joining and first sync** (re-review 8).
- When sync is turned on, or a profile or type is first linked, existing local items get entries
  stamped `Clock.at(editedAt)` where an item has one, else the turn-on time. On a rejoin, an
  existing newer entry is kept (D10).
- **Except the `adoptRemoteOnJoin` adapters** (`set:`, `prof:`, `pth:`, `share:`, `devmode:`): they
  get no seeded entries, so a joining Mac adopts the synced settings and profile names instead of
  overwriting everyone's with its own. A user command run during the join is journaled as an edit
  like any other.
- Passwords seed the ledger: an equal login is seeded; a differing one takes the folder's value; a
  login the folder lacks is an addition.

## 2. Publishing chains

- `doc.deviceId` stays the device's identity for `dev:` records, the device name and its tabs.
- Batches are published under `chain = <deviceId>.<n>`. vv, extra and seq are kept per chain. A chain
  is just another device string, so there's no format change for readers.
- **The chain is kept at load only when the state proves it is current.** All of these must hold:
  - the sealed state loaded, and its batch journal is readable;
  - after the first pull, `vv[chain]` doesn't exceed the state's seq, and no snapshot's vv does;
  - the first pull lists no file unknown to the state as pending or damaged;
  - the phrase wasn't just re-entered, and this is the Mac that `deviceId` was minted on (D8,
    re-review 7).
- **Twins.** The sync key's Keychain item is `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
  but it is saved without `kSecUseDataProtectionKeychain` (SyncKeyStore.swift:16-21, 41). So it
  lives in the file-based login keychain, and Migration Assistant and disk clones carry it.
  docs/sync.md's "this device only" is therefore wrong today. Changing the item's keychain class
  would change the key's lifetime, so that's the owner's decision and isn't part of this design.
  - Instead, `deviceId` is saved with the Mac's `IOPlatformUUID`. At load, a different
    `IOPlatformUUID` means a copied Mac. It mints a new `deviceId` (a new identity for its `dev:`
    record and tabs) and a new chain. The original keeps both.
- Otherwise a new chain is minted before the first write. Re-sends (the batch journal, an older
  build's revived batches) keep their ops and stamps and get new seqs under the new chain.
- **A healthy Mac never waits.** It publishes in its first cycle, under its old chain if the checks
  pass, under a new one otherwise. Nothing holds publishing to protect seqs.
- **Cost:** one vv entry per load that can't prove currency. A placeholder at launch is common, so
  that will be frequent. A retired chain's vv entry is dropped from snapshots once no log of it is
  left and it is past the tombstone hold (90 days).

## 3. Holds, all bounded

One hold remains: a rebuilding type doesn't apply while its pull is incomplete.
- Each unreadable file the state doesn't know gets a first-seen time, saved in the state and kept
  whatever its listing says, including pending after damaged (Q1).
- After 10 minutes a file stops holding anything. The type then applies what it has. Under the
  bookmarks apply rule, an invisible node is removed only on a tombstone, or when the vv covers its
  last origin. A node whose file is still pending isn't covered, so it stays. Nothing local is
  published as deleted without a journal entry.
- The Sync pane shows "Waiting for N files" until a file arrives or is given up after a day.
- A healthy Mac is never under this hold.

## 4. Per-type settle

- A rebuild is per data type: `rebuild.types` lists the types still rebuilding.
- A type settles once its pull is complete or past its limit, its adapters have extracted, and
  nothing of it is unapplied. For passwords, "unapplied" is judged against the ledger, so a lost base
  can't keep it from settling (R-unapplied).
- A type that's off isn't listed. Turning it on adds it, and it is judged by the journal.
- The marker is deleted when the list is empty.

## Clocks (D9)

- **One clock per Mac.** The journal, the scopes and `doc.clock` share it.
- **Counter overflow.** The HLC counter is 4 base-36 digits. Today, past `zzzz` it becomes `10000`,
  which sorts below `zzzz`. /private/tmp/design-review/hlc-counter-overflow.test.mjs shows that
  after 1,679,614 ticks behind a stamp in 2030, reachable because the clock ticks on every
  observation. The fix: on overflow, the clock carries into the wall time (`wall + 1 ms`, counter 0).
  That keeps the format and stays monotonic.
- **Skew** isn't bounded by anything here. A Mac whose wall clock runs ahead wins concurrent edits
  until the others observe its stamps, as today (docs/sync.md § Clock skew). The earlier claim that
  it's "bounded to that skew" was wrong and is withdrawn.

## Semantics, stated

- **Per record, last writer wins.** Two Macs editing different fields of one record (a bookmark's
  title on one, its folder on the other) keep only the later record whole.
- **A password rename** is published as the old key's deletion plus a new key. If another Mac
  changes the old login's password meanwhile, the deletion conflicts by value and is dropped. Both
  logins then survive, the renamed one and the changed one. Nothing is lost, and the user sees two
  entries.
- **A long-offline Mac's edit** has its edit-time stamp, so it loses to a later edit elsewhere. A
  password change that conflicts with a change elsewhere is decided by its real modified time too.
  A non-conflicting one is stamped after the record it replaces.

## Migration

- **Journal at upgrade.** It starts empty, and no edits are claimed. An older build's edits that
  weren't published before the upgrade are taken as stale. That includes edits made during an
  old-format rebuild (B-old). It's a one-time window of a few seconds, since an old build publishes
  within 3 s of an edit. The lead accepted it. guard-review2's B-old repro stays red as the record
  of it, named EXPECTED RED.
- **Password ledger at upgrade.**
  - Seeded from keys equal to their record.
  - A differing login is claimed only if Chrome modified it after the record's time (§ 1).
  - Login Data's `meta` generation is written on the first ledger write.
- `doc.rebuilding`, `rebuildBaseline`, `rebuild.noted` and `heldOutbox` are read and then dropped.
- **Older builds.** sync.json's `v` is bumped, so older builds (from 5b76b1f6 on) leave it alone, as
  in B35. Builds before 5b76b1f6 can't be guarded. Downgrading past it is unsupported.

## What's removed

- From the guard: the launch and load notes, `baselines`, `notedFor`, `keepNotes`,
  `noteDelivered`/`fromFolder`, `changedHere`, `backToBase`, `heldBack`,
  `EDITABLE_WHILE_UNREADABLE`, the fresh download hold and the stand-in base.
- The guard keeps pull-first on a fresh load, re-sending batches under the current chain, and
  per-type settle.

## Checked: Chromium's `date_password_modified`

Read in this tree's Chromium (`components/password_manager/core/browser`). Every path that changes a
password sets it to `Now()`:
- add (saved_passwords_presenter.cc:88-89);
- edit (:857-861);
- form saves, including the change-password and generated-password flows (form_saver_impl.cc:86,
  127, 139, 157);
- CSV import, both new logins and replaced conflicts (password_importer.cc:648, through the
  presenter).

A username-only edit keeps the old date and lands under a new key (:870-874). The design doesn't
rely on the date: detection is by ledger and stamping by the sync clock.

## Checked: store paths that bypass or echo through the journal

| Path | Handling |
| --- | --- |
| Launch hydrate (`browser.ts hydrate`) | not a command, so not journaled |
| Bookmarks re-read from Chrome's model (`lib/bookmarks.ts`), including extension and importer edits | diff of fetched against Chrome's last-read-or-pushed tree, before the replay; pushed-values echo filter; first read journaled like any other, with the shadow saved synchronously |
| History view (`lib/history.ts setView`): cap eviction and Chrome's 90-day expiry | not journaled; the adapter's ignore rule; `is_from_expiration` passed through |
| History apply echo | `fromSync` update before the engine calls |
| NativeStore replica revs | per-key tags; journal on the Swift side |
| Imports (`components/import/apply.ts`) | commands are journaled; passwords through the ledger |
| `tabs:` of this device, pin page title and favicon | observations: published by diff, never journaled |
| `bookmarksReady`, `historyReady` and other flags | no sync key, ignored |

## Holes I still see

- **A missed command path.** A user edit that bypasses the command layer is never published. Each
  native path above gets a test.
- **Login Data `meta` writes: checked in Chromium, they work but need an engine patch.**
  - `sql::MetaTable` (sql/meta_table.cc) is a plain key/value table. `Init` only creates it if it's
    missing (:153), `SetValue` inserts or replaces one key (:204), and nothing in
    `LoginDatabase::Init`, its migrations (:1196-1240, `FixVersionIfNeeded` :916) or its version
    checks (:1148-1160) touches keys other than the version pair. So a custom row survives
    migrations and version checks.
  - `DeleteAndRecreateDatabaseFile` (:1908-1929) deletes the file, row included. Its one caller is
    Chrome Sync's bridge (password_sync_bridge.cc:942), which Solara never runs. If it ever did, the
    missing row reads as a mismatch, which is the safe outcome.
  - A database too new for this Chrome fails `Init` (:1154): passwords are unreadable, not mismatched.
  - Login Data is opened with exclusive locking (`DatabaseOptions` default, sql/database.h:350), so
    a second SQLite connection can't write it while Chrome runs. The row has to be written through
    Chrome's own `LoginDatabase`, as an engine patch that adds a method reaching `meta_table_` on the
    password store's sequence, exposed as `ac_passwords_mark`. That's one more patch in the series.
- **Chrome's own cleanup of undecryptable logins.** With `kClearUndecryptablePasswords` on,
  `LoginDatabase` deletes logins it can't decrypt (login_database.cc:2266). It doesn't when Chrome
  runs with `--user-data-dir` (:1036). Solara always passes it (ArdiaCoreHost.mm:638), and ArdiaCore
  refuses to start without it (ac_main_delegate.cc:410). The ledger would read such a cleanup as
  deletions, so the dependency is pinned by a test that checks both lines (FR6).
- **Keychain class.** Twins are handled by `IOPlatformUUID`; the item still copies with the Mac.
  Whether to move it to the data-protection keychain is the owner's decision.
- **The mass-change prompt** waits on the user. Until they answer, the held keys aren't published,
  and the folder's values aren't applied over them.

## Repros mapped to the design

| Repro | What it shows | Removed by |
| --- | --- | --- |
| revsync4 R-baseline | baseline taken before stores are ready | invariant 1: no baseline |
| revsync4 R-passwords | rebuilt passwords republish the old one | ledger detection, ledger apply (D1–D3) |
| revsync4 R-unapplied | rebuild ends with keys unapplied; for passwords it never settles after a loss | per-type settle judged by the ledger (D3) |
| revsync4 R-lock | throw during baseline capture locks the Mac | no capture step |
| revsync4 R-pending | pending file holds the rebuild for 24 h | hold limited to 10 minutes, with the D7 apply rule |
| revsync4 R-rollback | readable rollback keeps the old base | invariant 1 |
| revsync4 R-rollback-outbox | rollback outbox reuses a seq | invariant 2 |
| guard-review r1 | rollback, own batch pending, seq reused | invariant 2: pending at first pull, so a new chain |
| guard-review r2 | relaunch undoes edits made after the loss | write-through journal with generation (D4) |
| guard-review r3 | healthy relaunch reverts the latest choice | write-through entry carries the edit's stamp (D4) |
| guard-review r4 | rollback, remote pending, stale resend | invariant 1 |
| guard-review2 A, A2, A3 | rollback after compaction resends stale | invariant 1; A is also a new chain |
| guard-review2 B-old | old-format rebuild loses an edit | migration window (accepted, one-time) |
| guard-review2 C1 | marker open while a type is off | per-type settle |
| guard-review2 C2 | edit while the type is off is overwritten | invariant 1 and per-type settle |
| guard-review2 D | stubbed note misses the shared profile | invariant 1: no note |
| guard-review2 E | own batch pending past 10 minutes, seq reused | invariant 2 |
| guard-review3 r1, r1b | setting chosen while unlocking or locked is lost | write-through journal at edit time |
| guard-review3 r2 | launch note stuck behind passwords | no note |
| guard-review3 r3 | passwords read with the type off | no note; passwords read only when on |
| guard-review3 r4 | launch cost with large history | no note |
| guard-review4 Q1 | damaged-then-pending holds applies forever | per-file first-seen age |
| guard-review4 Q3, Q3-pre | rolled-back password resent over newer | ledger outside the sync state; detection by digest; apply by ledger (D1–D3) |
| oracle 35309 | corrupt sync journal, seq reused | invariant 2 |
| oracle 25066 / B70 | partial apply wipes bookmarks, published as deleted | D7 apply rule; invariant 1 |
| oracle 43, 212, 390, 398 (strict) | tie repair rewrites whole records | separate tie-by-key fix |
| design review, HLC overflow | counter past `zzzz` sorts low | carry into wall time (D9) |

## Today's accepted residuals

| Residual (as of 095f633c) | Under this design |
| --- | --- |
| Healthy Mac waits up to 10 minutes at launch | Gone: no seq hold; a new chain when currency is unproven |
| Healthy relaunch: a setting matching another Mac's unpulled old value is taken for a rollback (R3) | Gone: journal entry, not value comparison |
| Rolled-back state resends an older password (Q3, Q3-pre) | Gone: ledger detection and apply |
| Passwords saved while unreadable taken as stale | Gone: the ledger sees the change whenever passwords become readable |
| Rollback after compaction undetected (A2) | Gone: no detection needed |
| Old-format rebuild loses its baseline (B-old) | One-time migration window; the old build kept no record |
| Own batch downloading past 10 minutes reuses its seq (E) | Gone: new chain |
| Marker open while a type is off (C1) | Gone: per-type settle |
| Seed 35309 | Gone: new chain |
| Tombstones dropped after 45 days | Narrower: a returning Mac sends only journaled edits, and D7 removes collected deletions. A log replayed after the hold can still bring one back, as today |
| Tie repair rewrites records | Separate tie-by-key fix |

## Test plan

Every repro above becomes a failing-first test in engineRecovery, and so does each finding. The
scratch suite is /private/tmp/redesign-tests/ (`run.sh`).

Harness notes:
- **Bookmarks with the engine** (rr5-bridge-engine.test.mjs) runs the real `lib/bookmarks.ts` over
  the Chrome bookmark fake, together with the engine. A gate on the fake's `ac_bookmarks_apply`
  holds an app edit pending.
- **The setTimeout shim.** The engine harness stubs `setTimeout` to return 0 and never fire. The
  bridge saves its cache at stop only when `cacheTimer` is truthy, so under that stub the cache is
  never written, and the first launch read replays the whole stale store over Chrome. That made a
  fake red result. Any test running the bridge must return a non-zero id for the 2 s cache timer
  (without firing it), and must let the 5 ms `reloadBookmarks` wait run on real time.
- **RR5 and RR5-stale-cache are guards.** They're green on today's bridge, which has no restore tag.
  The new code must keep them green. RR5-stale-cache also checks that a stale shadow doesn't resend
  this Mac's own pushed value.
- **D1:** a username-only rename survives an older tombstone of the new key, and a change here wins
  over a clock running an hour ahead.
- **D2:** Login Data losing most logins doesn't delete them everywhere.
- **D3:** with base lost, a differing login is applied and the type settles.
- **D4:** an edit just before a crash is published.
- **D6:** a lost base doesn't renumber positions.
- **D7:** a partial replica doesn't wipe bookmarks.
- **D8:** a copied Mac never reuses a seq.
- **D9:** the counter carry.
- **D10:**
  - A rename made while sync was off wins on rejoin over an older rename elsewhere.
  - A deletion made while a profile's sync was off goes out when it's turned back on, if the item
    is untouched.
  - The same deletion loses to a later rename elsewhere.
- **D11:** a setting changed while joining stands.

Re-review items:
- **RR1:**
  - Login Data restored in place (same inode, older content) reverts nothing anywhere.
  - A login changed back to an earlier digest is a rollback signal, not an edit.
- **RR2:**
  - A mass change holds only the keys over the threshold, edits counted too.
  - The prompt's default restores them.
  - No "couldn't be read" message appears.
- **RR3:**
  - Another Mac republishing the same value doesn't undo a deletion here.
  - A password changed here while unreadable on day 1 loses to B's change on day 2.
  - At upgrade, a login Chrome modified after its record is claimed, and an older one isn't.
- **RR4:** after a lost journal, a rename and a deletion made elsewhere after the last in-step time
  both win.
- **RR5:** an extension edit made before the first read at launch is published.
- **RR6:**
  - The 5,000-entry cap and Chrome's 90-day expiry publish no deletion.
  - A history apply's echo journals nothing.
- **RR7:** a copied Mac, with the Keychain item copied too, gets a new `deviceId` and chain from
  `IOPlatformUUID`.
- **RR8:** a joining Mac adopts the synced settings and profile names, and doesn't overwrite them.
- **RR9:** a navigation writes nothing to the journal.
- **RR10:**
  - Positions come from records, with base as the fallback.
  - The ever-seen set removes a bookmark whose tombstone was collected.

Final review:
- **FR1:** Login Data restored in place from one ledger write ago (row at `L - 1`), dropping 30
  of 70 logins applied in that write, deletes none elsewhere.
- **FR2:** a deliberate revert to an earlier password is published.
- **FR3 (RR4):** a late file older than `T` (C's 9:00 rename arriving at 10:30) wins over this
  Mac's stale title, and nothing stale is sent.
- **FR4:** the ever-seen set removes nothing whose file is still downloading.
- **FR5:** a pin's page-title change doesn't send its old group or position over a move made
  elsewhere.
- **FR6:** Solara always passes `--user-data-dir`.

**Tie seeds.** The cited seeds come from a strict oracle, the tracked harness with the two
"repair counts as a choice" rules removed (`/private/tmp/redesign-tests/engineScenario-strict.mjs`).
In its first 400 seeds, 43, 212, 390 and 398 fail on tie repairs. 265 no longer does, since the
settle phase and hidden-file steps changed what it generates. The tie-by-key fix's commit puts the
rules back to failures, so these pass on their merits.

# Sync redesign: the edit journal and publishing chains

Status: proposal, revised after design review (findings D1–D11, against 9f61ca29). It replaces
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
   union, at the oldest plausible stamp, and the folder never wins over them.
2. **A seq is used once per chain.** This Mac publishes under a chain id. When a load can't prove
   that its state knows every seq the chain has used, it mints a new chain before writing anything.
3. **Every hold has an age limit**, counted from when the file was first seen and kept with the file
   whatever the listing later says (pending, damaged or gone).
4. **Settling is per data type.** A type that's off isn't part of a rebuild. When it's turned on, it
   is judged by the journal.

Consequence: what a rolled-back or rebuilt Mac sends is only what its user changed, stamped by one
monotonic clock. It can't collide with a batch already written.

## 1. The local edit journal

**Entry.** `(scope, key) → { v: value | null, h: HLC }`, holding the latest edit to that key. A
deletion is `v: null`. Entries are keyed by scope as well as key, so a key can't be published into
the wrong profile.
- When a profile retires (Stop Syncing for it, or the profile is deleted), its entries are dropped.
  Re-adding a profile with the same sync id then can't publish old deletions (D10).

**Where it lives.** In the store's persisted data (the local store, not `sync-state.nns`), so
losing or rolling back the sync state never touches it.

**Durability (D4).**
- **Write-through for user edits.** The journal is its own small document, written synchronously
  with each user edit. It does not go through `persist.ts`'s 800 ms debounce. A crash right after an
  edit keeps its entry.
- **Generation.** Every journal write increments a generation, stored twice: in the journal and in
  a separate one-line document. On load, a journal that is unreadable, missing, or older than the
  stored generation is lost.
- **On a lost journal**, every type whose store was edited since the last confirmed publish runs as
  a union. Local differences are published at the oldest plausible stamp: `Clock.at(time of the
  journal's last durable write)`, older than anything made after it. Local items the folder lacks
  are never deleted. That is the old union-on-join behaviour, and nothing is lost to folder-wins.
  Two generation documents that disagree in a way that can't happen count as lost.

**How it's written.** A store middleware, wrapping `set`, writes entries for every mutation not
tagged `fromSync` or `restore`. A new command can't forget it.
- **Value diff.** Entities are compared by value, not identity (D5): bookmark nodes, settings,
  profiles, pins, groups and history entries are compared in their extracted form. Each changed
  entity maps to its sync key through the same functions the adapters use, moved to a shared module
  so the adapter and the journal can't disagree.
- **Tags.**
  - Sync applies run under `fromSync`. Settings and pins already do; bookmarks, history and profiles
    get the same flag.
  - The launch hydrate runs under `restore`.
- **NativeStore** (D11). When it owns the workspace, the journal is kept on the Swift side, which
  sees each command and its per-key `fromSync` flag. Replica revs that reach JS carry the set of keys
  they changed, with a tag per key, so JS never journals a sync key a rev touched.
- **One clock** (D9). Stamps come from the sync clock (`doc.clock`, the same `Clock` the scopes
  use), never from a second clock with the same device suffix. Two clocks could mint the same HLC
  for different values, and `mergeRecord` keeps the first one to arrive (scope.ts:143). The journal
  saves its newest `h`, and on load the clock observes it.

**Bookmarks: Chrome's model is the source** (D5). User edits made inside Chrome (the extension
`chrome.bookmarks` API, Chrome's importers) arrive only when `lib/bookmarks.ts` re-reads the
tree. So does the echo of sync's own pushes.
- At extract level, each read journals `diff(fetched tree, shadow)` per node, by value. The shadow is
  the tree the store last held for that profile.
- The diff is taken before `readTree` replays pending store edits over Chrome's tree
  (lib/bookmarks.ts:249-251). A concurrent extension edit therefore isn't hidden. A node that
  differs between fetched and shadow is journaled and wins over the replay.
- Echo filter: a pushed-values table (`node → value sync last pushed`). A fetched node equal to its
  pushed value isn't journaled. Entries clear after the next successful read, so they can't
  suppress a later real edit.
- The first read at launch with no shadow (the cache is debounced by 2 s, so it can be behind) is
  tagged `restore`. It sets the shadow and journals nothing.

**Passwords: Chrome's Login Data is the source** (D1–D3).
- **Ledger.** `pwLedger: key → { p: digest of the password, modified }`, kept in Solara's data
  folder beside the journal. It records each login as last published or applied by sync, with
  Chrome's `date_password_modified` read back after the write.
- **Detection by ledger only.** On each read:
  - a key not in the ledger is a local addition;
  - a ledger key missing locally is a local deletion;
  - a key whose digest differs from the ledger's is a local edit.

  The raw modified date is never compared or used as a stamp. A username-only rename
  (saved_passwords_presenter.cc:870) shows up as a deletion of the old key and an addition of the
  new one, whatever its date.
- **Stamp.** After the pull, the clock observes the key's record `h`, and the stamp is
  `max(Clock.at(min(modified, now)), successor of record h)`. That is newer than everything this Mac
  has seen of the key. A remote clock ahead by an hour can't make a real change here "not newer".
- **Deletions versus newer edits elsewhere.** A deletion is published only when the key's record
  `h` is still the one the ledger saw. If the record changed since, by another Mac's edit, the
  edit wins: the login is applied back and the deletion is dropped. So a deletion noticed days
  later (passwords were unreadable) never beats a newer edit made elsewhere.
- **Ledger identity.** The ledger stores an identity for its Login Data file: the file's inode and
  creation time, plus a random id the ledger writes into its own side file. On a mismatch (Login
  Data replaced, razed, or restored without its ledger), the passwords type rebuilds, and nothing in
  it is claimed as an edit. The ledger is re-seeded with the keys whose local value equals their
  record. Keys that differ take the folder's value. Keys the folder lacks are kept locally and get
  added to the journal at the oldest plausible stamp.
- **Mass-drop refusal.** A read that drops more than half the ledger's keys, and more than 5, is
  taken as an unreadable read: nothing is published or applied from it, and the Sync pane says
  passwords couldn't be read. Two such reads in a row a day apart, with Chrome's own count agreeing,
  are accepted as real.
- **Apply uses the ledger** (D3). `passwordsAdapter.apply` (adapters.ts:521) checks the ledger, not
  base. It skips a login only if the ledger says it was changed here. With base lost, a differing
  login is therefore applied, and published only if it's an edit by the ledger.
- **Upgrade.** The ledger is seeded from keys equal to their record. A login that differs is neither
  claimed nor overwritten until its record next changes; it then takes the folder's value. It is
  not republished as new.

**Extensions** already record intents (`host.intents()`). Those become their journal entries.

**History.** Visits are append-only and carry their own times. A history delete is a store command
and is journaled.

**Clearing an entry.** An entry is cleared when the op carrying exactly its `(scope, key, h)` has been
written to the folder (`flush` succeeded). A newer edit replaces the entry, so a clear for the older
stamp leaves it alone. A crash between write and clear re-sends the same op, which changes nothing.

**Publishing.** `publishAdapter` no longer finds edits by diffing against base. For each entry of
the adapter's prefix, it publishes `{k, h: entry.h, v: current value or null}`:
- If the record already has `h >= entry.h`, the entry is stale and is cleared.
- Bookmark positions are computed against the records wherever base lacks a sibling (D6). Today they
  come from base (adapters.ts:283-288), so a lost base renumbers everything.

**Applying.** Every key with a difference and no live entry is applied with the folder's value.
- A key with a live entry is never applied over (D11), in every adapter, `adoptRemoteOnJoin`
  included (scope.ts:209).
- **Bookmarks apply rebuilds the tree from what's visible** (D7), so a partial replica removes the
  rest (B70). It now keeps a local node that isn't visible only when that node's key was never in
  this Mac's records and the node's origin isn't covered by the vv (a local item not yet published).
  Any other invisible node is a deletion (a tombstone, or one collected by a snapshot, scope.ts:164-169)
  and is removed. So a Mac returning after 45 days still drops bookmarks deleted meanwhile.

**Joining and first sync.**
- When sync is turned on, or a profile or type is first linked, every existing local item gets an
  entry stamped `Clock.at(editedAt)` where the item has one (history, bookmark `addedAt`), otherwise
  the turn-on time. Passwords seed the ledger as above. That keeps today's union on join.
- On a rejoin after Stop Syncing (D10), an existing entry newer than that stamp is kept, so an edit
  made while sync was off keeps its time.

## 2. Publishing chains

- `doc.deviceId` stays the device's identity for `dev:` records, the device name and its tabs.
- Batches are published under `chain = <deviceId>.<n>`. vv, extra and seq are kept per chain. A chain
  is just another device string, so there's no format change for readers.
- **The chain is kept at load only when the state proves it is current.** All of these must hold:
  - the sealed state loaded, and its batch journal is readable;
  - after the first pull, `vv[chain]` doesn't exceed the state's seq, and no snapshot's vv does;
  - the first pull lists no file unknown to the state as pending or damaged;
  - the phrase wasn't just re-entered, and the ThisDeviceOnly key was present at unlock (D8). A
    Migration Assistant copy keeps `deviceId` (engine.ts:1025) and its state, but not the
    this-device-only Keychain item. It therefore always mints a chain, so twins never share one.
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
- After 10 minutes a file stops holding anything. The type then applies what it has. With D7's apply
  rule, nothing it can't see is removed unless it was deleted, and nothing local is published as
  deleted without a journal entry.
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
  changes the old login's password meanwhile, that edit beats the deletion (§ 1, Passwords). Both
  logins then survive, the renamed one and the changed one. Nothing is lost, and the user sees two
  entries.
- **A long-offline Mac's edit** has its edit-time stamp, so it loses to a later edit elsewhere.
  Passwords are the exception: a detected password change is stamped newer than its current record.

## Migration

- **Journal at upgrade.** It starts empty, and no edits are claimed. An older build's edits that
  weren't published before the upgrade are taken as stale. That includes edits made during an
  old-format rebuild (B-old). It's a one-time window of a few seconds, since an old build publishes
  within 3 s of an edit.
- **Password ledger at upgrade.** Seeded from keys equal to their record (§ 1).
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

The middleware wraps `set`, so every JS store change passes through it, including the direct
`useBrowser.setState` calls in 13 non-test files. The risk is changes that aren't edits and carry no
tag.

| Path | Handling |
| --- | --- |
| Launch hydrate (`browser.ts hydrate`) | `restore` tag |
| Bookmarks re-read from Chrome's model (`lib/bookmarks.ts`), including extension and importer edits | value diff against the shadow, before the replay; pushed-values echo filter; first read at launch is `restore` |
| NativeStore replica revs | per-key tags; journal on the Swift side |
| Imports (`components/import/apply.ts`) | store commands are journaled; passwords go through the ledger |
| Engine events on pins (page title `ti`, favicon) | journaled: this device's observation, published today too |
| `bookmarksReady`, `historyReady` and other flags | no sync key, ignored |

## Holes I still see

- **A missed path.** A native mutation reaching the store with neither a tag nor a value change in a
  synced field. The value diff makes this hard to miss, but each native path above gets a test.
- **Ledger identity.** An inode and creation time can survive some restores (restoring Login Data
  in place). The side-file id covers a restore that brings back an older ledger. A restore of both
  together is consistent anyway.
- **Mass-drop refusal** delays a real bulk delete by a day.

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
| oracle 212, 265, 43 | tie repair rewrites whole records | separate tie-by-key fix |
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

Every repro above becomes a failing-first test in engineRecovery. Each review finding gets its
own:
- **D1:** a username-only rename after an older tombstone of the new key keeps the login. A change
  here while another Mac's clock runs an hour ahead still wins.
- **D2:**
  - Login Data replaced: a rebuild, and no mass deletion.
  - A read dropping most keys is refused.
  - A deletion noticed after a newer remote edit loses to the edit.
  - Upgrade doesn't republish every login.
- **D3:** with base lost, a differing login is applied, and the passwords type settles.
- **D4:**
  - A crash 100 ms after an edit keeps its entry.
  - A rolled-back journal document is detected by generation and falls back to union, and a
    bookmark the folder never had isn't deleted.
- **D5:**
  - Adopting an unchanged tree journals nothing.
  - The first read at launch is `restore`.
  - An extension edit concurrent with a pending store edit is journaled.
  - A pushed value stops filtering after the next read.
- **D6:** a lost base doesn't renumber positions.
- **D7:**
  - A partial replica doesn't wipe local bookmarks.
  - A Mac back after 45 days drops collected deletions.
- **D8:** a copied Mac (same `deviceId`, no Keychain item) mints a chain.
- **D9:**
  - One clock: no two values with the same `h`.
  - The counter carry: the review's overflow repro.
- **D10:**
  - Re-adding a profile with the same sync id publishes no old deletions.
  - A rejoin keeps a newer entry.
- **D11:**
  - A NativeStore rev tagged per key.
  - Apply skips live entries, `adoptRemoteOnJoin` included.
- **Journal basics:**
  - every store command journals;
  - `fromSync` and `restore` don't;
  - an entry clears only on its own `(scope, key, h)`.
- **Chains:**
  - each mint condition;
  - re-sends under a new chain;
  - older-build readers refused by `v`.
- **Oracle:**
  - edit stamps become edit times;
  - the `sentAt` and `unsent` relaxations are tightened back;
  - new ops for a journal document rolled back, Login Data replaced, a twin Mac, and a profile
    re-added.

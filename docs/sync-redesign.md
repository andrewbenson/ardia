# Sync redesign: the edit journal and publishing chains

Status: proposal, for design review before any code. It replaces the load guard described in
docs/sync.md (§ After a load) as of 095f633c. Four reviews and the convergence oracle kept finding
new holes in that guard because it decides "changed here" by comparing snapshots of the store
(notes and baselines). Those snapshots are taken at the wrong time, from the wrong inputs, or are
lost with the state. This design removes that inference.

## The problem in one paragraph

A Mac's sync state (`sync-state.nns`: records, base, version vectors, seq) can come back lost
(unreadable, foreign, malformed) or older than the folder (a lost save, a restored backup, a
corrupted journal). Then two things go wrong:
- Base no longer says what this Mac last published or applied. Any local value that differs from
  it looks like an edit, and goes out stamped "now", over newer edits made elsewhere.
- The seq no longer says which numbers this Mac has used. The next batch can reuse one with
  different contents.

The current guard guesses which differences are real edits. Every guess has a counterexample.

## Invariants

1. **Only the edit journal says "changed here".** A local value or deletion is published only if
   the local edit journal holds an entry for its key. The op carries the entry's stamp, which is the
   HLC at the moment of the edit, not at publish time. A difference from base with no journal entry
   is never published. The folder's value is applied over it.
2. **A seq is used once per chain.** This Mac publishes under a chain id. When a load can't prove
   that its state knows every seq this chain has used, it mints a new chain before writing anything.
3. **Every hold has an age limit**, counted from when the file was first seen and kept with the file
   whatever the listing later says (pending, damaged or gone), so no hold outlives its limit.
4. **Settling is per data type.** A type that's off isn't part of a rebuild. When it's turned on, it
   is judged by the journal, like everything else.

Consequence of invariants 1 and 2: whatever a rolled-back or rebuilt Mac sends was chosen by its
user, and carries the stamp of that choice. It can't be stamped newer than an edit another Mac made
later, and it can't collide with a batch already written.

## 1. The local edit journal

**What an entry is.** `key → { v: value | null, h: HLC at edit time }`, one entry per sync key,
holding the latest edit. A deletion is `v: null`.

**Where it lives.** With the data it describes, in the store's own persisted state, never in
`sync-state.nns`. So losing or rolling back the sync state never loses or rolls back the journal. A
whole-profile backup restore rolls both back together, which is consistent: the entries it restores
re-send with their old stamps, and those lose to anything newer.

**How it's written.** By the store, at edit time, for every mutation not marked `fromSync`. It's
written as a store middleware, not inside each command, so a new command can't forget it:
- The middleware compares the changed slice before and after, by object identity per entity
  (bookmark node, setting, profile, pin, group, history entry). It maps each changed entity to its
  sync key with the same key functions the adapters use. Those move into a shared module, so the
  adapter and the journal can't disagree.
- Sync applies run through `fromSync` (settings and pins already do; bookmarks, history and profiles
  get the same flag) and are never journaled.
- The stamp comes from the sync clock (`Clock.tick()`), saved with the journal. It is monotonic and
  newer than every remote stamp this Mac had seen when the user made the edit. That is the HLC rule.
- With the Swift NativeStore owning the workspace (`nativeWrite`), the journal is kept on the Swift
  side, through the same commands.

**Sources the store doesn't own.**
- Passwords live in Chrome's Login Data, and the user edits them in Chrome's UI. `readPasswords`
  will return each login's `date_password_modified`. The store keeps a side table `pwApplied: key →
  modified time` written when sync applies a password, and also kept outside the sync state. A login
  counts as journaled when its modified time is later than both `pwApplied` and the stamp of the
  record it was last published or applied as. Its stamp is that modified time.
- Extensions already record intents (`host.intents()`). Those become their journal entries.
- History visits are append-only and already carry their own times (`editedAt`). A history delete
  is a store command and is journaled.

**When an entry is cleared.** When the op carrying exactly that `(key, h)` has been written to the
folder (after `flush` succeeds). A newer edit to the same key replaces the entry, so a clear for the
older stamp leaves the newer one alone. A crash between the write and the clear re-sends the same
`(key, h)`. Merging that changes nothing.

**How publishing changes.** `publishAdapter` no longer diffs extraction against base to find edits:
- For each journal entry of the adapter's prefix, it publishes `{k, h: entry.h, v: current
  extraction value or null}`.
  - It uses the current value, not the journaled one, so derived fields such as positions are
    whatever the store computes now.
  - If the record already has `h >= entry.h`, the entry is stale: it's cleared, and nothing is sent.
- Every key with a difference and no entry is queued for apply, so the folder's value wins.
- Base keeps one role only: telling apply what this Mac last applied (the passwords adapter's
  conflict check). It no longer decides what is published.

**Joining and first sync.** When sync is turned on, or a profile or type is first linked, every
existing local item gets a journal entry. Its stamp is `editedAt` where an item has one (history,
passwords, bookmark `addedAt`), and otherwise the turn-on time. That reproduces today's union on
join, and `adoptRemoteOnJoin` stays as it is.

## 2. Publishing chains

- `doc.deviceId` stays the device's identity for `dev:` records, device names and tabs.
- Batches are published under `chain = <deviceId>.<n>`, and vv, extra and seq are kept per chain.
  Readers treat a chain like any device. That's no format change: a device id is just a string, and
  older builds already handle many devices.
- **The chain is kept at load only when the state proves it is current.** All of these must hold:
  - the sealed state loaded and its journal batches are readable;
  - the first pull lists no unknown file as pending or damaged;
  - `vv[chain]` after the pull doesn't exceed the state's seq.
  Otherwise a new chain is minted before the first write:
  - a lost state;
  - a rollback (own seqs found in the folder or in a snapshot's vv);
  - a corrupt sync journal;
  - anything still downloading at the first pull.
- Re-sends (the sync journal's batches, an older build's revived batches) keep their ops and stamps
  and get new seqs under the new chain.
- Nothing waits for downloads to protect seqs anymore. The ten-minute fresh hold goes away.
- **Cost:** one new vv entry per load that can't prove currency. A placeholder at launch is common,
  so this happens often. Compaction already removes covered logs. A retired chain's vv entry is
  dropped from snapshots once no log of it is left and it is older than the tombstone hold (90
  days), the same rule that already bounds a replay.

## 3. Holds, all bounded

Only one hold remains. A rebuilding type doesn't apply while its pull is incomplete, because the
bookmarks adapter rebuilds the whole tree from what's visible (B70).
- Each unknown file that isn't readable gets a first-seen time, saved in the state and kept
  whatever its listing state is. That closes Q1: today a damaged entry only ages while the file is
  reported damaged.
- After 10 minutes the file stops holding anything. The type then applies what it has, and the Sync
  pane shows "Waiting for N files" until the file arrives or is given up after a day.
- Under invariant 1, a local item that's missing only because a file was late is never published
  as deleted. Even so, the bookmarks adapter should stop removing nodes that aren't visible and have
  no tombstone. That is a small adapter change, proposed alongside this.

## 4. Per-type settle

A rebuild is now per data type, not per adapter prefix:
- `rebuild.types` lists the types still rebuilding.
- A type settles once its pull is complete or past its limit, its adapters have extracted, and
  nothing of it is unapplied.
- A type that's off isn't listed. Turning it on adds it, and its local differences are then judged
  by the journal. An edit made while the type was off is journaled, so it is published; anything
  else takes the folder's value (C2).
- The marker is deleted when the list is empty, so it no longer stays open while a type is off (C1).

## Migration

- **No journal means no edits claimed.** On upgrade, the store starts with an empty journal.
  - An older build's edits that weren't published before the upgrade are taken as stale and
    replaced by the folder's value. This includes edits during an old-format rebuild (B-old).
  - This is a one-time loss window of a few seconds per Mac: an old build publishes within 3 s of an
    edit.
  - The alternative is to keep diff-based publishing for one launch. That brings back every bug
    above, so I don't recommend it.
- `doc.rebuilding`, `rebuildBaseline`, `rebuild.noted` and `heldOutbox` are read and then dropped.
- Older builds reading a newer state ignore `chain` and `rebuild.types`. They see their old device
  id with a stale seq, which is the same exposure as any downgrade today. The fix is to give older
  builds the B35 refusal: bump `v` on sync.json so they leave it alone.

## What's removed

The launch and load notes, `baselines`, `notedFor`, `keepNotes`, `noteDelivered`/`fromFolder`,
`changedHere`, `backToBase`, `heldBack`, `EDITABLE_WHILE_UNREADABLE`, the fresh download hold and
the stand-in base. The guard keeps:
- pull-first on a fresh load;
- re-sending held and revived batches under the current chain;
- per-type settle.

## Checked: Chromium's `date_password_modified`

Read in this tree's Chromium (`components/password_manager/core/browser`):
- **Password manager: add.** `saved_passwords_presenter.cc:88-89` (used by the Settings add-password
  dialog) sets `date_created = date_password_modified = Now()`.
- **Password manager: edit.** `saved_passwords_presenter.cc:857-861`: when the password changes,
  `date_password_modified = Now()`.
- **Password manager: username-only edit.** It keeps the old `date_password_modified` and goes
  through `UpdateLoginWithPrimaryKey` (`:870-874`). That's a different key (`origin\nusername`).
  The new key shows up with an old time and the old key disappears.
- **Note-only edit.** It doesn't touch the modified date, and we don't sync notes.
- **Saving on a form.** `form_saver_impl.cc:86, 127, 139, 157`: a first save, an update after
  sign-in, and the change-password and generated-password flows all set `Now()`. These are the
  paths the change-password flow without Chrome sync goes through.
- **CSV import.** `import/password_importer.cc:648` adds new credentials through
  `presenter_->AddCredentials` (the add path above, `Now()`). A conflict the user chooses to replace
  goes through the presenter's edit path (`Now()` when the password differs).
- **Database.** `login_database.cc:265, 1510` write the field as given. Migration v30
  (`:853-858`) set old rows to `date_created`.

**What the design does with it.** "Edited here" is tracked per key against a presence ledger
(`pwApplied: key → modified time`), kept with Chrome's data and outside the sync state:
- **A key not in the ledger** is a new local login and is an edit. That covers a username-only edit
  (the new key) whatever its modified time.
- **A ledger key that is now missing locally** is a local deletion. Chrome keeps no tombstone, so a
  deletion has no modified time, which is why the ledger tracks presence and not only times.
- **A ledger key whose modified time is later than the ledger's** is a local edit.
- **Every apply and publish** updates the ledger with the time read back from Chrome after the
  write, so sync's own writes never count as edits.

Remaining exposure: a write path that changes the password without updating the date. I found
none in the paths above. A new one in a Chromium update would show up as a missed edit, and a test
that edits through each path above pins it.

## Checked: store mutations that would bypass the middleware

The middleware wraps the store's `set`, so every JS store change passes through it, including the
direct `useBrowser.setState(...)` calls in 13 non-test files. The risk is the opposite: changes that
aren't user edits but carry no `fromSync` tag, and user edits made outside the JS store. Found:

| Path | What happens | Handling |
| --- | --- | --- |
| Session restore and hydrate (`browser.ts hydrate`) | loads saved state at launch | tagged `restore`: not an edit |
| Bookmarks: Chrome's BookmarkModel is the source. `lib/bookmarks.ts` re-reads a profile's tree on `onBookmarksChanged` and adopts it whole | user edits made in Chrome itself (extension `chrome.bookmarks` API, Chrome's own importers) arrive only this way. Sync's own applies, pushed to the engine by `push(s)`, come back the same way as an echo | the adopt diff is journaled, except nodes whose new value equals the last value sync pushed for them (a pushed-values table, kept until the echo is seen) |
| NativeStore (`nativeStore.ts`): when active it owns settings and downloads; JS gets replica revs | sync's `updateSettings(…, { fromSync })` goes to Swift and returns as a rev without the tag | journal on the Swift side, where the command and its flag are seen, or carry the flag on the rev. The Swift port needs this anyway |
| Imports (`components/import/apply.ts`) | bookmarks, history and pins go through store commands. Passwords go straight to Chrome (`savePassword`) | store commands are journaled; passwords via the ledger (not in it, so an edit) |
| Engine events for tabs and pins (page title `ti`, favicon) | automatic, not user edits | journaled like any non-sync change: they're this device's observation and are published today too |
| `bookmarksReady`, `historyReady` and other flags | not synced data | ignored: no sync key maps to them |
| `sync/adapters.ts` and pinned `fromSync` applies | sync's own writes | tagged `fromSync` |

So no user edit path bypasses the journal. What the design adds instead is two echo filters, one
for bookmarks and one for NativeStore, plus the restore tag. Each needs a test: an echo must not be
journaled, and a real edit made while an echo is pending must be.

## Holes I can see

- **A missed mutation path.** An edit that bypasses the middleware is never published.
  - The middleware design makes that a store-wide default, not a per-command duty.
  - A test walks every store command with a non-sync change and asserts a journal entry. The
    oracle's edit ops go through real commands.
  - Native paths are the risk: Chrome's bookmark API reached from extensions, and NativeStore
    commands. Each needs its own test.
- **Passwords by modified time.** This depends on Chrome updating `date_password_modified` on every
  user change and on `pwApplied` being saved before the next read. If Chrome leaves it unchanged
  (some import paths do), that edit isn't published. I'd verify against Chrome's code before
  committing to it.
- **Clock jumps.** An edit stamped while the wall clock was far ahead can win later edits. That's
  the same as today (§ Clock skew), and HLC monotonicity keeps it bounded to that skew.
- **Concurrent edits stay last-writer-wins by edit time.** A long-offline Mac's edit loses to a
  later edit elsewhere even if it's published later. That is the intended semantics.
- **The position-tie repair.** It rewrites whole bookmark and pin records. Under invariant 1 a
  repair is not an edit, so it is no longer published at all: ties persist until the tie-by-key fix
  lands. That fix is separate (agreed) and still needed.

## Repros mapped to invariants

| Repro | What it shows | Removed by |
| --- | --- | --- |
| revsync4 R-baseline | baseline taken before stores are ready | 1: no baseline |
| revsync4 R-passwords | rebuilt passwords republish the old one | 1: not journaled (pwApplied) |
| revsync4 R-unapplied | rebuild ends with keys unapplied | 1 + 4: unjournaled keys never publish; settle requires none unapplied |
| revsync4 R-lock | throw during baseline capture locks the Mac | no capture step |
| revsync4 R-pending | pending file holds the rebuild for 24 h | 3: 10-minute limit; deletions are journaled, so they publish anyway |
| revsync4 R-rollback | readable rollback keeps the old base | 1 |
| revsync4 R-rollback-outbox | rollback outbox reuses a seq | 2 |
| guard-review r1 | rollback, own batch pending, seq reused | 2: pending at first pull, so a new chain |
| guard-review r2 | relaunch undoes edits made after the loss | 1: journal persists with the store |
| guard-review r3 | healthy relaunch reverts the latest choice | 1: the entry carries the edit's stamp |
| guard-review r4 | rollback, remote pending, stale resend | 1 |
| guard-review2 A, A2, A3 | rollback after compaction resends stale | 1: no evidence needed |
| guard-review2 B-old | old-format rebuild loses an edit | migration (accepted, one-time) |
| guard-review2 C1 | marker open while a type is off | 4 |
| guard-review2 C2 | edit while the type is off is overwritten | 1 + 4 |
| guard-review2 D | stubbed note misses the shared profile | 1: no note |
| guard-review2 E | own batch pending past 10 minutes, seq reused | 2 |
| guard-review3 r1, r1b | setting chosen while unlocking or locked is lost | 1: journaled at edit time |
| guard-review3 r2 | launch note stuck behind passwords | 1: no note |
| guard-review3 r3 | passwords read with the type off | no note; passwords read only when on |
| guard-review3 r4 | launch cost with large history | no note |
| guard-review4 Q1 | damaged-then-pending holds applies forever | 3: first-seen age kept per file |
| guard-review4 Q3, Q3-pre | rolled-back password resent over newer | 1: pwApplied lives outside the sync state |
| oracle 35309 | corrupt sync journal, seq reused | 2: a corrupt journal can't prove currency |
| oracle 25066 / B70 | partial apply wipes bookmarks, published as deleted | 1 + 3 (+ the adapter change) |
| oracle 212, 265, 43 | tie repair rewrites whole records | separate tie-by-key fix |

## Today's accepted residuals, one by one

| Residual (as of 095f633c) | Under this design |
| --- | --- |
| A healthy Mac waits up to 10 minutes after launch while a file is pending or unreadable | Gone. Nothing waits to protect seqs. A healthy Mac publishes in its first cycle; if the first pull can't prove its chain is current, it publishes under a new chain at once. The only remaining hold is a rebuilding type's applies, and it doesn't apply to a healthy Mac |
| Healthy relaunch: a setting matching another Mac's unpulled old value is taken for a rolled-back copy (R3) | Gone. Whether to publish comes from the journal entry, not from comparing values |
| A rolled-back state resends an older password it couldn't apply (Q3, Q3-pre) | Gone. A password counts as edited here only when its modified time is later than `pwApplied`, which lives with Chrome's data, outside the sync state. The rolled-back copy was applied by sync, so it's never sent |
| Passwords saved while a rebuilding Mac can't read them are taken as stale | Gone. Chrome stamps the change with a modified time later than `pwApplied`, so it's an edit whenever passwords can be read again, however long that takes. It depends on Chrome's `date_password_modified`; see Holes |
| A rolled-back state that wrote nothing after the backup goes undetected once compaction removed what it took (A2) | Gone. Detection isn't needed: the stale value has no journal entry |
| An old-format rebuild loses its baseline (B-old) | Becomes the one-time migration window (see Migration): an old build's unpublished edits at the moment of upgrade. It can't be removed: the old build kept no record of what it edited |
| Own batch still downloading after 10 minutes reuses its seq (E) | Gone: a new chain |
| Rebuild marker stays open while a type is off (C1) | Gone: per-type settle |
| Seed 35309: a corrupt sync journal reuses a seq | Gone: a sync journal that won't open can't prove the chain is current, so a new chain |
| Tombstones dropped after 45 days come back from a Mac away longer | Narrower: a returning Mac sends only journaled edits, so a stale item it still has is never re-published. A log replayed after the hold still can bring one back, as today (docs/sync.md § Compaction) |
| Tie repair rewrites whole records | Not a sync-guard matter: the separate tie-by-key fix |

## Test plan

- Every repro above becomes a failing-first test in engineRecovery. Those written against the
  current guard are rewritten wherever the guard's internals no longer exist.
- Journal tests:
  - every store command journals;
  - `fromSync` doesn't;
  - an entry clears only on its own `(key, h)`;
  - a crash between write and clear re-sends the same op.
- Chain tests:
  - each of the four mint conditions;
  - re-sends under a new chain;
  - old-build readers.
- The oracle's choice ordering already uses publish stamps. Its edit stamps will now equal the edit
  time, so the `sentAt` and `unsent` relaxations can be tightened back to the edit itself.

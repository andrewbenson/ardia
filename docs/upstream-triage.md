# Upstream triage

Solara no longer merges upstream Ardia wholesale. Each triage reads the upstream commits since the last one and
sorts them into what to port now, what the Swift app should carry later, and what to skip.

## 2026-10-26: d055df07..bc3c48f8

- **Range:** `d055df07` (2026-10-26 00:22, "Nightly 0.2.41-nightly.5") to `bc3c48f8` (2026-10-26 13:52, "Site:
  download 0.2.41"), 215 commits, all of `git log HEAD..upstream/main` on top of merge base `c508a9f3`.
- **Last reviewed upstream commit:** `bc3c48f8cb2ad79d810a5f6392535d888fb151e3`. Start the next triage with
  `git log --reverse bc3c48f8..upstream/main`. Since Solara doesn't merge any more, `HEAD..upstream/main` will
  keep listing these 215 commits.

### Summary

This range is mostly upstream reorganizing its code: the RN app split into components, state, platform and lib
layers; design tokens; one-type-per-file splits; the ArdiaCore pod renamed from `ArdiaCore*` to `Ardia*`; and the
engine API rebuilt as one Expo module per domain. On top of that come the ardia.dev site, its demo, and the 0.2.41
release. **The range has no Chromium or Helium bump.** Both sides are on 156.0.8078.47, and the 0.2.41 release notes
cover the whole cycle, most of which Solara already has from merge `994a9b93`.

8 commits are worth porting now, but only as hand ports of the behavior. Five real bugs that Solara has today are
buried in them: permission and download events arrive twice; a withdrawn permission prompt can still show up; deleting
a profile leaves its WebKit data on disk; WebKit's store removal can crash on a cold start; and the restored first
page paints about 80 ms late. One more is engine hardening that has to travel with a larger change. 13 commits feed
the Swift port later. The other 194 are skipped.

Almost no commit applies as it is. `git apply --check` fails on every candidate. In most cases that's because of
upstream's renames and splits, not because the two codebases have truly diverged. For example, upstream's
`ArdiaEarlyWindow+Pages.mm` is HEAD's `ArdiaCoreEarlyWindow.mm`, upstream's `EngineCall.swift` is HEAD's
`CefModule.swift`, and `packages/ardiacore/src/engine/api.ts` was never in HEAD because b9a9e0ec created it. Each item
below names its HEAD target and how big the hand port is.

### PORT NOW, in priority order

1. **Every Chromium permission and download event reaches JS twice.** The fix is inside b9a9e0ec (the event channels
   part).
   - In HEAD, `packages/ardiacore/ios/CefModule.swift:8` and `packages/ardiacore/ios/WebKitModule.swift:8` both
     declare `onDownload`, `onPermission` and `onPermissionDismissed`.
   - `packages/ardiacore/src/module.ts:134-165` subscribes to both modules.
   - Expo's legacy emitter delivers an event to every module that declares its name. So a camera or microphone prompt
     shows again after you allow it, and each download update is handled twice. Upstream's acceptance tests
     `camera-mic-allow` and `permission-element-allow` failed on this.
   - **Port:** give the WebKit module its own event names (for example `onWebKitDownload`, `onWebKitPermission`,
     `onWebKitPermissionDismissed`) in `WebKitModule.swift` and in the emits in `WebKitHub.swift`. Then point
     `webKitListener` in `module.ts` and the types in `native.ts` at them. That's about 10 lines.
   - Don't port b9a9e0ec itself. It rebuilds the whole engine API.
   - Reproduce it first in a hidden instance: one Chromium permission request should log two `onPermission`
     deliveries.
   - Risk: low.
2. **WebKit's store removal crashes on a cold start.** The fix is in 0c545880, and eb461d30 keeps it.
   - `WKWebsiteDataStore.remove(forIdentifier:)` and `fetchAllDataStoreIdentifiers` crash with SIGSEGV in
     `WTF::RunLoop::dispatch` when nothing has started WebKit yet.
   - HEAD calls `remove(forIdentifier:)` at `packages/ardiacore/ios/WebKitHub.swift:487`. Profile data cleanup can
     reach that line at launch, before any WebKit page opens (`apps/browser/src/lib/profileData.ts` drains
     `orphanedProfileData`).
   - **Port:** create a non-persistent store before either call. That's a few lines.
   - Risk: low.
3. **Deleting a profile leaves its WebKit data on disk.** The fix is bd692cb2 plus eb461d30. Port only their net
   result.
   - HEAD's `WebKitHub.deleteProfileData` (`WebKitHub.swift:480-489`) calls `remove` while open tabs, parked views and
     pending prompts still hold the store. The removal fails with "in use".
   - It also creates a store just to delete it.
   - **Port:**
     - Release the store first: close its views and tabs, dismiss its prompts, close its resume host, and cancel its
       WebKit downloads.
     - Clear its data, then retry the removal for up to 3 seconds.
     - If that fails, answer `remaining: ["WebKit data"]` so the profile stays in `orphanedProfileData` and is retried
       at the next launch.
     - For the rest of the session, a deleted profile gets a non-persistent store.
     - Skip the store when there's none on disk.
     - Add eb461d30's recheck in `lib/profileData.ts`: orphan cleanup never deletes a profile that is in use again.
   - **Do not port** 0c545880's store-generation scheme or its `WebKitStoreRemovals.json` queue. eb461d30 removed both
     because they lost data.
   - Hand port of about 80 lines across `WebKitHub.swift`, `WebKitModule.swift` and `lib/profileData.ts`, plus the
     acceptance checks `profile-data-deletion-fails` and `profile-data-retried-at-launch`. HEAD's `WebKitHub.swift`
     holds what upstream split into `WebKitDownloads.swift` and others.
   - Risk: medium, because this deletes user data. It needs a Codex review before and after.
4. **The restored first page paints about 80 ms late in the early window.** The fix is ed393289.
   - The regression came in 505eaa8d (launch tab restored through `restoreTab:`), which is in HEAD.
   - **Port**, two lines in `packages/ardiacore/ios/ArdiaCoreEarlyWindow.mm`:
     - In `ShowsLaunchOrigin` (line 849), change `committed &&` to `committed.length &&`.
     - In `attachPage:` (line 1368), set `page.hidden = NO;` before `[s.cover addSubview:page]`.
   - Upstream measured first paint going from about 490 ms to about 405 ms.
   - Risk: low. Back/forward survive a relaunch, and Clear History still applies.
5. **A permission prompt the site withdrew can still appear later.** The behavior comes from eaec8892.
   - In HEAD's `apps/browser/src/components/site/permissions.ts`, `drop(id)` filters the queues but not `orphans`.
     So a request from a tab that wasn't hosted yet survives its dismissal and is enqueued once the view arrives.
   - **Port:** also remove the id from `orphans` in `drop`. That's one line.
   - eaec8892 moved the whole queue into native code alongside a tab-id API rewrite. Don't port it.
   - Risk: low.
6. **Test seams in a shipping engine.** The fix is b995485d, plus 0104a48a for the carryover script.
   - In HEAD, `--ardia-test-bluetooth-chooser`, `--ardia-test-external-protocol-no-launch`,
     `--ardia-test-system-media-permission`, the media route provider and the profile gate are bare `HasSwitch`
     checks. A signed release build honors them.
   - b995485d puts every seam behind one gate. The gate opens only when all three hold: the build isn't signed for
     distribution, it runs on `--use-mock-keychain`, and `--user-data-dir` resolves to `--ardia-data-dir`.
   - b995485d's engine files merge cleanly. Only `docs/engine-build.md` and the conventions baseline conflict.
   - It depends on ea19c0b1 and d03f0572 (ArdiaLaunchConfig passes `--ardia-*` switches instead of the engine reading
     `ARDIA_*` with `getenv`). That changes how hidden test instances are launched (AGENTS.md's `--env ARDIA_*`
     recipe), the scripts in 36d14530, 28d06773 and 7270420d, and the carryover script (0104a48a).
   - **Smaller alternative:** keep the env contract and gate the bare switches with the safe-storage test gate HEAD
     already has.
   - Needs the chromium lock and an incremental build. Check that `chromium-safe-storage-name.patch` and
     `chromium-safe-storage-no-silent-reset.patch` stay unchanged, and get a Codex review.
   - Risk: medium. The test harness can break. Exposure is low, because exploiting it takes local argv control.

### PORT LATER INTO SWIFT

- **UI tokens and sharing (the native UI's design tokens in SolaraUI).** Commits 2eb7884e, 73f47007, 1f943c68,
  9d3f16be, d835b7ec, e97105a1, d370d7ce, a91d9381 and 160af35c.
  - One accent blue.
  - One red ("destructive") for every error, danger and capture mark.
  - Dia's menu item hover on every row.
  - One divider at Dia's separator color.
  - Two dark plates: panel and tooltip.
  - One ink for filled pills and badges.
  - One dialog shadow, with the popover keeping a lighter one.
  - Shared warning and success colors.
  - A 15 pt heading size.
  - Take the values from upstream's `components/ui/tokens.ts`.
- **Onboarding.** fe0abf35: every browser tile in "Where are you coming from?" shows an icon. It uses the installed
  app's icon when there is one, otherwise a bundled 256 px PNG instead of a globe, and the preview lists only browsers
  that are installed. The bundled Chrome, Firefox, Edge and Zen logos are third-party marks, so check that use before
  shipping them.
- **NativeStore.** da0e6ed3 gives every saved JSON document a schema version and forward migrations: a missing version
  counts as 0, a newer version reads as defaults, and the version key is written last. It's worth carrying into
  NativeStore's documents before their first format change. Don't port it into the RN layer: NativeStore owns that
  data now, and the commit also versions telemetry files Solara doesn't have.
- **Swift engine bridge.** 6cfc3d49 decides once whether a profile is private, from the engine's off-the-record flag,
  and puts every call in one table with a private-session policy.
  - In HEAD, the JS path already refuses every private engine call (`CefModule.swift:109`).
  - The native callers (`ArdiaCoreServices.mm:128`) deliberately serve the base profile, and upstream kept that
    behavior. So nothing leaks today.
  - Carry the single policy when the Swift core takes over engine calls.
  - HEAD has two different prefix checks: `"incognito"` in `CefModule.swift` and `"incognito:"` in `WebKitHub.swift`.
- **AGENTS.md.** b21114d2 adds a rule: after a fix, re-run only the checks that cover it, not the full suite or
  release sequence. AGENTS.md's "Verify in proportion" already says most of this. Copy it in only if the owner wants
  it spelled out for releases.

### SKIP (194)

| Group | Count | What it is |
| --- | --- | --- |
| Splits and renames (native and RN) | 60 | One type per file, the 400 and 600-line caps, `ArdiaCore*` → `Ardia*` (f2a157fc), ArdiaCore.h split, ArdiaLaunchConfig (d03f0572), PageEngine protocol (bc54fed6), the `chrome/browser/ardia` and `ac_browser*.mm` splits, Shaders, Sync, Core splits |
| RN state and platform layering | 32 | `state/`, `platform/` and hooks-and-actions passes, one store shape, launch environment through ArdiaLaunchConfig (ea19c0b1) |
| ardia.dev site, Meadow, demo, vitals | 32 | Solara has no site; `apps/site` and `apps/demo` are removed |
| Fixes to upstream-only refactors | 22 | e.g. 65e6658c (clearSiteData as an object after b9a9e0ec), b55a5f0e, 1c2be8da, a52ccc99, 2175d906, 719a1ecc, b0a4e99d, dfe29e8c: each fixes something an upstream refactor in this range broke, which HEAD doesn't have |
| Conventions, docs and agent tooling | 20 | docs/conventions.md and its checker, doc path updates, ui-snapshots, launch-variable scripts tied to ArdiaLaunchConfig |
| RN UI layering | 11 | components/ui pieces, motion curves, swatches |
| RN render-perf | 7 | Sidebar and row re-render cuts (5b931ed5, 65893a2a, a3bcc191), CLI pill mount, favicon page state, the group IP check (bd360993, the only one that applies cleanly) and upstream's ratchet ceilings; the behavior doesn't change and the Swift sidebar replaces these |
| Setup code and web demo | 6 | 8bc3770a, ede788a0, 2fd1072f, 881eb401, fb9f6410, 9ca432af: a code from the ardia.dev demo configures the app. It depends on the demo Solara removed, so skip it unless Solara gets its own site. If it's ever ported, carry ede788a0's checks with it: refuse raw input over 8× the cap, and never skip the search and privacy step |
| Upstream release | 4 | 0.2.41-nightly.5 and .6, the 0.2.41 release and upstream's prebuilt engine entry |

### Conflicts with Solara decisions

- **Identity and the rename.** `docs/upstream-merge.md` keeps upstream's names to keep merges small. Upstream's
  f2a157fc rename (`ArdiaCore*` → `Ardia*` in the pod) and the file splits mean every later upstream fix in
  `packages/ardiacore/ios` lands on paths that HEAD names differently. Ports are by hand from now on, whatever Solara
  names things.
- **No site or demo.** The setup code feature (8bc3770a and its follow-ups) only makes sense with ardia.dev's demo.
- **No telemetry.** da0e6ed3 versions `telemetry.json`, `telemetry-daily.json` and `telemetry-queue.json`, and the
  0.2.41 notes describe a daily "opened today" count. None of that comes over.
- **The native store owns data.** RN-side persistence changes (da0e6ed3, ec498ed5) belong in NativeStore, not in the
  RN layer.
- **The launch contract.** b995485d and ea19c0b1 change how test instances get their settings (switches instead of
  `ARDIA_*` env). Porting them means updating AGENTS.md's hidden-instance recipe and Solara's scripts in the same
  change.

# Solara native architecture

This doc covers moving Solara off React Native and JavaScript to a native Swift app. It records what the app is
today (§1), what it becomes (§2), how the owner's data carries over (§3), how both stacks run side by side during the
move (§4), the plan phase by phase (§5), the measurements to take before any code moves (§6, details in
[baseline.md](baseline.md)), and the risks and open questions (§7).

The owner has already decided the following, and the doc designs for them:
- Fully native, diverging from Ardia. Upstream UI changes stop merging for each surface once it goes native; engine
  and native-module work can still be merged.
- All Swift, macOS first. The core is a Swift package (model, GRDB persistence, sync, omnibox, importers) built on
  Observation and strict concurrency. SwiftUI is used for forms and lists, AppKit for the sidebar, tab rows, drag and
  the toolbar. Chrome is reached through the existing C interface. Rust is out for now.
- Order: measure; the core becomes the source of truth behind a bridge; then Settings, New Tab, toolbar and omnibox,
  and the sidebar, one surface at a time; then RN, Expo, Hermes, Metro and the JS build are removed.

---

## 1. The architecture today

### 1.1 Processes and threads

| Where | What runs there |
|---|---|
| **Browser process, main thread** | `main.swift` → `LegacyMigration` → `ArdiaCoreHost.run` → `ChromeMain`. The main thread is AppKit's event loop, which is also **Chrome's UI thread**: `NSApp` is Chrome's `BrowserCrApplication`, and the RN host (`AppDelegate`, an `ExpoAppDelegate`) starts inside Chrome's run loop. RN mounts views here, along with every `ArdiaCoreWebView` and `ArdiaCoreWindow`, Chrome's bubbles and menus, every Expo function marked `runOnQueue(.main)`, every engine callback, and `WindowManager` (`packages/shell/ios/Windows.swift`). |
| Browser process, JS thread | Hermes: the zustand store (`useBrowser`), React reconciliation, every store listener, the omnibox's suggestion work (`@ardia/core`), persistence serialization (`JSON.stringify` of the whole session), the sync merge, and Live Folders. |
| Browser process, RN shadow queue | Yoga layout (legacy architecture). |
| Browser process, `ardia.documents` queue | `DocumentStore` file writes (`ShellModule.swift:115`). |
| Browser process, Chrome's IO thread and thread pool | Chrome's own work: history, passwords, network. |
| Renderer, GPU and utility processes | Chrome's. |

A click on a sidebar row today makes this round trip:

```
main (AppKit event)
  → JS (touch handler → store action → listeners → React commit)
  → shadow queue (Yoga)
  → main (UIManager mount → AppKit layout → Core Animation commit)
```

Each hop waits on the other thread's queue. A busy Chrome task on main delays the mount, and a busy JS thread
delays the response. Engine events take the reverse path: main (delegate) → `emit` → JS (`lib/nativeEvents.ts` holds
page reports for one batch) → store → React → mount.

### 1.2 Who owns which state

| State | Owner today | Persisted where |
|---|---|---|
| Workspace: profiles, windows, tabs, groups, splits, pins, tile folders, parked pins, closed and cleaned items, `pinChoices`, `pinSync` | JS store (`store/*.ts`, 114 actions) | `session.json` (v2) |
| Settings (about 60 typed keys, plus `chosen`, `inferred` and `migrations`) | JS store (`store/settings.ts`) | `session.json` → `settings` |
| Downloads list | JS store (`store/ui.ts`) | `downloads.json` |
| Live tab facts (which tabs each Chrome strip holds, their order, the active tab, Chrome's groups) | Chrome's `TabStripModel`, mirrored into JS (`lib/chromeTabs.ts`, `store/liveTabs.ts`) | Chrome's session |
| Live page state (loading, progress, back/forward, audio, theme color) | JS store `live` | not saved |
| History, bookmarks, favicons, passwords, autofill, extensions, site settings, zoom, cookies | **Chrome** (`Chromium/` in the data folder), reached through `ac_*` calls and `ArdiaCoreServices` | Chrome's profile. JS keeps views of them (`history[profileId]`, `bookmarks`), plus `bookmarks-cache.json` for display only. |
| Sync | JS (`sync/engine.ts`, `adapters.ts`, `packages/sync/src` merge). Crypto, vault and keychain are Swift (`ArdiaSyncCore`). | `sync.json`, `sync-state.nns`, `sync-journal.nns`, the Keychain service `Ardia Sync Key` |
| Live Folders and Calendar | JS (`live/`) | `live.json` |
| Small documents | JS | `onboarding.json`, `release-notes.json`, `ardia-cli.json`, `launch-look.json`, `default-browser-offer.json`, `bangs-state.json`, `sync-extensions.json`, telemetry and kill-switch caches |
| Launch picture | Native (`ArdiaCoreEarlyWindow.mm`) | `launch-layout.json`, `launch-picture-*.png` |

The owner's live data folder (`~/Library/Application Support/com.hill.solara`) holds only `session.json` (21 KB),
`launch-layout.json`, `onboarding.json`, `release-notes.json`, `bookmarks-cache.json`, `ardia-cli.json` and
`Chromium/`. Sync and Live Folders are off. The plan doesn't rely on that.

### 1.3 How state reaches native views and the engine

- **Windows.** JS calls `openWindow(id, …)`. `WindowManager.open` makes an `ArdiaCoreWindow` (`ChromeWindows.makeWindow`)
  and embeds an RN root view for that id (`WindowHost.makeContentView` → `superView(withModuleName: "main",
  initialProperties: ["windowId": id])`). Every window, Settings and Import included, is an RN root on **one** JS
  runtime.
- **Tabs.** Each tab's page is an `ArdiaCoreWebView`. That is a plain `NSView` with a delegate
  (`ArdiaCoreWebView.h`), created by RN's `WebView` component (`packages/ardiacore/src/WebView.tsx`) and driven by
  props (`profile`, `initialURL`, `adoptId`, `transferKey`, `visible`, `frozen`, …). This matters for the move: native
  code can host it with no RN involved.
- **Chrome's tab strips.** The contract is in `docs/store-api.md` › "Live tabs". JS sends `activate`, `arrange` and
  `group` commands (`sendTabStripCommand`). Chrome answers with ordered transactions `{rev, cmd, strips}`, and
  `chromeChanged` folds Chrome's own changes (extensions, Chrome's successor pick) into the workspace. There is one
  writer per fact.
- **Services.** JS → Expo module (`CefModule.swift` and friends) → `ArdiaCoreServices` (Obj-C, typed) or
  `ArdiaCoreEngineBridge` (`ac_*` C calls in `engine/chromium`, JSON in and JSON out, found through dlsym). Events
  come back through `ArdiaCoreEngineBridge.observe` and the event switch in `CefModule.swift`.
- **Menus and app state.** `lib/native.ts` (`startNativeSync`) pushes the menu state, appearance and scroll-bar style
  to `Menus.swift` and the other shell modules on a 120 ms debounce.

### 1.4 Persistence and migrations today

- `lib/persist.ts`: `startPersistence` hydrates the store from `loadSession()`. It then watches each document's
  source slices by reference and, 800 ms after a change, serializes the **whole** document on the JS thread. A
  document whose JSON is unchanged isn't written. `writeDocument` hands the string to `DocumentStore`, which writes
  atomically on its own queue, retries with backoff, and flushes on `willTerminate`.
- `session.json` has `version: 2` and the fields `SessionV2` lists (`persist.ts:105`). Private windows, Little Solara
  windows, Peek tabs and private closed items are left out. `navigation` and `adoptId` are dropped, and `pageIn`
  becomes `unloaded`.
- `hydrate` (`store/browser.ts`) repairs as it loads:
  - drops tabs whose window or profile is gone;
  - `pinnedFirst` reorders each window;
  - keeps `pinnedAsRow` and `tileFolder` only where they're valid;
  - fills `pinnedUrl`;
  - repairs `activeTabIds`;
  - drops empty groups;
  - `sanitizeSplits`;
  - filters the per-profile tables;
  - replays activation in focus order.
- `restoreSession === false` (`loadSession`) parks every window's pins and turns its windows into closed windows.
- **Settings migrations** are named and idempotent. `migrateSavedSettings` runs `withoutBatterySaver`,
  `keepToolbarOnScroll` (recorded in `settings.migrations`) and `withNewTabButtonPosition`. `chosen` and `inferred`
  record which keys the user set.
- **Native readers of `session.json`:** `ArdiaCoreHost.mm:158` reads it before JS runs, for the early window
  (`ArdiaCoreEarlyWindow prefetchForSession`: `launchTab`, `launchBackdrop`, `linkProfile`). `LegacyMigration.swift`
  (run in `main.swift` before Chrome) rewrites its keys and URLs for the Netnyahoo → Ardia rename and checks that it
  exists.

### 1.5 Sizes

Lines of code, from `wc -l` on 2026-10-26.

| Area | Source | Tests |
|---|---|---|
| `apps/browser/src/store` | 7,564 | 7,511 |
| `apps/browser/src/lib` | 7,678 | 3,673 |
| `apps/browser/src/sync` | 2,941 | 4,749 |
| `apps/browser/src/live` | 1,994 | 244 |
| `apps/browser/src/telemetry` | 1,714 | 391 |
| `apps/browser/src/components` | 42,384 | 2,017 |
| ↳ sidebar / layout / settings / onboarding / site / extensions / media / import / omnibox / pages | 6,906 / 5,695 / 6,337 / 5,074 / 2,744 / 1,594 / 1,610 / 1,548 / 1,356 / 1,312 | |
| `packages/core` (omnibox): logic, plus `bangList.ts` data | about 3,000 + 10,706 | 1,079 |
| `packages/sync/src` (merge, TS) | 1,821 | |
| Native Swift / Obj-C++: `packages/shell/ios`, `packages/ardiacore/ios`, `packages/sync/ios`, `packages/import/ios` | 9,894 / 18,804 / about 2,300 / about 5,100 | Swift tests in sync and import |
| Engine: `engine/chromium` (`ac_*`), `engine/ardiacore` (`//ardia/core`) | 10,889 / 17,042 | |

About 70k lines of TypeScript go away by the end. About 37k lines of native app code and 28k lines of engine code stay.

### 1.6 Costs the owner has seen

**The main thread is shared with Chrome, and RN adds hops to it.**
- 746664cf measured 1.3–1.7 ms of main thread per window move just to report the frame to JS and UserDefaults.
- be42c43a: the hand-driven drag loop "stutters on a fast drag because that thread is Chrome's and React Native's
  too".
- Going native does **not** give the main thread back: it stays Chrome's UI thread. What native removes is the JS
  hop, the shadow-queue hop, serialization across the bridge, React's reconcile work, and RN's mount queue.
  react-native-macos also carries 10 patches of our own.

**The JS-driven window drag.**
- Drag start is 50–83 ms late, after 7–10 pt of travel (3d689889). This is **not** RN's doing: Chromium's
  `BridgedContentView` claims its whole bounds as opaque for window moves (crbug 830962), so every drag waits for
  `mouseDown` on main.
- On macOS 27.2, `performWindowDragWithEvent:` is broken. Solara's fallback moves the window from the main thread one
  event at a time (17ca55fe). It trailed by up to 57 pt until 746664cf, and it now installs only from 27.2 on
  (be42c43a).
- Native views make the fix simpler (the `ServerWindowDrag` approach behind `ARDIA_SERVER_WINDOW_DRAG`, with
  geometry we own instead of walking RN's z-order), but going native doesn't make that work unnecessary.

**Launch.**
- On the 200-tab seed, the window shows its content at 1,070 ms against 490 ms for one tab, and "nearly all of the
  difference is in JS" (`docs/perf/sprint-baseline.md`).
- On a warm one-tab launch, 79% of the time is native start → JS running (387 ms).

**Per interaction.**
- Tab switch (J3) takes 27 ms, 10 ms of it JS. An omnibox keystroke (J2) costs 6.2 ms.
- The ratchet's `switchTabs` scenario wakes 950 store-listener calls over 12 switches. These are counts of the
  RN-era overhead, not of the browser's work.

**Development cost.** Every instance runs everyone's JS through Metro, so there is a "Native API skew" check. An
import-cycle LogBox crashes RN. Shadows crash, and `RCTView` resets layer properties. Expo prebuild and pods sit
between Swift and the app.

---

## 2. The target architecture

### 2.1 Module layout

There is one Swift package, `native/SolaraKit/Package.swift`, plus the app target. The core targets import neither
AppKit nor ArdiaCore, so a future WebKit-based iPhone or iPad app can reuse them.

```
SolaraModel        value types, ids, invariants                      (Foundation)
  └─ SolaraStore       commands, reducers, settle passes, commits, rev log
       ├─ SolaraPersistence  GRDB schema, migrator, writer, session.json v2 import/export   (+ GRDB)
       ├─ SolaraOmnibox      packages/core port: parse, fix-up, suggest, bangs, calculator, IDN
       ├─ SolaraSync         ArdiaSyncCore (moved as-is) + the merge (port of packages/sync/src) + adapters
       └─ SolaraImport       packages/import/ios/Core (already plain Swift with a Package.swift), moved
SolaraEngine (macOS)  typed Swift over ArdiaCoreEngineBridge, ArdiaCoreServices, ArdiaCoreTabStrip,
                      ArdiaCoreWebView, ArdiaCoreHost; EngineClient, TabViewPool, LiveTabs
SolaraUI (macOS)      AppKit + SwiftUI surfaces: SettingsUI, OnboardingUI, NewTabUI, ToolbarUI, SidebarUI, WindowShell
SolaraRNBridge        Expo module exposing the store to JS (deleted in phase 6)
App target            main.swift, AppDelegate (Chrome-hosted), menus (Menus.swift moves here)
```

| Target | Depends on | Platforms |
|---|---|---|
| SolaraModel | — | macOS 14+, iOS 17+ |
| SolaraStore | Model | macOS, iOS |
| SolaraPersistence | Model, Store, GRDB (exact version pinned) | macOS, iOS |
| SolaraOmnibox | Model | macOS, iOS |
| SolaraSync | Model, Store, Persistence | macOS, iOS |
| SolaraImport | Model | macOS (it reads other Mac browsers) |
| SolaraEngine | Store, Omnibox; ArdiaCore headers (pod until phase 6) | macOS |
| SolaraUI | Engine, Store, Omnibox, Sync, Import; `ArdiaShaders` (Metal views, unchanged) | macOS |

Reasons:
- `SolaraEngine` is the only place that knows Chrome. On iOS a WebKit engine target can implement the same command
  and event types. The app already runs a second page engine per tab (`tab.engine`, `WebKitTab.swift`), so the
  boundary has a real second user.
- The Expo wrappers (`CefModule.swift`, `ShellModule.swift`, `SyncModule.swift`) are thin. Their logic moves into
  plain Swift types the UI calls directly, and the modules shrink to adapters until phase 6 deletes them.

**Where Rust could come in later, in isolation.** None of these is needed for macOS or iOS, since Swift covers both.

| Candidate | Why it would fit | When |
|---|---|---|
| Omnibox scoring, fuzzy matching, bang table | Pure functions with a frozen reference spec and property tests (`suggest.reference.ts`) | Only for a non-Apple platform |
| Sync merge and file format | Pure, security-sensitive, wire format fixed by `docs/sync.md` | Only if a non-Apple client must sync |
| Importer parsers for other browsers' databases | Untrusted input, fuzzing-friendly | If fuzzing finds Swift parser crashes we can't contain |

### 2.2 The core's data model

The model keeps the JS store's shapes and **string ids verbatim**. Sync record keys are built from them (`pin:t:<id>`,
`bm:<id>`), `newId` has a random part so ids are unique across Macs, and the golden replay (§5.2) diffs states
directly.

```swift
public struct BrowserState: Sendable, Equatable {
  public var profiles: [Profile.ID: Profile]
  public var profileOrder: [Profile.ID]
  public var windows: [Window.ID: BrowserWindow]
  public var windowOrder: [Window.ID]
  public var tabs: [Tab.ID: Tab]
  public var groups: [TabGroup.ID: TabGroup]
  public var splits: [SplitView.ID: SplitView]
  public var parkedPins: [Profile.ID: ParkedPins]
  public var pinChoices: [Profile.ID: PinTable]
  public var pinSync: [Profile.ID: PinTable]
  public var closedTabs: [ClosedTab]
  public var closedWindows: [ClosedWindow]
  public var closedGroups: [ClosedGroup]
  public var deletedGroups: [ClosedGroup]
  public var cleanedTabs: [CleanedTab]
  public var orphanedProfileData: [String]
  public var downloads: [Download]
  public var settings: Settings
  public var focus: FocusState
  public var session: SessionState
}
```

| Entity | Fields (as in `store/types.ts`) | Notes |
|---|---|---|
| `Profile` (Dia's profiles; Arc spaces import as profiles) | `id, name, color, icon, createdAt, dataId?, theme?` | `dataId` shares one engine profile's data. `engineProfile(id)` resolves it. |
| `BrowserWindow` | `id, profileId, incognito, tabIds, activeTabIds[profile], sidebarOpen, tabLayout?, frame, fullScreen?, createdAt, kind? ("small"), linkPointer?, originalProfileId?` | `tabIds` is the sidebar order. A private window's profile id is `incognito:<window>@<profile>`. |
| `Tab` | `id, windowId, profileId, url, title, favicon, pinned, pinnedAsRow?, tileFolder?, pinnedUrl, pinKey?, muted, zoom, customTitle, customIcon, openerId, wakeAdoptId?, liveItem?, unloaded?, engine?, createdAt, lastActiveAt` | `navigation`, `adoptId` and `pageIn` are session-only (`SessionState`). |
| `TabGroup` | `id, windowId, profileId, name, icon, color, collapsed, pinned, tabIds, createdAt, autoUngroup?, pinnedOpenerId?, pinKey?, parentId?` | Groups nest through `parentId`. |
| `SplitView` | `id, windowId, tabIds (2–3), orientation, sizes, stack?` | One sidebar row. |
| Pinned rows, tiles and folders | Not separate entities: a tile is a pinned tab, a pinned row is `pinnedAsRow`, a folder is `tileFolder` | As today. A Live Folder's place in the pinned order lives in Live state (`after` anchor). |
| `Settings` | Typed struct with every key in `store/settings.ts`, plus `chosen`, `inferred` and `migrations` | Keys a newer build wrote survive (§2.5). |
| History pointers | None in the core | History is Chrome's. The omnibox keeps its own index (§2.6). `closedTabs` and friends carry `tabId`/`restoreFrom`, so Chrome can restore the back/forward list. |
| Live tab state | Not in the core | `LiveTabs` (main actor, per tab) is fed by the engine directly: loading, progress, back/forward, audio, theme color, find, permissions. |

**Invariants.** `SolaraModel.check(state)` asserts all of these. It runs after every commit in Debug builds and in
tests, and on import.
1. A window's `tabIds` lists exactly the tabs whose `windowId` is that window, in sidebar order, pinned first: tiles,
   then pinned rows and pinned groups interleaved, then the rest (`pinnedFirst`).
2. A group's members are contiguous in its window's order and share its pinned state. Nested groups sit inside their
   parent. No group is empty.
3. A split has 2–3 panes, contiguous, all pinned or all unpinned, and moves as one row.
4. `activeTabIds[p]` is a tab of that window with profile `p`, and the shown profile always has one.
5. Pins are per profile. Each regular window showing a profile holds a copy of every pinned tile and pinned group,
   linked by `pinKey`. A profile's `parkedPins` is non-empty only while no window shows it.
6. `tileFolder` appears only on pinned tiles, members sit next to each other, and a one-member folder dissolves.
7. `pinnedUrl` is set exactly when a tab is in a pinned place (`settlePinHomes`).
8. Private windows, Little Solara windows and Peek tabs are never persisted. Private closed items never leave memory.
9. Ids are unique across all entity kinds and never reused.

### 2.3 Commands, transactions and the settle pipeline

- **Commands map 1:1 to today's store actions** (`newTab`, `closeTabs`, `activate`, `placeTabs`, `dropTabs`,
  `pinTabs`, `createGroup`, `createSplit`, `switchProfile`, `updateSettings`, …; 114 in all), with the same
  arguments. JS call sites therefore don't change in phase 1, and the golden replay can drive both implementations
  from one script. A caller that needs a new id passes it in, or gets it back in the commit.
- **A reducer is a pure function:** `(inout BrowserState, Command) throws -> [Effect]`.
- **Settling happens inside the transaction.** Today, invariants are restored after the fact by `subscribe` listeners
  that call `setState` again. That makes them hidden writers. The core runs them inside the transaction, in the order
  `browser.ts` registers them, before anything is published:
  1. `forgetClosedPrivateWindows`
  2. `settleNesting`
  3. `livePinTable` (`pinChoices`, `pinSync`)
  4. `settlePeeks`
  5. the mirror chain: `settlePinHomes` → `unshareTabs` / `pagesIntoSplits` → `settleSharedPins` →
     `settleTileFolders` → `mirrorPins` → `mirrorTabs`, repeated to a fixpoint with the same cap of 4 passes
     (`mirroring > 3`).

  A command is one transaction. `dispatch([Command])` batches several into one, as `storeTransaction` does for the
  engine's held page reports (`lib/nativeEvents.ts`).
- **A commit** is `{rev, changes: ChangeSet, effects}`. `rev` increases by one per commit for the process's lifetime.
  `ChangeSet` lists, per entity table, the ids upserted and removed, plus the settings keys and singletons changed.
- **Effects** are what the store asks the outside world to do, executed after the lock is released:
  - `stripCommand`, `loadURL`, `discard`, `releaseProfile`;
  - `openWindow`, `closeWindow`;
  - `deleteProfileData`;
  - `bookmarkOps`;
  - `notify`.

  Reducers never call the engine.

### 2.4 Threading

| Actor or queue | Runs |
|---|---|
| `@MainActor` | All AppKit and SwiftUI. Every engine call and callback, since Chrome requires its UI thread. `EngineClient`, `TabViewPool`, `LiveTabs`, and the observable projections (§2.5). Effect execution. |
| `Store` (nonisolated, `final class Store: Sendable`, state behind `OSAllocatedUnfairLock`) | `dispatch` from any thread. In phase 1 that includes the JS thread, synchronously (§4). Reducers plus settling typically take tens of µs; the budget is 1 ms on the 200-tab seed. |
| Persistence writer (a GRDB `DatabasePool` writer, background QoS) | Coalesced row writes and the `session.json` shadow export. |
| `SuggestionEngine` actor | Omnibox: index maintenance, parsing, ranking. |
| Sync actor | The cycle, merge, file IO (already off main in `SyncVault`), compaction. |
| Importers (`Task.detached`) | Reading other browsers' data. |

Why a lock rather than `@MainActor` for the store:
- During the bridge phase, JS must read its own writes synchronously. `const id = newTab(…)` followed by reads of the
  new state is common across 33 `useBrowser.setState` sites and the 114 actions.
- A synchronous hop from the JS thread to main (`DispatchQueue.main.sync`) would stall on Chrome's tasks and risks
  deadlock.
- An uncontended unfair lock costs about 20 ns. After phase 6 every caller is on main and the lock is never contended,
  so it stays.

A commit that originates on main (an engine event, a native control) updates the projections **synchronously in the
same run-loop turn**. A click goes: AppKit event → `dispatch` → projections → view update → Core Animation commit,
with no thread hop. Commits from other threads (JS in phase 1, sync) reach main with one `DispatchQueue.main.async`.

Main-thread rule: no JSON, no SQLite, no suggestion ranking, and no full-state diffing on main. A row's model
updates in O(1). A window's derived row list (the port of `sidebarEntries`) is recomputed only for dirty windows,
O(n) in that window's tabs, which `micro-bench` already holds to well under 1 ms at 1,000 tabs.

### 2.5 How SwiftUI and AppKit observe the core

Projections are `@Observable @MainActor` classes the UI binds to. They are kept in step from each commit's
`ChangeSet`, so only the objects whose entities changed are touched:
- `AppModel`: profiles, window order, focus, `SettingsModel`.
- `WindowModel`: profile, layout, sidebar open, active tab, `rows: [RowID]` (pinned tiles, pinned rows and groups,
  Live Folders, the rest, splits as one row).
- `TabModel` per tab: persisted fields. `LiveTabModel` is separate and fed by the engine, so a progress tick never
  touches the store.
- `GroupModel`, `SplitModel`.

How each kind of UI reads them:
- **SwiftUI** (Settings, onboarding, New Tab) reads the projections directly. A setting is a `Binding` built by
  `SettingsModel.binding(\.warnBeforeQuitting)`, which dispatches `updateSettings`, so `chosen` is maintained the same
  way it is today.
- **AppKit** (sidebar, toolbar, tab rows) uses a small `observe { }` helper over `withObservationTracking` that
  re-arms after each change and coalesces to one `needsLayout` / `needsDisplay` per run-loop turn. A row observes its
  own `TabModel`, so a title change re-lays out one row. This is the native counterpart of today's narrow zustand
  selectors. (On macOS 26 AppKit tracks Observation in layout itself; §7 asks about the deployment target.)

### 2.6 Engine events in, commands out

```
Chrome (UI thread = main)
  ArdiaCoreWebView delegate ─┐            ┌─▶ LiveTabs (not stored)
  ArdiaCoreTabStrip txns ────┼─▶ EngineClient ─┤
  EngineBridge topics ───────┤            └─▶ Store.dispatch(.engine(…)) ─▶ Commit ─▶ projections
  ArdiaCoreServices handlers ┘                                               └▶ effects ─▶ EngineClient ─▶ Chrome
```

- **`EngineClient`** (main actor) gives the C and Obj-C surface typed async Swift. `ac_*` calls become `Codable`
  request/response pairs over `ArdiaCoreEngineBridge.call`, guarded by `exports:`. `ArdiaCoreServices` callbacks
  become `async` functions. Topic events (`history.changed`, `tabs.strip`, bookmarks, extensions, downloads) become
  `AsyncStream`s.
- **`TabViewPool`** owns one `ArdiaCoreWebView` per loaded tab, keyed by tab id (`transferKey`). It is the delegate
  in place of the RN view module, and it sets `visible`, `warm`, `frozen` and the rest from the window's projection.
- **The tab-strip contract stays exactly as `docs/store-api.md` defines it.** `chromeChanged` (a port of
  `store/liveTabs.ts`) is a reducer. `stripPlan` and the "one command per strip at a time, never resend unchanged"
  rule (a port of `lib/chromeTabs.ts`) live in `EngineClient` and run after each commit. The fake-engine tests in
  `liveTabs.test.mjs` become golden-replay cases (§5.2).
- **Omnibox.**
  - `SuggestionEngine` (actor) keeps an in-memory index built from `ac_history_query` plus `history.changed`,
    `ac_bookmarks_tree`, open tabs (from commits), search engines (settings plus `ac_search_engines`), and the bang
    table, generated at build time from `bangList.ts` into a resource.
  - Each keystroke carries a generation number. Main applies only the newest result.
  - Remote suggestions use the same endpoints as `suggestFetcher.ts`.
  - The core drops `history[profileId]`, the whole-history mirror the JS store keeps in memory today.

### 2.7 Persistence: GRDB

The database is one file, `solara.sqlite`, in the data folder (`ARDIA_DATA_DIR` is honored), opened as a GRDB
`DatabasePool` in WAL mode with `synchronous = NORMAL` and `foreign_keys = ON`.

```sql
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE profile (id TEXT PRIMARY KEY, position INTEGER NOT NULL, name TEXT NOT NULL, color TEXT NOT NULL,
  icon TEXT, created_at INTEGER NOT NULL, data_id TEXT, theme TEXT);
CREATE TABLE setting (key TEXT PRIMARY KEY, value TEXT NOT NULL, chosen INTEGER NOT NULL DEFAULT 0,
  inferred INTEGER NOT NULL DEFAULT 0);
CREATE TABLE window (id TEXT PRIMARY KEY, position INTEGER NOT NULL, profile_id TEXT NOT NULL,
  sidebar_open INTEGER NOT NULL, tab_layout TEXT, frame TEXT, full_screen INTEGER, created_at INTEGER NOT NULL,
  link_pointer TEXT, original_profile_id TEXT);
CREATE TABLE window_active_tab (window_id TEXT NOT NULL REFERENCES window ON DELETE CASCADE,
  profile_id TEXT NOT NULL, tab_id TEXT NOT NULL, PRIMARY KEY (window_id, profile_id));
CREATE TABLE tab (id TEXT PRIMARY KEY, window_id TEXT NOT NULL REFERENCES window ON DELETE CASCADE,
  position INTEGER NOT NULL, profile_id TEXT NOT NULL, url TEXT NOT NULL, title TEXT NOT NULL, favicon TEXT,
  pinned INTEGER NOT NULL, pinned_as_row INTEGER NOT NULL DEFAULT 0, pinned_url TEXT, pin_key TEXT,
  tile_folder TEXT, muted INTEGER NOT NULL, zoom REAL NOT NULL, custom_title TEXT, custom_icon TEXT,
  opener_id TEXT, wake_adopt_id TEXT, live_item TEXT, unloaded INTEGER NOT NULL DEFAULT 0, engine TEXT,
  created_at INTEGER NOT NULL, last_active_at INTEGER NOT NULL);
CREATE INDEX tab_by_window ON tab (window_id, position);
CREATE TABLE tab_group (id TEXT PRIMARY KEY, window_id TEXT NOT NULL REFERENCES window ON DELETE CASCADE,
  profile_id TEXT NOT NULL, name TEXT NOT NULL, icon TEXT, color TEXT, collapsed INTEGER NOT NULL,
  pinned INTEGER NOT NULL, created_at INTEGER NOT NULL, auto_ungroup INTEGER, pinned_opener_id TEXT,
  pin_key TEXT, parent_id TEXT);
CREATE TABLE group_member (group_id TEXT NOT NULL REFERENCES tab_group ON DELETE CASCADE,
  position INTEGER NOT NULL, tab_id TEXT NOT NULL, PRIMARY KEY (group_id, position));
CREATE TABLE split (id TEXT PRIMARY KEY, window_id TEXT NOT NULL REFERENCES window ON DELETE CASCADE,
  orientation TEXT NOT NULL, sizes TEXT NOT NULL, stack TEXT);
CREATE TABLE split_pane (split_id TEXT NOT NULL REFERENCES split ON DELETE CASCADE, position INTEGER NOT NULL,
  tab_id TEXT NOT NULL, PRIMARY KEY (split_id, position));
CREATE TABLE profile_pins (profile_id TEXT PRIMARY KEY, parked TEXT, choices TEXT, sync TEXT);
CREATE TABLE archive (id TEXT PRIMARY KEY, kind TEXT NOT NULL, closed_at INTEGER NOT NULL, payload TEXT NOT NULL);
CREATE TABLE download (id TEXT PRIMARY KEY, position INTEGER NOT NULL, payload TEXT NOT NULL);
CREATE TABLE document (name TEXT PRIMARY KEY, value TEXT NOT NULL);
```

**Hot entities get columns; cold ones get JSON.**
- Windows, tabs, groups and splits change on every interaction and get real columns.
- Closed, cleaned and deleted items (`archive.kind`), parked pins and pin tables are written rarely and read as
  wholes, so they stay JSON in the exact shape `session.json` uses. That makes the export a copy, not a translation.
- `document` takes the small JSON documents (onboarding, Live state, CLI) as their owners port.

**Write strategy.**
- Each commit's `ChangeSet` is merged into a dirty set.
- The writer flushes it in **one transaction** 250 ms after the first change, or at once for commits marked durable:
  closing a window, deleting a profile, settings, quit. A flush upserts only the dirty rows.
- When a window's order changes, that window's `position` values are rewritten. That is at most a few hundred rows,
  about 1–2 ms off main.
- Today's equivalent re-serializes the whole session on the JS thread every 800 ms after any change.

**Crash safety.**
- WAL plus a single transaction per flush: a crash loses at most the last 250 ms, never half a flush. Today the loss
  window is 800 ms.
- `willTerminate` flushes synchronously with a 500 ms deadline (`DocumentStore`'s pattern).
- At launch, `PRAGMA quick_check` runs (sub-ms at this size). If it fails, the file moves to
  `solara.sqlite.corrupt-<date>` and the app re-imports from the shadow `session.json` (§3.4).

**Versioning.** A GRDB `DatabaseMigrator` applies named, forward-only migrations, and `meta.schema` records them. A
build that finds migrations it doesn't know (a downgrade) doesn't open the database: it falls back to the shadow
`session.json`.

**Forward compatibility.** `setting` rows for keys this build doesn't know are kept and written back unchanged, as
today's `{...DEFAULT_SETTINGS, ...saved}` keeps them. Unknown JSON fields in `archive` payloads survive the same way.

---

## 3. Migrating the owner's data

### 3.1 What moves, what doesn't

| Data | Action |
|---|---|
| `session.json` v2 (profiles, settings, windows, tabs, groups, splits, closed / cleaned / deleted items, parked pins, `pinChoices`, `pinSync`, focus, last profile) | Imported into `solara.sqlite` once. |
| `downloads.json` | Imported (`download`). |
| `sync.json`, `sync-state.nns`, `sync-journal.nns`, Keychain `Ardia Sync Key` | **Untouched.** The sync engine keeps reading them in every phase. Only the record source changes (§4.5). |
| `live.json` | Imported into `document` when Live Folders port (phase 2). |
| `onboarding.json`, `ardia-cli.json`, `default-browser-offer.json`, `bangs-state.json`, `sync-extensions.json`, `release-notes.json` | Imported into `document` when their owner ports. |
| `launch-layout.json`, `launch-picture-*.png`, `bookmarks-cache.json`, `switches-cache.json`, telemetry files | Caches. Not migrated: rebuilt or deleted. |
| `Chromium/` (history, bookmarks, passwords, autofill, extensions, cookies, site settings) | **Chrome's. Never touched.** The engine reads it as it does today. |

### 3.2 The one-time import

- **Where.** `main.swift`, right after `LegacyMigration.runAtLaunch()` and before `ArdiaCoreHost.run`. That is before
  Chrome starts, before any window, and with nothing touching `NSApp`. Same slot, same style and same test approach
  (an executable tool plus XCTest fixtures, like `packages/sync/tools/legacy-migration`).
- **What.** `SessionV2Importer` is a straight port of `loadSession()` + `migrateSavedSettings` + `hydrate`'s
  repairs (§1.4), including the `restoreSession === false` branch. It produces a `BrowserState`, runs
  `SolaraModel.check`, and writes it to `solara.sqlite.importing`.
- **Atomic.** The import writes the temporary file, `fsync`s it, then renames it to `solara.sqlite`. A crash
  mid-import leaves no database, so the next launch imports again. The source files are never modified.
- **Recorded.** `meta` holds `imported_from = session.json`, its version, the SHA-256 and size of the source, the
  app version, the import time, and the counts per entity before and after repair.
- **Checked.** Counts are logged. Anything repair dropped is listed in `import.log` in the data folder, so a
  surprising loss is visible instead of silent.

### 3.3 Proving it loses nothing

The oracle is the JS loader itself. A Node script (`apps/browser/scripts/native/session-oracle.mjs`) runs
`loadSession()` + `hydrate()` on a `session.json` and prints the hydrated persisted slices as canonical JSON. The
Swift importer, run through its CLI on the same file, prints the same canonical form. They must be **byte-identical**.
- The fixtures are the existing test sessions, the `persist` and `settingsMigrations` cases, synthetic edge cases
  (`restoreSession: false`, orphaned tabs, a broken split, a deleted profile), and big seeds from
  `apps/browser/scripts/perf/seed.mjs`.
- The owner's real `session.json` is copied into a scratch dir (never committed) and run through both before the
  phase ships.
- In the app, the first launch after the import compares the importer's counts with what JS hydrates from the
  bridge snapshot, and logs any difference.

### 3.4 Versioning and rollback

- **Shadow export.** The persistence writer keeps writing a v2 `session.json` (debounced 2 s, off main), exactly
  what `persist.ts` writes today. It does this from the import until phase 6 ships plus two stable releases. That
  keeps three things working:
  1. `ArdiaCoreHost.mm`'s early-window read (`launchTab`, `launchBackdrop`, `linkProfile`), unchanged until the
     window shell goes native;
  2. **rollback**: installing an older build (or one from the other channel) finds a current `session.json` and runs
     on it as today;
  3. upstream's `LegacyMigration` expectations.
- **Downgrade, then upgrade.** `meta.last_export_sha` records the hash of the last shadow export. At launch, if
  `session.json`'s hash differs, an older build has written to it since. The database moves aside
  (`solara.sqlite.superseded-<date>`) and the importer runs again on `session.json`. Newer-only fields kept in
  `setting` / `document` are merged back by key.
- **Schema downgrade.** An older build with a newer `solara.sqlite` sees migrations it doesn't know, refuses the
  database, and imports the shadow `session.json`. Nothing is lost, because the shadow is always current.
- **Kill switch.** For the first nightly, `ARDIA_NATIVE_STORE=0` (environment, Debug and nightly only) makes the app
  run on the JS store and `session.json` as today. Remove it once the phase ships stable.

---

## 4. The transition bridge

### 4.1 One writer

From phase 1 on, **the Swift `Store` is the only writer** of the slices it owns. JS keeps a zustand **replica** of
them for the RN surfaces still in use.

| Phase | Swift owns | JS still owns (not persisted, or not yet ported) |
|---|---|---|
| 1a | settings, profiles, downloads, persistence, import | everything else |
| 1b | + the whole workspace (windows, tabs, groups, splits, pins, parked, closed/cleaned/deleted items, pin tables, focus) and the tab-strip reconciliation (`liveTabs` / `chromeTabs`) | `live`, `find`, `windowUi`, `selection` / anchors, Peek UI, the history and bookmark views, the sync engine (writing through commands) |

### 4.2 The bridge API

`SolaraRNBridge` is an Expo module.

| Call | Thread | Returns |
|---|---|---|
| `snapshot()`, sync | JS | `{rev, data: HydrateData}`, the shape `hydrate` already takes, which replaces `loadSession()`. |
| `dispatch(commandJSON, sinceRev)`, sync | JS, takes the store lock | `{rev, patches}`: **every** patch after `sinceRev`, its own included. |
| event `onStoreCommit {rev, patch}` | delivered on JS | Commits JS didn't originate (engine, sync, native UI). |

**Ordering and read-your-writes** work like the tab strip's `rev` contract. JS tracks the last `rev` it applied.
`dispatch` returns everything since then, so JS applies in order and sees its own write before `dispatch` returns. An
`onStoreCommit` at or below the applied `rev` is dropped. Swift keeps a ring of the last 1,024 patches; a gap larger
than that returns a full snapshot instead.

**Patches** are entity-level: `{tabs: {upsert: [...], remove: [...]}, windows: …, settings: {...}}`. The JS applier
replaces only the changed entities' objects, so object identity, narrow selectors and render counts behave as they
do today. Acceptance: the ratchet's exact counts (`switchTabs.subNotified`, the renders, `hover`) don't rise.

### 4.3 Removing the hidden writers

All of these become commands, or move into the Swift transaction, in the sub-phase that moves their slice:

| Writer | Becomes |
|---|---|
| `browser.ts` listeners: `forgetClosedPrivateWindows`, `settleNesting`, `livePinTable`, `settlePeeks`, the mirror chain | Settle passes in the Swift transaction (§2.3); deleted from JS |
| `useBrowser.setState` in `sync/adapters.ts`, `sync/pinned.ts` | A `sync.apply(records)` command; Swift keeps the invariants (group contiguity, pinned-first) |
| `lib/chromeTabs.ts` (`chromeChanged`) | Swift's reducer, fed natively; deleted from JS (1b) |
| `lib/history.ts`, `lib/bookmarks.ts`, `lib/bookmarkGroups.ts`, `lib/launchLook.ts` | Their own JS-owned slices stay JS until their surface ports; the bookmark-to-group action becomes a command |
| `components/import/apply.ts`, `onboarding/state.ts`, `littleArdia/actions.ts`, `sidebar/tidyPinsUi.ts`, `sidebar/tileFolderUi.ts`, `store/pinOrderChoices.ts` | Commands |

That covers 33 `setState` sites in 15 files. A Debug-build guard wraps `setState`: writing a Swift-owned key outside
the patch applier throws, with the call site, so a missed writer fails the first test that hits it.

### 4.4 Native ↔ RN hosting

- **RN inside a native window** (Settings during phase 2):
  - The Settings window becomes an AppKit `NSWindow` with an `NSSplitViewController`. The sidebar, search field,
    back/forward and title are native (SwiftUI).
  - A ported pane is an `NSHostingController`.
  - An unported pane is an RN root, `makeContentView("settings-pane")` with `initialProperties {pane, profileId,
    detail}`. A new `SettingsPaneRoot` renders that one pane, on the same JS runtime with no new bridge.
  - Navigation (`useSettingsNav`) becomes native and feeds the pane through props.
  - The search index (`settingsIndex.ts`, 110 rows) moves to Swift as static data, as does the reveal-and-flash. For
    an RN pane, native asks the pane, through a small JS function, for the anchor's y-offset.
  - Sheets (`useSettingsSheet`) render at the RN root today and would be clipped to the pane, so they become native
    `NSWindow` sheets as each one's data ports. Until then the RN pane presents them in an RN root hosted by a
    sheet window.
- **Native inside an RN window** (New Tab in phase 3, toolbar in phase 4):
  - An Expo native view `SolaraHostedView(kind, windowId, tabId)` holds an `NSHostingView` or an AppKit view.
  - RN lays out the hole. The native view reads its projections directly, not through props, so a keystroke or
    progress tick crosses no bridge.
  - Focus between RN and native views goes through AppKit's responder chain. Each hosted kind has a focus test in
    `shortcuts-test.mjs`.
- **Phase 5 flips the window.** The window shell becomes native (sidebar, content card, splits, `TabViewPool`), and
  the RN root of a browser window is removed.

### 4.5 Sync during the move

Sync must stay wire-compatible: a Mac on a native build syncs with one still on JS.
- In phases 1–4 the **merge stays in TypeScript** (`packages/sync/src` + `apps/browser/src/sync`), on the replica.
  Its adapters write through `sync.apply` commands.
- In phase 5 the merge and adapters port to `SolaraSync`. Wire compatibility is held by:
  - `packages/sync/src/fixtures` (`scope-v0.2.38.ts`), `sync/fixtures/pinned-v0.2.3x.ts` and the two-device tests in
    `adapters.test.mjs`, run as golden replays;
  - a cross-implementation test: a TS device and a Swift device sharing one folder.

---

## 5. The plan

Sizes are rough Swift lines, tests included. Every phase ships as nightlies first, then a stable release through the
full gate (`docs/perf/README.md`). Its perf is compared with the previous **stable** release, and the baseline's
metrics (§6) are re-run.

### 5.1 Phases

| Phase | Scope | Ships at the end | Measures | Size |
|---|---|---|---|---|
| **0. Baseline** | [baseline.md](baseline.md): the new probes (stall histogram, drag pacing, per-window memory, signposts) and one full run on the last RN stable | `docs/native/baseline-<version>.md` | Everything in §6 | about 800 (probes, orchestrator) |
| **1a. Core: settings, profiles, persistence** | SwiftPM package; Model / Store / Persistence; importer + oracle; shadow export; RN bridge; JS settings and profile actions → `dispatch` | Same UI, `solara.sqlite` source of truth for settings, profiles and downloads | Launch (J1) not worse; save cost moves off the JS thread | 5–6k |
| **1b. Core: workspace** | All 114 actions; settle pipeline; `chromeChanged` / `stripPlan` in Swift; the hidden writers removed; golden replay of the store tests | Same UI on the Swift store | J1, J3, the ratchet's exact counts (must not rise); store dispatch p99 < 1 ms on the seed | 10–12k |
| **2. Settings, onboarding, utility windows** | Native Settings window (15 panes + sub-surfaces, below); Live engine port (`live/` → Swift, for Live Folders and Calendar); onboarding (5k TS); Import window | Native Settings; RN panes hosted until each ports; then no RN in utility windows | Settings open-to-content, pane switch, typing in search; memory with Settings open | 9–11k |
| **3. New Tab + internal pages** | New Tab (`NewTabPage.tsx`, `ntp/`, the sun hero, shader backdrop), `ardia://history`, `bookmarks`, `downloads` pages | Native New Tab hosted in the RN window | ⌘T → typeable, ⌘T → painted | 3–4k |
| **4. Toolbar + omnibox** | `SolaraOmnibox` (port of `packages/core`, property tests against the frozen reference); toolbar, URL field, command bar, Developer Mode, find bar, downloads popover, site prompts, extension toolbar and overlays | Native toolbar and omnibox in the RN window | Keystroke → suggestions, compute per key, ⌘L, J4 | 8–10k |
| **5. Sidebar + window shell + sync port** | Sidebar (rows, tiles, groups, splits, Live Folders, DnD, list motion, swipes), top tab strip, content card, splits, Peek, media/PiP controls, Little Solara, `TabViewPool`; drag via `ServerWindowDrag`; sync merge to Swift | Browser windows with no RN; the early window reads the store | Tab switch, hover frames, drag pacing, stalls, memory per window, launch | 15–18k |
| **6. Removal** | Delete RN, Expo, Hermes, Metro, pnpm app build, `SolaraRNBridge`, `NATIVE_API_VERSION`, the JS ratchet; ArdiaCore from pod to SwiftPM / Xcode target; plain Xcode project; stop the shadow `session.json` two stable releases later | An app with no JS runtime | Launch (no Hermes), memory, binary size | −70k TS |

Phase 2 depends only on 1a, so it can start while 1b is in progress.

### 5.2 Parity method: golden replay

`apps/browser/scripts/native/replay.mjs` runs action scripts through the real JS store in Node, the way the
`*.test.mjs` files already do, and records `(initial state, command list, resulting persisted state, effects)` as
JSON cases. `SolaraStoreTests` replays every case through the Swift core and diffs canonical JSON.
- Sources: all 7.5k lines of store tests, `liveTabs.test.mjs` with its fake engine (strip transactions as input,
  commands as effects), the sync adapter tests, and random sequences from a seeded generator over the 114 actions.
- "Behaves like today" becomes a diff that has to be empty. Once JS is gone, the cases stay as Swift's fixtures.

### 5.3 Acceptance checks per phase

All existing suites keep passing at every phase: the store, lib and sync tests (through replay once the JS is
gone), `acceptance.mjs`, `shortcuts-test.mjs`, `tab-drag-test.mjs`, `windowing-test.mjs`, `sidebar-click-test.mjs`,
`layout-shift-test.mjs`, `hover-shift-test.mjs`, `settings-shift-test.mjs`, `onboarding-test.mjs`. Solara's own
behaviors, checked where their phase lands:

| Behavior | Source | Checked in |
|---|---|---|
| ⌘D moves a tab to Pinned; bookmarking is ⌥⇧⌘D | 56e9f201 | 1b (command, menus), 5 (sidebar) |
| A tab close that takes the window asks first; the close-window dialog counts pinned tabs ("Close N tabs") | 750134ef, 69dba1e2, `closeIntent` | 1b (semantics), 5 (native alert) |
| Closing the last tab leaves a New Tab unless the policy closes the window (`closingTabs`, `leavesEmptyWindow`) | acc17272 | 1b, 3 |
| New Tab hero is the sun alone, on whole device pixels | 524f4047, 7104dc4d | 3 (pixel diff with the RN capture) |
| Developer Mode toolbar: 18 pt stripes falling right, 11 pt URL edited in place on the resting line, no not-secure lock on local hosts, window colors kept, reload chevron, DevTools buttons | be12e868, 1bd64609, 1ca81a98, 65266b4a, d34de431, 2d369f49, a8370ae3 | 4 |
| Tab titles run to the row's edge unless the row is hovered | 76669d61 | 5 |
| Tidy and Clear fade in on sidebar hover without shortening the divider; Clear only on hover; divider full width at rest | 25764cfd, 1a8400db, 538bfdd9 | 5 |
| A group's box shows only under the pointer | e8ae23fb | 5 |
| Switching tabs shows the new page at once, with no fade | 719f4787 | 5 |
| Main windows open and close with Little Solara's motion | 3b1de139 | 5 |
| Tooltips show the bound key | 2c05816b | 4, 5 |

Visual checks compare against an RN capture with the same crop and state (AGENTS.md › "Match Dia with numbers").
Timings in frames are measured from 30 fps recordings.

### 5.4 Settings inventory (phase 2)

`PANES` (`settingsIndex.ts:5`) has **15** panes, not 17. The other surfaces are Profile details
(`ProfileDetailsPane`), the Theme editor (`ThemeEditor.tsx`, 571 lines), Sync sheets (`SyncSheets.tsx`) and Share
diagnostics. In all, 6,337 lines across 29 files and 110 indexed rows.

| Pane | Lines | Kind | Native data source |
|---|---|---|---|
| General | 260 | Simple + system | `SettingsModel`; login item (`SMAppService`), default browser, `Updater.swift` (channel, auto-update), `ArdiaCoreEngineBridge` `ac_downloads_settings` / `ac_downloads_set_settings`, default profile |
| Tabs | 198 | Simple | `SettingsModel` (`tabLayout`, `newTabPosition`, `newTabButtonPosition`, `newTabOpens`, `cleanUpInactiveTabsAfterHours`, sidebar button, haptics, website color, ⌘-click groups, meeting groups) |
| Appearance | 278 | Simple + app icon | `SettingsModel` (`appearance`, `addressBar`, `commandBarPlacement`, `pageScrollBars`, `selectedTabGlow`, `spacesFollowAppearance`); app icon list from `AppIcon.swift` |
| Search Engine | 165 | Medium | `SettingsModel` + custom engine add/edit sheet (`addCustomEngine` validation from `SolaraOmnibox`); extension-controlled engine from `ac_search_engines` |
| Engines | 154 | Simple | `SettingsModel` (`pageEngine`, `websiteEngines`, `protectedVideoInWebKit`) |
| Advanced | 155 | Simple + info | `SettingsModel`; CLI install and control (`CliInstaller.swift`, `ac_cli_control`); `ArdiaCoreHost.engineInfo`; Widevine from `ArdiaCoreServices.components` |
| Keyboard Shortcuts | 197 | Medium | Menu item list from `Menus.swift` (direct), `settings.shortcuts` remaps, recorder control |
| Privacy & Security | 366 | Data-heavy | `ArdiaCoreContentBlocker` (state, lists, allow-list), `ArdiaCoreServices.siteSettings*`, `externalAppAllowances`, `zoomLevels` / `setZoom`, `clearBrowsingData`; Share diagnostics (Solara sends none: drop the row) |
| Passwords | 250 | Data-heavy, secrets | `ArdiaCoreServices.listPasswords` / `unlockPasswords` (reauth) / `password` / `save` / `update` / `delete` / `neverSaveOrigins` / `exportPasswords`; CSV import via `SolaraImport` (`PasswordsCSV.swift`); password-autofill toggle via `boolPreference` |
| Autofill | 308 | Data-heavy, secrets | `ArdiaCoreServices.addresses` / `saveAddress` / `cards` / `saveCard` / `deleteAutofillEntry` / `revealCardNumber`; enable toggles |
| Extensions | 213 | Data-heavy, live | `ArdiaCoreServices.listExtensions` / `setExtension` / `uninstall` / `reload` / `configure`, `extensionsHandler` events; Web Store link, load unpacked (`inspectUnpacked`) |
| Profiles + details + Theme editor | 318 + 571 | Data-heavy | `AppModel` profiles; create / share-with / reorder / delete commands; clear data (`clearBrowsingData`, `deleteProfileData`); theme editor on `ArdiaShaders` Metal views (already native) |
| Sync + sheets | 282 + 294 | Data-heavy, setup flows | `SyncModule` / `ArdiaSyncCore` (folder info, recovery phrase, recovery kit PDF/QR); sync state and devices from the TS engine until phase 5 (through the bridge), then `SolaraSync` |
| Live Folders | 348 | Data-heavy, OAuth | Live engine (ported in this phase): sources (GitHub, Bitbucket, Notion, Confluence, Google Drive), Google auth, connected accounts in the Keychain |
| Calendar | 114 | Data-heavy | `Calendar.swift` (EventKit) + Live state (`hiddenCalendarIds`, alert options), `autoGroupMeetingTabs` |

**Port order:**
1. The native shell, search and navigation, with every pane hosted from RN.
2. General, Tabs, Appearance, Search Engine, Engines, Advanced, Keyboard Shortcuts.
3. Privacy, Passwords, Autofill, Extensions.
4. Profiles and the Theme editor.
5. Sync.
6. The Live engine, then Live Folders and Calendar.
7. Onboarding.
8. The Import window.

---

## 6. Measurement baseline (summary)

Full definitions, tools and the script plan are in [baseline.md](baseline.md). **Nothing has been run yet.** The
baseline runs on the last RN stable after the overnight Chromium build ends, under the perflab lock, with the
display awake.

| Metric | Endpoint pair | Existing tool | New work |
|---|---|---|---|
| Tab switch click → response | The row's click event → CA commit showing it selected; → the new page's frame | `tab-actions.mjs` (sidebar click, ⌃Tab, ⌘1–9; it also splits out "main wait"), J3 | None |
| New tab | ⌘T key event → field typeable; → New Tab painted | `native-bench --only newtabkey` (J2), `tab-actions` ⌘T | None |
| Omnibox keystroke → suggestions | Key event → suggestion rows committed; compute alone per key | J2 `suggested` mark, `suggest-hermes.mjs` | A native signpost, so the metric survives the move |
| Sidebar hover | Pointer enters a row → hover in a CA commit; frames delivered over a 24-row sweep | Frame rig `hover`, census `hover` | None |
| Window drag frame pacing | Drag start latency (ms and pt), trail per frame (pt), frames delivered / expected, end error | None in the repo (746664cf used an uncommitted `drag.swift`) | `acperf postdrag`; needs a visible window (§7) |
| Main-thread stall histogram | Main and JS run-loop iterations bucketed 8 / 16 / 33 / 50 / 100 / 250 ms per scenario; samples of each ≥ 50 ms stall | `acframes.m` busy time (totals only), `acsample.c` (launch only) | Histogram output; `acsample` during scenarios, with attribution to Chrome / RN / app |
| Launch → first window | Process start → window shown → content → first frame → FCP; warm, cold (`--fresh-copy`), 1 tab and seed | `native-bench --only launch` | A "core ready" mark to replace "JS running" |
| Memory per window | Δ `phys_footprint` (browser) and Δ total (with helpers) per extra window, k = 1..4, settled | `native-bench` memory / newwindow | Slope variant |

The JS-side marks (`perfProbe`, `journeys.ts`) and the ratchet's React counts disappear with RN. The baseline
therefore defines every metric from native endpoints (AppKit event time, Core Animation commit, the page's frame).
`SolaraSignposts` (`os_signpost`) mark the same points in RN-era and native code, and a native ratchet (layout passes,
view updates and store commits per action) replaces the JS one in phase 6.

---

## 7. Risks and open questions

Each has a recommendation.

1. **The core port is large** (114 actions, a settle chain whose order matters, 7.5k lines of store logic).
   → Golden replay before any surface work (§5.2). Port by slice (1a, then 1b), and ship each slice as a nightly
   with `ARDIA_NATIVE_STORE=0` as the escape hatch.
2. **The main thread stays Chrome's.** Native won't remove stalls Chrome causes.
   → The baseline's stall attribution (§6) splits main-thread time between Chrome, RN and app before we promise a
   number. The target is per interaction: no app work over 1 ms on main.
3. **Two writers creep back during the bridge** (33 `setState` sites, sync adapters, listeners).
   → The Debug guard (§4.3) plus the ratchet's exact counts.
4. **Upstream store fixes stop merging** once 1b lands, since the Swift core replaces `store/*.ts`.
   → The upstream-merge agent lists upstream changes to `store/`, `lib/chromeTabs.ts` and `packages/core` as port
   candidates with replay cases. Engine and native-module merges continue.
5. **Sync wire compatibility.**
   → The merge stays TS until phase 5, then is held by cross-implementation fixtures (§4.5).
6. **Rollback depends on the shadow `session.json`.**
   → Keep it until phase 6 plus two stable releases. It costs one 21 KB write every 2 s at most, off main.
   *Open question: is that window long enough?*
7. **Mixed RN / native focus and key handling** (hosted views in phases 2–4).
   → A focus case per hosted kind in `shortcuts-test.mjs`. Native key equivalents go first through `Menus.swift`,
   as today.
8. **Drag pacing can't be measured hidden.** Real HID drags need a visible, unoccluded window, and posting in-process
   skips the window server path that matters.
   → *Open question:* may we schedule a 10-minute run with the owner away from the Mac but the screen unlocked, with
   the instance visible? Otherwise the drag row stays "needs owner run".
9. **Deployment target.** The app targets macOS 14. Observation works there, but AppKit's automatic observation
   tracking, `Mutex` and current SwiftUI APIs need macOS 15 or 26.
   → *Open question:* raise the minimum to macOS 26 for the native app? Recommendation: yes. Solara has no users to
   migrate yet, and it cuts the helper code in §2.5 and the Liquid Glass fallbacks.
10. **Where the package lives.**
    → Recommendation: `native/SolaraKit`, outside `packages/` (Expo's workspace), so phase 6 deletes `packages/*`
    except ArdiaCore without moving the core. *Open question if the owner prefers `packages/solara-core`.*
11. **Hermes-side services nobody sees.** `main.tsx` starts: translate, user scripts, CLI control, memory trim, tab
    lifecycle, app integration (AppleScript), kill switches, telemetry.
    → Each gets a row in phase 6's checklist. Kill switches and telemetry are off in Solara (empty URLs): delete
    them rather than port them.
12. **GRDB as a dependency.**
    → Pin the exact version and checksum in `Package.resolved`, and add it to the supply-chain review. Owner's choice
    already; noted only for the pin.
13. **Size of onboarding** (5k lines, demos).
    → Port it last in phase 2. It reuses the Metal views as they are.

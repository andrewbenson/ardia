# Testing

`pnpm test` at the root runs every unit test (333 cases, 2026-10-12). Turbo caches the results; a cold run spends most
of its time in `swift test`'s first build. Each package also runs its own:

| Package | Command | Cases |
| --- | --- | --- |
| `apps/browser` | `pnpm --filter @ardia/browser test` | 228 |
| `packages/core` | `pnpm --filter @ardia/core test` | 32 |
| `packages/sync` | `pnpm --filter @ardia/sync test` (`swift test`, `node --test`, then the rename's launch migration end to end, `scripts/legacy-migration-e2e.mjs`) | 66 + 9 |
| `packages/import` | `pnpm --filter @ardia/import test` (`swift test`) | 26 |
| `packages/ardiacore` | `pnpm --filter @ardia/ardiacore test` (`tests/pip-zoom.test.cc`, compiled with `clang++`) | 1 program |
| `extras/raycast-solara` | `node --test extras/raycast-solara/src/scripts.test.ts` | 6 |

`apps/browser` runs its TypeScript under plain Node, with the real `@ardia/shell` and `@ardia/ardiacore` code:
`src/test-loader.mjs` swaps only the native side. `expo-modules-core` becomes `src/test-native/expo.ts`, which hands
each package the fake of every native module it asks for (`src/test-native/shell.ts`, `src/test-native/ardiacore.ts`),
and `react-native` a few inert views; the packages' `.tsx` files are transpiled with TypeScript on the way in (cached in
`node_modules/.cache/ardia-test-tsx`). The native surface is listed once per package, in `src/nativeModules.ts`
(`ShellNativeModules`, `ArdiaCoreNativeModules`), and the packages can only ask for modules listed there. Each fake is
typed against that list, so `pnpm -C apps/browser typecheck` fails when a native method is added, removed or changed
and the fake isn't. Tests drive the fakes through `src/test-native/index.ts` (`docs`, `chromeVisit`, `windows`,
`engineEvent`, …). One file: `node --no-warnings --import ./src/test-loader.mjs --test src/store/tabs.test.mjs` (from
`apps/browser`).

End-to-end checks need a built app and are run by hand. Each runs hidden instances through `scripts/lib/instance.mjs`
and prints one line per check (PASS/FAIL, ms), a failure's first lines, then a summary with the path of the log that
holds the rest.

A URL handed to a hidden instance (`ARDIA_BACKGROUND=1`) is forwarded to the owner's running app, or the default
browser, unless the instance runs with `ARDIA_ACCEPT_EXTERNAL_URLS=1`. `launch({ urls })` sets it and refuses to
hand URLs to an instance whose env turns it off; any other way of handing an instance a URL must set it too.

| Check | Run | Guards |
| --- | --- | --- |
| Release smoke test | `.claude/skills/release/scripts/smoke.sh` (the `release` skill) | Every release, whole |
| Shortcuts | `node apps/browser/scripts/shortcuts-test.mjs <Debug app> matrix`, then `… presses` | `matrix`: every shortcut in every focus, dry (0.2.8: ⌘1–9 were swallowed outside a page). `presses`: real presses, ⌘T/⌘L/⌘F focus handoffs, ⌘Q. About 6 and 4 min |
| Developer Mode toolbar | `node apps/browser/scripts/developer-toolbar-test.mjs <Debug app>` | RN and native in turn on a 127.0.0.1 page, light and dark: Chromium's NONE and no not-secure badge, the resting and editing URL where RN draws it (1 px at 2x), the URL not moving when editing starts, the dark stripes pixel for pixel, ⌘L editing in place with Return going and Escape keeping the URL. About 1 min |
| Profile swipes | `node apps/browser/scripts/profile-swipe-test.mjs <Debug app>` | The native pager's races (0.2.14–0.2.18 fixes) |
| Tab dragging | `node apps/browser/scripts/tab-drag-test.mjs <Debug app>` | Dragging in the top tab strip moves the tab, never the window (0.2.18); the empty strip moves it over its whole height and a double-click zooms (0.2.25); the empty sidebar under the rows moves it too, and a double-click there still opens a tab |
| Native top strip | `node apps/browser/scripts/top-strip-test.mjs <Debug app>` | The tab strip on RN, then with `ARDIA_NATIVE_TOP_STRIP=1`, holding pinned tabs, groups (expanded, collapsed, one with a nested folder) and a split: every item spans where RN's does at the strip's middle (within 0.5 pt), the native entries are the store's, clicks select a tab and collapse a group, hovering moves nothing, a collapsing group's width follows RN's spring frame by frame (sampled every frame, within a frame's lag and 2 pt), and under 1% of the strip's pixels differ from RN's. About 30 s |
| Windowing | `node apps/browser/scripts/windowing-test.mjs <Debug app>` | Window frames and what the screen shows in passing |
| Hidden panes | `node apps/browser/scripts/hidden-pane-test.mjs <Debug app>` | What changes while a tab is hidden (URL, title, loading, zoom, find bar, a permission prompt) is on screen the moment it is shown |
| Hover layout | `node apps/browser/scripts/hover-shift-test.mjs <Debug app>` | Hovering moves nothing: every hover-tracked view in the sidebar, the tab strip and the downloads popover (below), once with the RN surfaces and once with `ARDIA_NATIVE_OMNIBOX=1 ARDIA_NATIVE_NEWTAB=1` |
| Shell hover | `node apps/browser/scripts/shell-hover-test.mjs <Debug app>` | With `ARDIA_NATIVE_SHELL=1`: the RN sidebar's rows hover, a native view in the shell's overlay slot stops them hovering, a row under a still pointer leaves when the native view arrives and enters when it goes, and finding the layer under the pointer takes under 30 µs |
| Sidebar clicks | `node apps/browser/scripts/sidebar-click-test.mjs <Debug app>` | One click opens a tab or pinned tile: in the frame its hover card appears, under another tile's appearing card, after a New Tab and after closing a pinned tab (0.2.39-nightly.5: tabs needed two clicks) |
| Sidebar bulk changes | `node apps/browser/scripts/sidebar-bulk-test.mjs <Debug app>`, then again with `ARDIA_NATIVE_SIDEBAR=1` | Duplicating 8 tabs, opening 8 and closing 6 at once leaves no slide stuck part way, the rows in store order at a 37 pt pitch, and the hovered row the one drawn at the pointer's y |
| Onboarding | `node apps/browser/scripts/onboarding-test.mjs <Debug app> [--rn \| --native]` | No text field sits behind the onboarding card, a click on the first row's checkbox toggles it, another window keeps its New Tab field meanwhile, and the New Tab field is back and focused once it ends, in a bar of the same height (the hidden New Tab field took the first row's cursor and its checkbox clicks); clicking Continue from the source step through the outro ends it with the outro saved. The native overlay through `devOnboarding`, the RN one with `--rn` |
| Settings layout | `node apps/browser/scripts/settings-shift-test.mjs <Debug app> [--rn]` | Nothing in a Settings pane moves, appears or changes after its first frame, on every pane; search: ⌘F focuses, typing finds the row, Return opens its pane with the row in view and highlighted, Escape clears. The native window through `devSettingsSwitch` and `devSettings("search")`, the RN one with `--rn` |
| Settings reopen | `node packages/settings/scripts/settings-reopen-test.mjs <app>` | The native Settings window, opened, closed and opened again, is key, has its title and back/forward, and takes typing (the reused pre-built view lost its toolbar and kept a switch focused, so a reopened window took no keys) |
| Internal pages | `node apps/browser/scripts/pages-test.mjs <Debug app>` | The native pages behind `ARDIA_NATIVE_PAGES=1`, driven by clicks and keys: Downloads lists the window's downloads, search filters and Escape clears, ✕ removes one, Clear All keeps the running ones; History groups by day, search filters, hover shows a row's checkbox, click and shift-click select, Cancel clears, and Clear Browsing Data… clears and closes; Bookmarks opens folders from the tree, searches across folders, selects with click, ⌘-click and shift-click, deletes with an Undo toast, and moves a dragged row; the ⌘D popover and the bookmark editor: Return, Esc, a click outside, the folder picker, Remove, and no Save without a URL; Create a Profile: Return creates, a preset shares data, Esc and a click outside create nothing; the calendar preview lists the fixture's events (`ARDIA_CALENDAR_FIXTURE=1`) and a row shows the calendar tab; the meeting alert's Join opens the meeting and Ignore dismisses it; the page prompts (permission, password, autofill, external app, engine offer, device chooser, blocked pop-ups) open in a native `PopoverView` on the card RN draws (within a point, from a second instance without the switch); Esc or a click on the page leaves the first six unanswered and closes the pop-ups list, and a pop-up's row opens just that one, as RN does; under the native shell the meeting alert is a native frame in `shell.overlay` at RN's spot (300 wide, 52 from the top), Join opens the meeting and ✕ dismisses it |
| Folder panel | `node apps/browser/scripts/folder-panel-test.mjs <Debug app>` | The pinned tiles' folder panel drawn by RN and then natively (`ARDIA_NATIVE_SIDEBAR=1`: `SidebarFolderPanelView` in the sidebar's panel layer), clicked through the window: a click on the folder tile opens it under the tile with the member rows on RN's window frames (within half a point), a row shows its tab and closes the panel, and a click on the page, a second click on the tile and Escape each close it, as in RN |
| Sidebar scroll | `node apps/browser/scripts/sidebar-scroll-test.mjs <Debug app>` | The pinned tiles hold still while the tabs scroll (Dia's dock), with the address field in the sidebar and without: a row dragged onto a tile after a scroll pins it there, selecting a tile while scrolled leaves the list put, and a dock too tall for the window scrolls with the tabs |
| Sync | `node packages/sync/scripts/e2e.mjs <Debug app>` | Two and three hidden instances through one folder (`docs/sync.md`) |
| Import | `node packages/import/scripts/e2e.mjs <Debug app> <scratch dir>` | Cookies, addresses and cards from a fake Chrome home (`packages/import/README.md`) |
| Media controls | `node apps/browser/scripts/media-ui-test.mjs <Debug app> [--native]` | On a local tone page: the sidebar player shows for a playing tab out of view, play/pause reaches the page, Close Player hides it without pausing or switching tabs, a new play brings it back, Back to Tab ends it; the hover player's marquee and clock tick at RN's pace; the CLI pill's in and out timing; the cast and share pickers open at RN's size (340 × 185, 460 × 423) and answer their buttons. `--native` runs the AppKit ports (`ARDIA_NATIVE_MEDIA=1`) and clicks them |
| Little Solara | `node apps/browser/scripts/little-solara-test.mjs <Debug app> [--native]` | The small window on a local page: the field at SmallChrome's 84, 5, 28 high and the buttons at the right, a field click opens the command panel, which grows from the field to RN's dropdown frame (max(350, field + 137) wide, radius 12; port-omnibox's native panel in its dropdown mode, RN's Grow under `ARDIA_NATIVE_OMNIBOX=0`), keeps a click on its field inside the bar and closes on a click on the card, a click on the bar's blank part leaves the window alone, Open in Solara moves the tab to the main window, and a relaunch handed a link as another app hands it (`ARDIA_ACCEPT_EXTERNAL_URLS=1`: a hidden instance otherwise passes outside links on to another copy or the default browser) opens it in Little Solara, not the main window, through the early link window (the Debug-only `engineInfo().earlyLinkWindow` is `shown`, or the reason it was skipped). `--native` runs the AppKit shell (`ARDIA_NATIVE_MEDIA=1`): backdrop, bar and RN slots in that order, the card inset 6 below the 38 pt bar, the RN root's fill cleared |
| Sad tab | `node apps/browser/scripts/sad-tab-test.mjs <Debug app>` | A crashed tab (This tab needs to reload, Reload) and an unresponsive one (the dimmed pane under a 320 wide card with Exit Page and Wait), drawn by RN and then by the native `SadTabView` (`ARDIA_NATIVE_SHELL=1`: a container on top of the shell's card, each view framed to the page area RN measures): the overlay and its buttons sit in the same window frames in both (within one pixel), Reload and Wait clicked through the window clear the state, and the native container leaves the card once nothing shows |
| Zoom popover | `node apps/browser/scripts/zoom-popover-test.mjs <Debug app>` | The zoom popover over a local page under RN's shell and then the native one (`ARDIA_NATIVE_SHELL=1`: its `PopoverView` in the pane overlay container on top of the shell's card, framed to the page area RN measures, no RN-hosted `NativePanelView`): the card 236 wide, 8 from the page's right and top, 49 high, fully faded in; Zoom In clicked through the window zooms the tab and keeps it open; a click on the page outside the card dismisses it without touching the zoom or the active tab |
| History popover | `node apps/browser/scripts/history-popover-test.mjs <Debug app>` | The back button's history popover on a tab that went ONE, TWO, THREE, with RN hosting the native panel and then under the native shell (`ARDIA_NATIVE_SHELL=1`: `HistoryPanelView`'s `PopoverView` in the pane overlay container on top of the shell's card): the native card where the hosted one is placed (300 wide, 8 from the page's top, RN's left from the back anchor) with TWO and ONE, fully faded in; a click on ONE through the window goes back and closes it; a click outside the card closes it without navigating |
| Selection search bar | `node apps/browser/scripts/selection-popover-test.mjs <Debug app>` | The bar over a selected word on a local page with a local custom search engine, drawn by RN and then under the native shell (`ARDIA_NATIVE_SHELL=1`: `SelectionBarView` in the pane overlay container on top of the shell's card): 6 above a word (below one near the top), centred and kept 8 inside the page, fully faded in, with no RN bar; bar and Search button on RN's window frames within half a point; a click on Search through the window searches the engine for the word and takes the bar down |
| Downloads popover | `node apps/browser/scripts/downloads-popover-test.mjs <Debug app>` | The popover with two finished downloads, drawn by RN and then under the native shell (`ARDIA_NATIVE_SHELL=1`: `DownloadsPanelView` in the shell's overlay container): the card where its placement puts it (left, width, top or bottom, the arrow's height on the button's side), fully faded in, with no RN panel; the native list as tall as RN's and the card on RN's frame for the same placement; through the window, View all downloads opens the downloads page and closes it, a click away closes it and changes nothing, Clear empties the list and closes it |
| Drops under the native shell | `node apps/browser/scripts/shell-drop-test.mjs <Debug app>` | With `ARDIA_NATIVE_SHELL=1` and `ARDIA_NATIVE_SIDEBAR=1`, the view AppKit would hand a file, URL or text drop at a point on the page (`devDropTarget`: the frontmost view there registered for the type) is Chromium's web contents: with the page alone, beside the zoom popover in the pane overlays, with the native sidebar's hover card up (in the shell overlay, shown, opaque, inside the window and its fill in a window snapshot where it changes what the window shows, before and after the drops) and on both panes of a split under the native split chrome; a drop on the zoom popover's card goes to the same kind of view as in an RN instance (both fall through to the page) |
| Native sidebar hover cards | `node apps/browser/scripts/hover-card-test.mjs <Debug app>` | With `ARDIA_NATIVE_SIDEBAR=1`, `ARDIA_NATIVE_SHELL=1` and `ARDIA_NATIVE_MEDIA=1`: the card in the shell overlay waits for the 500 ms hover intent and RN draws none of its own, and a long title truncates on its second line where RN's does; moving onto it keeps it past the 160 ms hide delay; its Pin button pins the tab; it leaves on hover away, a click in the sidebar and a space switch, and stays through a tab switch as RN's does; a collapsed group's card lists the group's tabs, takes the keys once the pointer is on it, filters to a typed match and switches to it on Return; a live pull request's card opens the pull request from its comments line; a playing pinned tab's 320 × 76 player card goes back to the tab from its artwork; a pinned calendar tab's 300-wide card lists the fixture's events (`ARDIA_CALENDAR_FIXTURE=1`) and a click on one shows the tab |
| Native sidebar rename | `node apps/browser/scripts/sidebar-rename-test.mjs <Debug app>` | With `ARDIA_NATIVE_SIDEBAR=1`: a click on the empty sidebar under the rows keeps a tab's typed name, closes the field and opens no tab, also when a second click follows at once; Esc still cancels |
| Swipe capsule | `node apps/browser/scripts/swipe-capsule-test.mjs <Debug app>` | The back-swipe capsule on a tab that went ONE, TWO, THREE, drawn by RN and then by `SwipeCapsuleView` (`ARDIA_NATIVE_SHELL=1`: in the pane overlay container on top of the shell's card, fed by RN's `SwipeOverlay`, which keeps the gesture): the same simulated gestures give the confirmed 82 pt capsule centred on the page (cancelling it navigates nowhere) and the 200 × 92 destination list with its first row centred (ending it goes back one); native and RN frames agree within half a point, RN draws no capsule with the switch on, and the native container leaves the card after the fade |
| Pane overlay slots | `node apps/browser/scripts/pane-overlays-test.mjs <Debug app>` | `PaneOverlays` under `ARDIA_NATIVE_SHELL=1 ARDIA_NATIVE_PAGES_POOL=1`: each pane of a split gets a visible slot equal to its page area in `SplitPanesView`; a fullscreen pane hides the other pane's slot and fills the card; leaving fullscreen shows both again; separating the split leaves one slot. Fullscreen is set through page state, so the hidden instance never takes a Space |
| Pane roots | `node apps/browser/scripts/pane-roots-test.mjs <Debug app>` | Per-tab RN pane roots in the `PaneOverlays` `.rn` slots under `ARDIA_NATIVE_SHELL=1 ARDIA_NATIVE_PAGES_POOL=1 ARDIA_SHELL_PANES=1`: the active tab gets one root, which draws the page overlays (the find bar renders under it, not under the main root); switching tabs retires the old root and ends it after the 1 s grace; a split gives each pane a root; a fullscreen pane retires the other pane's root and leaving fullscreen brings it back; closing a tab ends its root at once. Ended roots are unmounted in JS, not just removed |
| Pane roots placement | `node apps/browser/scripts/pane-roots-placement-test.mjs <Debug app>` | The page overlays land in the same place from the main root (`ARDIA_SHELL_PANES=0`) and from the pane roots (`=1`) under the native shell: in a split and after resizing it, the find bar and CLI pill frames match and the window snapshots match pixel for pixel (bar the dimmed main-root overlays the shell draws under the native split pane without pane roots); with the toolbar hidden while scrolling the status bubble slides as far, frame by frame; while the dock peek slides in with the address bar in the sidebar, Site Controls is drawn exactly once every frame |
| Main root on top | `node apps/browser/scripts/main-top-test.mjs <Debug app>` | With `ARDIA_SHELL_MAIN_TOP=1` (and the shell, pane roots and pages pool switches), once with the native sidebar and once with RN's: the RN main root sits under the shell's overlay and above every other layer; no RN view that draws nothing and handles nothing catches the pointer over the card, sidebar or top strip (`devReactBlockers` names each RN view there with no background or content, and one with its own mouse enter or leave handler, or a press, click, drop or responder handler on itself or a parent at most twice its area, counts as a control; the report names the parent and prop); a click on the page lands outside the main root and focuses the page; file, URL and text drops there reach the web contents. The gate for the pool: until it takes the pages out of the main root, the click check fails on that |
| Closing a selection | `node apps/browser/scripts/close-selection-test.mjs <Debug app>` | ⌘W with three tabs selected, as a key press on the window, on the RN sidebar, the native sidebar (`ARDIA_NATIVE_SIDEBAR=1`) and the JS store (`ARDIA_NATIVE_STORE=0`): the File menu item reads "Close 3 Tabs", all three close and the selection clears, and one ⇧⌘T brings all three back in place; with a New Tab in the selection, ⌘W asks once (the confirm stubbed to Cancel) and cancelling closes nothing |
| Video upscaling | `node apps/browser/scripts/video-upscaling-test.mjs <Debug app> [--keep] [check…]` (`--list`) | What the GPU process upscales in every state the gate decides (playing, paused, native size, background tab, app inactive, occluded, Low Power, thermal, PiP, HDR, full screen, Little Solara, setting off), from its `ArdiaVSR.*` trace events and `videoUpscalingState()` |
| Engine patches | `python3 engine/patches/series.py check` | The patch series reproduces the Chromium tree (`docs/engine-build.md`) |
| Engine (ArdiaCore) | `node packages/ardiacore/scripts/acceptance.mjs <Debug app> <scratch dir> [--keep] [check…]` | The app on ArdiaCore, hidden (`docs/ardiacore-parity.md`). `--keep` leaves the instance up and `--attach <scratch dir> [check…]` re-runs checks on it in seconds; `--list` gives each check's section and what it needs (brought along automatically) |
| Focus (ArdiaCore) | `node packages/ardiacore/scripts/activation-acceptance.mjs <Debug app> <scratch dir> [check…]` | The panes shown, Chrome's active tab and native focus agree |
| Native perf | `node apps/browser/scripts/perf/native-bench.mjs --app <Release app> --out <dir>` | Launch, idle, memory, tab and window latency; the release perf gate (`docs/perf/README.md`) |
| JS perf | `node apps/browser/scripts/perf/js-bench.mjs run --app <Release app> --bundle <main.jsbundle> --label <name>` | What each interaction costs the JS thread (`docs/perf/README.md`) |

## Test instances

Launch with `scripts/agent/ac launch <app> --data <dir> [--env NAME=value]…` (`--help`; then `ac eval`, `ac page`,
`ac quit`), or `launch()` in `scripts/lib/instance.mjs`. `ARDIA_BACKGROUND=1` and a scratch `ARDIA_DATA_DIR`
make an instance a test instance; the rest are hooks for one test.

| Variable | Read in | What it does |
| --- | --- | --- |
| `ARDIA_BACKGROUND=1` | everywhere (below) | A hidden test instance (below) |
| `ARDIA_DATA_DIR` | `ArdiaCoreHost.mm`, `packages/shell` `ACIsolation.m` | Scratch data dir (below). A Debug build refuses to start without one |
| `ARDIA_REMOTE_DEBUGGING_PORT` | `ArdiaCoreHost.mm` | CDP on that port (`--remote-allow-origins=*`), only on Chrome's mock keychain (a scratch `ARDIA_DATA_DIR`, or an ad hoc build). A team-signed build on its real data dir ignores it, forwards neither argv nor `ARDIA_CHROMIUM_SWITCHES`, and its browser process removes every switch that would open the profile to outside control, however it's spelled, at startup and again once chrome://flags have become switches, and unsets `SSLKEYLOGFILE` (`ac_main_delegate.cc` `kSwitchesThatOpenTheProfile`; `--ardia-show-profile-gate` logs the parsed and gated command lines both times) |
| `ARDIA_JS_LOCATION=host:port` | `AppDelegate.swift` | This launch's Metro, never written to defaults |
| `ARDIA_CHROMIUM_SWITCHES` | `ArdiaCoreHost.mm` | Extra Chrome switches, space-separated (background mode drops the auto-accept capture ones); only on Chrome's mock keychain, like argv |
| `ARDIA_ALLOW_OCCLUSION=1` | `ArdiaCoreHost.mm` | Background mode keeps Chrome's occlusion. macOS posts no occlusion change for a window a band below normal, so minimizing and deminiaturizing post one for it (the page goes hidden as in a user's minimized window) |
| `ARDIA_ALLOW_AUDIO=1` | `ArdiaCoreHost.mm`, `IntroMusic.swift` | Background mode keeps sound |
| `ARDIA_DOWNLOADS_DIR` | engine `ac_downloads.cc` | Chrome's download folder for this launch: the pref's default, never written to the profile (a folder the user picked still wins) |
| `ARDIA_TEST_REAUTH=granted` | engine `ac_reauth.cc` | Background mode grants macOS re-auth requests (otherwise refused, each reported as `reauth.requested`). Only builds that aren't signed for distribution (Debug, ad hoc) and run on Chrome's mock keychain honor it, so it can never reveal what the real "Ardia Safe Storage" key encrypts; a Developer ID build refuses every request in background mode |
| `ARDIA_CONTEXT_MENU_LOG` | engine `ac_context_menu.mm` | Context menus go to the host instead of the screen, in any build; the pick runs on the model that owns it, logged as `[ardiacore-menu]` in the system log |
| `ARDIA_FAKE_FULLSCREEN_MS` | `ArdiaCoreChromeWindow.mm` | Length of the acted-out full-screen transition (the window takes the screen's frame as it starts and its old frame back on the way out, as AppKit does). Dev actions (`devWindow`): `fakeFullScreen:<1\|0>[:<ms>]`, `fakeFullScreenMs:<ms>`, `fakeOcclusion:<visible\|occluded\|off>` (macOS's occlusion state; a test window otherwise counts as seen), `fakeFullScreenOcclusionMs:<ms>` (acted transitions occlude the window, visible again `<ms>` after they end, as a real Space animation), `pageCover:<1\|0>` (the page's picture over it through transitions, `ACPageCover`; 0 is 0.2.30's behavior), `fullScreenProbe:<ms>` then `fullScreenProbe` (per display frame, what an in-process render of the window, all AppKit's transition shows, has in the page's place: an 8 × 6 color grid, uniformity, covers; acceptance `fullscreen-transition-picture`) |
| `ARDIA_TRAFFIC_LIGHTS_LOG=<file>` | `ArdiaCoreChromeWindow.mm` | Logs every traffic-light change (test instances only) |
| `ARDIA_PIP_SELFTEST` | `ArdiaCorePictureInPicture.mm` | On the first PiP window: `close` / `backToTab` click Chrome's buttons (`pip-button-selftest.json`: closed, the prevents-activation tag, app activations), `hover` holds the controls up (`pip-hover.json`, `ARDIA_PIP_HOVER=close\|back`), anything else runs the style self-test (`pip-selftest.json`), all in the data dir |
| `ARDIA_TRACE_PIP=1` | engine `ac_picture_in_picture.mm` | PiP windows opening and closing, to `/tmp/ac-pip-trace.log` |
| `ARDIA_TRACE_VISIBILITY=1` | `ArdiaCoreHost.mm`, `ArdiaCoreWebView.mm` | Logs occlusion and each WebView attach/detach (`[ardiacore-vis]` in the system log) |
| `ARDIA_SHADERS_FORCE_KEY=1` | `MetalSurface.swift` | Metal views act as in the key window (the New Tab intro) |
| `ARDIA_RELEASE_NOTES=1` | `AppModule.swift` | Opens the release notes as after an update |
| `ARDIA_UPDATE_FEED_URL` | `Updater.swift` | Sparkle's feed; an instance with a scratch data dir checks for updates only with one |
| `ARDIA_CLI_HOME`, `ARDIA_CLI_BIN_DIR`, `ARDIA_CLI_URL`, `ARDIA_CLI_INSTALL_SCRIPT` | `CliInstaller.swift`, `apps/cli/install.sh` | Where the `ardia` command installs, where its link goes, the tarball to fetch (`file://` works) and another installer script (test instances only). A test instance installs or upgrades only with the first two set, so it never touches the real home. Its `--remote-debugging-port` makes the "Let the ardia command control Ardia" setting stand aside; test that setting in an instance launched without one |
| `ARDIA_SYNC_DEFAULT_FOLDER` | `SyncModule.swift` | The sync folder (`packages/sync/scripts/e2e.mjs`) |
| `ARDIA_IMPORT_SOURCE_DIR`, `_SAFARI_HOME`, `_TEST_SECRET`, `_DIA_BUNDLE_ID` | `ImportModule.swift` | Import from fixtures: the Application Support root, Safari's home, a fixed Safe Storage secret instead of the keychain, the app Dia's tabs come from (`packages/import/README.md`) |
| `ARDIA_ONBOARDING=1`, `_WHATS_NEW=1`, `_TELEMETRY=1`, `_LIVE_MOCK=<url>`, `_CALENDAR_FIXTURE=1` | JS, Debug builds only (`launchEnvironment`) | Run onboarding, show What's New, send telemetry, serve live folders from a mock, use the calendar fixture |

`ARDIA_BACKGROUND=1` changes:
- **Activation:** the process is BackgroundOnly and every activation path is refused and logged to
  `$ARDIA_DATA_DIR/activation.log` (`ArdiaCoreActivation.mm`). File panels never show: they answer with the paths in
  `$ARDIA_DATA_DIR/file-chooser.txt` (one a line, consumed), or cancel. Context menus are reported, not shown.
  It reads as active all the same (`-[NSApplication isActive]`, the one fake), and AppKit's key window follows as in an
  active app: the window made key is key and its notifications go out, so focus runs production's path. A check
  plays the user leaving for another app with `devWindow(n, "fakeAppActive:0")`. Metal views act as in the key
  window too (the New Tab intro plays in it).
- **Clicks:** `devWindow(n, "mouse:<down|up|dragged|moved>:<x>,<y>[,<clicks>]")` posts one event to the queue as the
  window server would (x, y from the window's top left), so a text field's mouse tracking sees its own mouse-up; a
  script times the up itself. AppKit still keeps an inactive app's first click on unselected text or a page to
  itself: `devWindow(n, "fakeActiveClicks")` lets them through, as in the active app. `devWindow(n,
  "responderChanges")` lists the first-responder changes since the last call with their stacks (who took a field's
  focus).
- **Windows:** they stay behind every other app's windows: each window's level is set a band below normal (normal at
  CoreGraphics layer -1000000, floating at -999997…; `-level` answers the one asked for), so no ordering, activation
  attempt or AppKit reshuffle lifts one over the owner's, the app's own keep production's order, and Mission Control
  leaves them out (`ArdiaCoreActivation.mm`). `[NSApp activateIgnoringOtherApps:]` and `activate` are refused and
  logged. With `ARDIA_ALLOW_OCCLUSION=1` a window the owner's cover is really occluded.
  Full screen is acted out (no new Space); windows answer NO to `-[NSWindow isOccluded]`, so a covered
  window shows a tab at once instead of after Chrome's 1 s delay, with `--disable-backgrounding-occluded-windows`;
  PiP windows stay at alpha 0 and click-through; the drag preview stays above its own window only.
- **Media:** `--mute-audio` (Chrome then reports no tab as audible, so the speaker never lights; the ArdiaCore
  acceptance run sets `ARDIA_ALLOW_AUDIO=1` with `--disable-audio-output`, so Chrome still hears its -60 dBFS fixtures and the speakers get nothing), no intro music, `--use-fake-device-for-media-stream` with the microphone kept on a fake
  input (`ac_fake_media.mm`), and `--disable-modal-animations` (a locked screen never ends a dialog's close animation).
- **Other:** macOS re-auth prompts never show; requests are refused unless `ARDIA_TEST_REAUTH=granted` in a build that
  honors it (above). Nothing system-wide changes: Set as Default (onboarding, whose checkbox starts unticked, and
  Settings), Chrome's own default browser, scheme and file type setters, Add to Dock and Launch at Login are no-ops
  that log a line (`ArdiaSystem`, `chromium-background-instance-no-default-handlers.patch`).

A scratch `ARDIA_DATA_DIR` holds Chrome's user data and the app's documents, its defaults, keychain items and
Sparkle state (`ACIsolation.h`); Chrome gets `--use-mock-keychain`; update checks are off without
`ARDIA_UPDATE_FEED_URL`; a Release build's telemetry is tagged `test`, and the release-notes page stays closed
unless `ARDIA_RELEASE_NOTES=1`.

A Release or RC build starts the dev harness (`dev-eval.js`) only when `$ARDIA_DATA_DIR/perf-probe` exists in a
test instance (`src/lib/perfProbe.ts`): `: > "$ARDIA_DATA_DIR/perf-probe"` before launch, as
`.claude/skills/release/scripts/smoke.sh` does.

Input and capture hooks on `ac.shell` (Debug builds only; a Release build answers nothing or `null`), for driving
the app as a person would rather than writing a new helper:

| Hook | What it does |
|---|---|
| `devKeyEquivalent(windowId, { key, keyCode, modifiers, focus, asKey })` | Presses one shortcut through the window's real key path |
| `devTypeKeys(windowId, text, interval)` | Types text into the focused field, a key every `interval` ms; resolves with per-key timings |
| `devMenuCommand(command, arg)` | Fires a menu command as if picked from the menu bar |
| `ArdiaApp.devMenuItems(title, path?)` | A menu bar menu's items as AppKit has them, its own included (Window › Fill, Move & Resize…); `"tiling:<windowId>"` is the window's green-button menu and whether AppKit tiles it; `path` picks an item |
| `ArdiaApp.devPostKey(windowId, key, keyCode, modifiers)` | Posts one key press to the app's event queue (`"menu:<key>"`: straight to the menu bar's key equivalents). System hot keys (fn-⌃ tiling) can't be posted |
| `devSnapshotWindow(windowId, path, transparent?)` | Writes the window's layers to a PNG in-process (works with the screen locked; `false` = failed) |
| `devRenderIntroMusic(cues, path)` | Renders the onboarding intro music to an audio file, for a video's soundtrack |

## Hover never moves anything

A control that shows on hover (a row's ✕, a live folder's refresh, Show in Finder) goes in a `HoverSlot`
(`components/HoverSlot.tsx`): the slot keeps the width of what it shows at rest, at least the control's, and the control
lies over it. `useHover` and `useRowHover` mark their handlers, and the dev harness's `ac.hoverShift.check({ scopes })`
(`src/lib/hoverShift.ts`) hovers each marked view inside the named components in turn, measures every view under its
parent before and while hovered, and returns what moved or resized; only a HoverSlot's inside may change. One
exception, as Dia does it: a row's title may give up its trailing edge to the ✕ (its leading edge, baseline and height
stay, and the slot grows leftward by exactly what the title gives up), and the Clear divider's line may shorten from its
trailing end while its leading edge and y stay. The native downloads list has the same check in Swift
(`SolaraDownloads.devHoverShifts()`), where a label may only give up its trailing edge.
`hover-shift-test.mjs` runs it on the sidebar (with groups, a live folder and its open items), the tab strip and the
downloads popover, in an RN pass and a native pass, and fails on any other shift. Run it after changing anything a
hover touches.

## What's kept, and why

The suite was cut from 412 unit cases to 82 on 2026-10-01. A case stays when breaking what it guards would
lose or leak data, or when the bug is invisible by eye and has shipped before.

| File | Kept | Why |
| --- | --- | --- |
| `apps/browser/src/store/privacy.test.mjs` | Private windows and incognito: nothing in `session.json`, `downloads.json` or favicon files, no history, no closed-tab records, no dragging tabs across; history time-range clearing; profile deletion queues Chrome's data and keeps shared data | Privacy and data loss. 0.2.11 shipped private tabs saved to disk and a deleted profile's data left behind |
| `apps/browser/src/store/session.test.mjs` | v1 → v2 migration; `hydrate` repairing a damaged session; reopened windows keeping back/forward (0.2.12); shared profile data across a reload; `history.json`'s hand-written serializer; pinned tabs unloading on ⌘W, parking with a closed window, coming back once, surviving a relaunch (0.2.2, 0.2.8) | Session and history persistence |
| `apps/browser/src/store/tabs.test.mjs` | Opener placement and close → activate rules; group contiguity; broken splits dropped; clean-up and abandoned New Tab cleanup never closing a window or the shown tab; Chrome's echo of the app's own tab switch; an extension's default search engine; the mini player staying closed (0.2.12) | Core behavior that's hard to see by eye |
| `apps/browser/src/components/omnibox/inline.test.mjs` | Every interleaving of typing and inline completion; stale completions never applied | 0.1.6: fast typing dropped or reordered letters |
| `apps/browser/src/sync/adapters.test.mjs`, `engine.test.mjs` | Bookmark delete-vs-add and move cycles, parked pinned tabs, passwords (newest wins); a crash right after a batch lands; nothing published before its journal is on disk | Sync data loss (0.2.11) |
| `apps/browser/src/sync/pairs.test.mjs` | Two in-memory Macs, every ordered pair of pinned-tab edits (pin, unpin, re-pin, row/tile, moves into groups, new groups, group unpin/re-pin/delete/restyle, rename, loaded pages, a member's page, a trip away and back, and a page copied to a new mirror before its window closes, profile moves) and lifecycle steps (park and reopen, a mirror window, a relaunch through the saved session, a snapshot collecting tombstones 46 days on) in six schedules (one after the other, concurrent, concurrent with a third Mac running the shipped 0.2.38 pinned adapter and scope from `fixtures`, either Mac's log delayed, a third Mac joining from the folder after B's delayed log, A's first log 44 days late while B compacts and a third Mac joins from that snapshot, without the ops that compact again), 7,402 runs in about 8 s: all Macs converge on the same pins, names, icons and group styles, every record names a group that exists, nothing pinned or kept regular is lost, the Mac that unpins a group keeps it, windows, splits and groups stay whole and ordered, each edit's outcome holds (renames, restyles, the page a Mac navigated to is sent, the later explicit choice), and nothing is sent once settled. Fourteen more cases: a member waiting for a group that never comes stands alone after 90 days on an idle Mac; seven page changes (a member navigated behind another window, copied to a new mirror whose window then closes, copied to a third window, a new group's mirror navigated before its first sync, navigated and unpinned then re-pinned elsewhere, a tile navigated then moved into a group, a mirror copy navigated in front), each with and without an edit from the other Mac, sent exactly as the shipped 0.2.38 adapter sends them, checked side by side; a Mac keeps the regular group it unpinned when the other restyles the pinned one; and, as documented in `docs/sync.md`, two Macs showing a pin at different pages, the page-change-versus-unpin conflict and three compaction residuals. The settle checks let a pin two Macs show at different pages keep sending; anything else must go quiet | Concurrent pinned-tab sync (0.2.40) |
| `apps/browser/src/telemetry/sanitize.test.mjs` | URLs, hosts, paths, user names, quoted text, emails, dev hosts and NSException reasons never leave the Mac | Privacy: telemetry must never carry what the user browsed |
| `packages/core/src/url.test.ts` | Typed text → URL (`resolveInput`, `fixupUrl`); IDN homograph spoofing stays punycode; tracking parameters stripped without touching the rest; `ardia://` shown, never `chrome://` | URL parsing and security |
| `packages/core/src/suggest.test.ts` | Inline completion never fills a long sign-in URL; free text never autocompletes; open tabs switchable; frecency ranking; a newer fetch aborts the older one | Omnibox ranking |
| `packages/sync` | The 9 convergence cases above, and the crypto's 5 (`docs/sync.md` › Tests) | Sync correctness and encryption |
| `packages/import/tests/ImportTests.swift` | Importing never writes to the source profile, never leaves its data folder, decrypts logins only with the right key and only after consent | Another browser's data and secrets |
| `extras/raycast-solara` | Tab and profile ids, and what's typed into New Tab, are quoted in the AppleScript it sends; its answer reads back into the right tabs and profiles; a profile name matches whole, then by a start only one profile has, ignoring case, and a start several share names them instead of picking one | Script injection; New Window opening the wrong profile |

## What went, and why

| Removed | Why |
| --- | --- |
| Spring, rubber-band, capsule and layout constants (`swipeMotion`, `stripGroups`), group naming and labels, numbered tabs, release-note postcard timing, favicon index bounds | Pin exact constants or formatting; a visual check catches these |
| Calculator, quick-create commands, Tab-to-search, text fragments, custom engine validation, most `appUrls` cases | Small pure helpers whose failure is visible the moment you use them |
| Live folders (GitHub, Meetings), Little Solara, splits beyond integrity, organize beyond clean-up, OTLP encoding | Feature detail rather than data or security; covered by use |
| The rest of `pinnedClose`, `openers`, `idn`, `suggest`, `sanitize`, sync and import | Variations of a kept case |
| `profile-pager-race-test.mjs` | Loaded the pager's source with its dependencies mocked; `profile-swipe-test.mjs` runs the same races against the real app |
| `profile-motion-stall-test.mjs`, `profile-swipe-replay.mjs` (and the owner's trackpad recording) | One-off investigation harnesses for the native pager, done in 0.2.18 |
| `packages/import/src/index.test.ts`, Swift tests for Dia tabs, file imports, Firefox and Chromium parsing | The JS wrapper is a thin bridge; parsing failures show in the importer's own result |

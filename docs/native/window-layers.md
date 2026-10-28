# Window layers in a shell window

Behind `ARDIA_NATIVE_SHELL=1` a browser window's content view is `WindowShellView`
(`native/SolaraKit/Sources/SolaraUI/WindowShell`). This is the v2 plan: one full-window RN root stays, moved to the
top and made transparent to the mouse, and everything inside the content card is native, with a small RN root per tab
for what RN still draws over a page. [architecture.md](architecture.md) › 4.4 has the page-view ownership.

## The layers, bottom to top

| # | Layer | What it is | Owner |
|---|---|---|---|
| 0 | `backdrop` | `WindowTreatmentView`: vibrancy, the profile tint and wash, the incognito fill | port-shell |
| 1 | `card` | `shell.card`, a shell-owned flipped container at the card frame: corner, shadow, slot geometry. Holds the pool's pages (`TabSlots` `card(w)` and `pane(w, tab)`), the native toolbar, `FrozenPageView` | port-shell (frame), port-omnibox (pages), port-sidebar-live (split panes) |
| 2 | pane overlays | `PaneOverlays.shared.container(windowId:tabId:)`, over each pane's page area below its toolbar, bookmarks and share bars. Inside it: the pool's page < the tab's RN pane root < native pane overlays (sad tab, zoom) | port-sidebar-live (container), port-shell (RN root), port-media (native overlays) |
| 3 | `splitChrome` | dividers, the split toast, the drop hints | port-sidebar-live |
| 4 | `peek` | Peek's page and frame (`TabSlots` `peek(w)`) | port-omnibox |
| 5 | `sidebar`, `topStrip` | the native sidebar and the top tab strip | port-sidebar, port-strip |
| 6 | main root | the window's RN root, full window, `passThroughTouches`, a box-none root in shell mode | port-shell |
| 7 | `overlay` | `shell.overlay` (`NativeWindowShell.overlay(w)`), one shared box-none container for window-level native overlays: popovers, hover cards. It tells hover, once per run-loop turn, when a child is added, removed, moved or hidden; owners call `shell.coverChanged()` only for motion inside a child (a layer animating its own contents) | port-shell (container), port-media, port-sidebar |
| 8 | foreign | views the shell didn't mount (the PiP overlay) stay above every slot | port-media |

`shell.hiddenPages` (`NativeWindowShell.hiddenPages(w)`) sits under every layer, hidden and at the card's size: the
pool parks pages with no slot there. Warm pages (pager neighbours, the drag successor) stay at the bottom of the card,
behind the active page, since Chrome throttles a page under a hidden view.

## Where each RN item goes

| RN today | Where (ContentCard.tsx unless named) | Layer | Owner |
|---|---|---|---|
| `ShellBackdrop`, `WindowProfile`, `ProfileTint` | App.tsx:65 | 0 | port-shell |
| `TabPane` → `TabWebView` | :277 | 1, pool slots | port-omnibox |
| `WindowToolbar`, `Toolbar`, `ToolbarBackdrop`, `BookmarksBar`, `ShareBar` | :304, :427 | 1, native toolbar | phase 4 toolbar |
| `AutoHideBackdrop`, `AutoHideToolbar` | :459 | 1, native | settings-ui |
| `FrozenPage` | :307 | 1, `FrozenPageView` | port-shell |
| `DropTargets`, `fileDrop` (window and file drops) | :320, fileDrop.tsx | 1, the card registers the drag types | settings-ui |
| `NewTabPage`, `EmptyCard`, `InternalPage` | :440 | 2, until each is native | port-shell (hosting) |
| `SplitEmptyState` | :440 | native split pane, else 2 | port-sidebar-live |
| `FindBar`, `StatusBubble`, `CliControlPill` | :495 | 2 | port-shell |
| prompts: permission, password, autofill, external app, engine offer, device chooser | :505 | 2 | port-shell |
| `SiteControls`, `BlockedPopupsPrompt` | :510 | 2 | port-shell |
| `BesidePeekPopovers` (`popoversOverCard`, :259) | :313 | 2, the active tab's root, left of the Peek edge | port-shell |
| `SwipeOverlay`, `HistoryPopover` | layout/SwipeOverlay.tsx:41 | 2 | port-shell |
| `SadTab`, `ZoomPopover`, `NavigationOverlays`, `SelectionPopover` | :499, :512, :516 | 1, native over the page (`pane.overlays` topic) | port-media |
| `SharePicker`, `CastPicker` | :513 | native | port-media |
| `SplitDividers`, `SplitToast`, `SplitToolbarFeed` | :310 | 3 | port-sidebar-live |
| `PeekOverlay`, `PeekPage` | :322 | 4 | port-omnibox |
| sidebar, `TopTabStrip`, `TopStripPeek` | App.tsx:68 | 5 | port-sidebar, port-strip |
| `ExtensionSidePanel` | App.tsx:59 | 1, `TabSlots` `sidePanel(w)`; the shell narrows the card | port-omnibox (page), port-shell (frame) |
| extension popup | ExtensionOverlays.tsx:151 | 6, its page in `TabSlots` `popup` | port-omnibox (page) |
| `CommandPanel`, `DownloadsPopover`, `DownloadMagnet`, bookmark dialogs, `CreateProfileHost`, `SidebarOverlays`, `OnboardingOverlay` | App.tsx:80 | 6 | their areas |
| Little Solara | `LittleArdiaWindow` | not a shell window: stays RN | port-media |

## Rules

- **Pass-through.** The main root and every pane root set `passThroughTouches`, and their root views are box-none, so
  a click lands on the native view under an empty spot. In shell mode the main root doesn't render `BrowserWindow`
  (its full-size row takes every click).
- **Hover goes to what's on top.** Under a `WindowShellView`, a React view doesn't hover where the window's hit test
  lands on a native view stacked above its root; views in the same root keep the geometric rule, so a
  `pointerEvents="none"` hover zone still hovers. Every native layer host returns nil from `hitTest` for itself where
  it draws nothing, and a layer that shows, hides or moves on its own (Peek, popovers, hover cards) calls
  `shell.coverChanged()` when it does, so hover updates under a still pointer. Cursor rects are still open: covered
  views' rects are to be dropped when the cover changes, and native layers set their own cursor.
- **Pane roots** (behind `ARDIA_SHELL_PANES` until the main root moves to the top) are keyed by tab, never by pane,
  and live in that tab's PaneOverlays container. Each is created hidden and shown on `RCTContentDidAppear`, keeps its
  content size across reloads, and runs no first-window, launch-committed or after-first-window effects. A root goes
  1 s after its tab stops being shown in the window, and at once when the tab closes.
- **Prompts anchored to the right** ride the pane root and may trail the card by a frame while the dock moves; that is
  accepted for now and measured.
- **Modals.** While the main root shows a modal (the command panel, a dialog, onboarding), the shell's
  `accessibilityChildren` lists only the main root, so VoiceOver can't reach the layers under it.

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
| 2 | pane surface | one RN root per tab, inside that tab's pane container, above its page and toolbar | port-shell |
| 3 | `splitChrome` | dividers, the split toast, the drop hints | port-sidebar-live |
| 4 | `peek` | Peek's page and frame (`TabSlots` `peek(w)`) | port-omnibox |
| 5 | `sidebar`, `topStrip` | the native sidebar and the top tab strip | port-sidebar, port-strip |
| 6 | main root | the window's RN root, full window, `passThroughTouches`, a box-none root in shell mode | port-shell |
| 7 | `overlay` | native window-level overlays: port-media's popovers and hover cards | port-shell (slot), port-media |
| 8 | foreign | views the shell didn't mount (the PiP overlay) stay above every slot | port-media |

## Where each RN item goes

| RN today | Where (ContentCard.tsx unless named) | Layer | Owner |
|---|---|---|---|
| `ShellBackdrop`, `WindowProfile`, `ProfileTint` | App.tsx:65 | 0 | port-shell |
| `TabPane` → `TabWebView` | :277 | 1, pool slots | port-omnibox |
| `WindowToolbar`, `Toolbar`, `ToolbarBackdrop`, `BookmarksBar`, `ShareBar` | :304, :427 | 1, native toolbar | phase 4 toolbar |
| `AutoHideBackdrop`, `AutoHideToolbar` | :459 | 1, native | port-shell |
| `FrozenPage` | :307 | 1, `FrozenPageView` | port-shell |
| `DropTargets`, `fileDrop` (window and file drops) | :320, fileDrop.tsx | 1, the card registers the drag types | port-shell |
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
- **Hover goes to what's on top.** A React view hovers only when the window's `contentView.hitTest` at the pointer is
  that view's root view or inside it; a native view stacked above the root blocks it. A `pointerEvents="none"` hover
  zone over its own root still hovers. Cursor rects follow the same rule: a layer's cursor rects are clipped to the
  parts of it nothing native covers, or the native view sets its own.
- **Pane roots** are keyed by tab, never by pane, and move with the tab's container as the pool moves it. Each is
  created hidden and shown on `RCTContentDidAppear`, keeps its content size across reloads, and runs no first-window,
  launch-committed or after-first-window effects.
- **Prompts anchored to the right** ride the pane root and may trail the card by a frame while the dock moves; that is
  accepted for now and measured.
- **Modals.** While the main root shows a modal (the command panel, a dialog, onboarding), the shell's
  `accessibilityChildren` lists only the main root, so VoiceOver can't reach the layers under it.

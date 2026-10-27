# Native surfaces against RN: parity audit, phases 0–4 (2026-10-26)

Every finished Swift surface turned on (`ARDIA_NATIVE_OMNIBOX=1 ARDIA_NATIVE_ONBOARDING=1`, the rest on by default)
against the RN versions (`ARDIA_NATIVE_OMNIBOX=0 ARDIA_NATIVE_ONBOARDING=0 ARDIA_NATIVE_NEWTAB=0
ARDIA_NATIVE_STATUS_BUBBLE=0 ARDIA_NATIVE_SETTINGS=0`), one Debug build (`build-parity-dbg`) run as two hidden
instances with the same seeded session and fixtures (a white page, a dark page with `theme-color #191A1E`, a dangerous
download, a MIDI prompt on example.com, a pinned unpacked extension with a badge and a popup). Captures are 2x
`screencapture -l`; the in-process `devSnapshotWindow` confirmed the ones that looked wrong. Pixel numbers are raw 2x
pixels, points are half of them.

## Intentional differences from RN: don't "fix" these toward RN

Native differs from RN here on purpose. Before changing native to match RN, check this list; if a difference might be
deliberate, ask the lead first.

| Surface | What native does | Commit | Why |
|---|---|---|---|
| Settings | The macOS look: `NavigationSplitView`, `Form`, system controls, title and back/forward in the content header, no NSToolbar, and an About pane in the sidebar. Settings parity covers content and behaviour (rows, values, search, navigation, what each control does), not pixels against RN | ca8ec86e | Owner, 2026-10-27 |
| Toolbar URL | Host at SF 13 regular with Dia's host and path colours ((51,51,51) light, 149–161 dark); text 68 px after reload; 1 pt divider; Dia's icon inks | 2d1118bb, e3a336fd, c32561b1 | Matches Dia |
| ⌘L | The URL stays put and the scheme is prepended to its left from cached widths; RN moves the URL | fa6e79e2 | Matches Dia |
| Command bar | Rows show hover only after the pointer moves, not when the list grows under a still pointer | 00a89525 | Matches Dia |
| Status bubble | Dia's timings (0.5 s show, 0.5 s hide, 0.1 s fade), its scheme handling and its light and dark colours | 25a3b373, d637be2d | Matches Dia |
| Developer Mode | URL bar stripes as Dia and Arc draw them (RN drew none on the dark page: bar flat 42, native 42–46) | 92286cb9 | Matches Dia and Arc |
| Not-secure treatment (coming) | Chromium's rules with Dia's red, native only | | Matches Dia |

## Gaps, most noticeable first

| # | Surface | Gap | Numbers | Owner |
|---|---|---|---|---|
| 1 | Settings | A reopened window (⌘W, open again) looks inactive and takes no keys | Typed "x", the search field kept "cookie"; `activation.log` makes it key over and over | settings-ui |
| 2 | Downloads popover | Closed in 79a94f86. Was: no panel, rows drawn straight over the sidebar and page with no fill, border or shadow | Release, light and dark: panel fill, border, arrow and shadow on the same pixels as RN; 16 px differ (max 36 light, 40 dark), all in the progress bar | port-omnibox |
| 3 | Settings | No title and no back/forward in the titlebar | Content 20 pt higher (first heading y 62 vs 82) | settings-ui |
| 4 | Settings | Intentionally native-styled (owner, 2026-10-27), not a gap: Settings is compared on content and behaviour only. Was: colours and chrome differ on every pane | Selected row grey (216) vs blue (108,165,250); sidebar 237/36 vs 219/64; pane 255 vs 240; group box 566 vs 550 pt, no border | settings-ui |
| 5 | Status bubble | Timings and scheme are intentional (Dia's; see Intentional differences). Open until the Release re-check: the dark mode read grey | Dark: fill 107, text 188 (contrast about 2.8:1); RN fill 44, text 224. Light matches Dia (fill 226, text 113, border 203) | status-bubble |
| 6 | Extension badge | Closed in c8f13a73. Was: "12" drawn as "1" | Release, light and dark: badge 2497–2527 × 54–75 px in both, "12" whole, badge pixels identical; icon edge 1 px wider on the left (2488 vs 2489) | port-omnibox |
| 7 | Find bar | Count closed in 6dfce5c4 (was: the total in "1 \| 3" cut in half). Still open: in replace mode the "Replace" and "All" buttons are clipped on the right ("Al"), sit 7.5 pt and 4 pt right of RN's and 0.5 pt lower; `FindTextButton` sizes its label without the cell's 2 pt inset that 6dfce5c4 gave the other labels. "No results" and the replace note sit 0.5 pt lower (the note also 8 pt right, following the buttons) | Release, light and dark. Count and buttons row: max diff 0–1. "No results" 2201–2312 vs 2202–2313 × 145–163 vs 146–164 px, colour (251,99,92) / (191,49,48) in both. Replace ink 2331–2421 vs 2346–2433 px (91 vs 88 wide), All 2463–2490 vs 2471–2492 (28 vs 22). Note "Not in a text field" 189 px wide in both, 2109 vs 2125 px. The native field shows an accent-blue selection where RN's unfocused window shows grey | port-omnibox |
| 8 | Settings › Privacy | Rule counts are stale and read once | 176,026 / 43,797 vs the engine's 254,167 / 44,271 | settings-ui |
| 9 | Settings › Live Folders | Source logos are a generic globe | GitHub, Bitbucket, Notion, Confluence, Drive | settings-ui |
| 10 | Developer Mode | Superseded by fa6e79e2: the URL now stays put on ⌘L by design (see Intentional differences); re-check that it doesn't move. Was: ⌘L edit moved the URL glyphs | 2 pt left, 1.5 pt up: (688,45) → (684,42) px | port-omnibox |
| 11 | Onboarding | Unselected option rows are filled like the selected one | 235 vs RN's 251 with a border | settings-ui |
| 12 | Onboarding | "Light or dark?" preview stays light with Dark selected in dark mode | | settings-ui |
| 13 | Command panel | 1.5 pt taller at the bottom, top 0.5 pt higher, no top border row | Bottom 217 vs 214 px (383 vs 378 with suggestions); bottom border 58 vs 81 | port-omnibox |
| 14 | Toolbar, dark page | Intentional (2d1118bb, Dia's host colours; see Intentional differences). Was: host darker than the icons | Host 161, icons 220 | port-omnibox |
| 15 | Onboarding | No onboarding controls in the accessibility tree; no New Tab field either | | settings-ui, main |
| 16 | Small layout | Profiles caption style, Shortcuts rows 41 vs 43 pt, section gaps +10 pt; "centre" → "center"; prompt button labels 0.5 pt lower; Site Controls top-row glyphs a hair lighter | | settings-ui, port-omnibox |

Matching Dia rather than RN, so not gaps: see Intentional differences above.

## Settled

- Settings' "About" row in the sidebar is native only, and it stays (owner's call, 2026-10-27).
- Settings keeps the native macOS look rather than RN's styling (owner's call, 2026-10-27).

## Re-checks on Release (2026-10-27)

| # | Fix | Result |
|---|---|---|
| 1 | ca8ec86e | Closed: the reopened window is key and takes typing ("x" replaces the kept "cookie"), one makeKey per open |
| 3 | ca8ec86e | Closed: title and back/forward in the content header, title ink 0.5 pt below RN's, content no longer 20 pt high |
| 4 | 42cc78bb, cb7e8ea7 | Superseded: Settings is intentionally native-styled (owner, 2026-10-27); settings-ui is restoring the ca8ec86e look, so no pixel check against RN |
| 8 | 26d150ec | Closed: native reads 254,028 / 44,270; RN was the stale one in this run (176,026 / 43,797) |
| 9 | 5abac41a | Open: letter tiles for all five sources; RN draws its bundled icons (`apps/browser/src/lib/siteIcons.ts`) for GitHub, Notion and Google Drive before the letter tile, and `SettingsFavicon` has no such step |
| 2 | 79a94f86 | Closed in light and dark (see row 2) |
| 6 | c8f13a73 | Closed in light and dark (see row 6) |
| 7 | 6dfce5c4 | Count and "No results" closed; replace-row buttons clipped and offset, labels 0.5 pt low (see row 7) |
| 5 | d637be2d (in progress) | status-bubble, from Dia's dark values |

## Same in both

- Toolbar at rest (light and dark), the command panel's contents and rows, Return / ⌘Return / ⌥Return / ⇧Return as real
  key events, Escape, `omnibox-parity.mjs` (16 scripts).
- New Tab: hero, bar and chip pixel-identical (only the caret differs); ⌘T then typing at once keeps every key; Escape
  clears it.
- Developer Mode bar on light and dark pages; edit Return navigates the same tab, Escape restores the URL.
- Find bar layout and matches; Escape returns focus to the page.
- Permission prompt layout; Site Controls layout; the extension popup and its anchor.
- Settings search, last pane and search text kept, window frame; onboarding's flow (19 Continues), the 52 settings it
  writes; the Import window at rest.

## Tests

- Read RN's internals, so they don't test the native surface: `onboarding-test`, `settings-shift-test`,
  `window-toolbar-test` (8 address checks), `hidden-pane-test` (URL and zoom while hidden).
- `layout-shift-test` passes on both, but native makes 2–3x the React commits at launch (355/318/320/272 vs
  169/116/145/92).
- Fail on both: `shortcuts-test` ⌘D / ⌥⇧⌘D and the ⌘L-panel checks, `hover-shift-test` (its `setState` downloads write
  trips the native store's guard and LogBox crashes Debug), `hidden-pane-test` "loading".

## Not covered

Hover states (`devSetPointer` changed neither toolbar), right-click menus and dragging the URL out (no hooks), animation
frame timings, 1x, Settings sub-sheets, the Import flow from a fixture source, and a pixel pass on the Release build.
Once, the native window went from 1280×800 to 1257×857 during the find-bar step; it didn't happen again.

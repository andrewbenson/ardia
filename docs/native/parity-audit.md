# Native surfaces against RN: parity audit, phases 0–4 (2026-10-26)

Every finished Swift surface turned on (`SOLARA_NATIVE_OMNIBOX=1 SOLARA_NATIVE_ONBOARDING=1`, the rest on by default)
against the RN versions (`SOLARA_NATIVE_OMNIBOX=0 SOLARA_NATIVE_ONBOARDING=0 SOLARA_NATIVE_NEWTAB=0
SOLARA_NATIVE_STATUS_BUBBLE=0 SOLARA_NATIVE_SETTINGS=0`), one Debug build (`build-parity-dbg`) run as two hidden
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
| Status bubble | Dia's timings (0.5 s show, 0.5 s hide, 0.1 s fade), its scheme handling and its light colours. Dark mode is ours, owner-approved 2026-10-27 (asked to fix dark only): an opaque #2B2B2B fill instead of the popover material, text at white 0.85 instead of secondaryLabelColor, Dia's 1 pt white 0.20 border; light unchanged | 25a3b373, d637be2d, adb6456c | Dia in light; ours in dark |
| Not-secure treatment | Chromium's security level (`WARNING`, `DANGEROUS`) drawn as Dia's red badge and red URL with its scheme; RN keeps its grey lock on the same levels | 065c15c2 | Matches Dia |

## Gaps, most noticeable first

| # | Surface | Gap | Numbers | Owner |
|---|---|---|---|---|
| 1 | Settings | A reopened window (⌘W, open again) looks inactive and takes no keys | Typed "x", the search field kept "cookie"; `activation.log` makes it key over and over | settings-ui |
| 2 | Downloads popover | Closed in 79a94f86. Was: no panel, rows drawn straight over the sidebar and page with no fill, border or shadow | Release, light and dark: panel fill, border, arrow and shadow on the same pixels as RN; 16 px differ (max 36 light, 40 dark), all in the progress bar | port-omnibox |
| 3 | Settings | No title and no back/forward in the titlebar | Content 20 pt higher (first heading y 62 vs 82) | settings-ui |
| 4 | Settings | Intentionally native-styled (owner, 2026-10-27), not a gap: Settings is compared on content and behaviour only. Was: colours and chrome differ on every pane | Selected row grey (216) vs blue (108,165,250); sidebar 237/36 vs 219/64; pane 255 vs 240; group box 566 vs 550 pt, no border | settings-ui |
| 5 | Status bubble | Closed (adb6456c): dark mode now reads the same over any page (owner-approved values, see Intentional differences) | In-process 2x snapshots, the same over a white and a #1E1E1E page: fill #2B2B2B, text white 0.85 (10.6:1 by the design values; the snapshot reads 56/229, 9.3:1, as it reads #1E1E1E as 40). Was, Release captures: dark/white 107/188 (2.81:1), dark/dark page 28/153 (5.98:1); light unchanged at 226/113 (3.77:1) | port-omnibox |
| 6 | Extension badge | Closed in c8f13a73. Was: "12" drawn as "1" | Release, light and dark: badge 2497–2527 × 54–75 px in both, "12" whole, badge pixels identical; icon edge 1 px wider on the left (2488 vs 2489) | port-omnibox |
| 7 | Find bar | Closed (6d9cf824, re-measured 2026-10-27): in replace mode Replace and All are whole and on RN's pixels; the count and "No results" rows as before. The replace row's swap icon and "Replace" placeholder draw at their tokens (textSecondary 0.5, placeholder 0.4), darker than RN's rendering; Dia is the reference and its placeholder is black 0.40 and secondary text 0.60 (dia-spec › Color tokens), so native keeps the tokens (lead, 2026-10-27) | Light, 2x in-process: Replace 2492–2580 × 225–246 px and All 2624–2650 × 225–242 in both; placeholder and icon positions equal. Ink, native vs RN: placeholder 263 vs 153, swap icon 150 vs 87 (RN at 0.58 of native), the search icon equal (65), the buttons 703 vs 624 | port-omnibox |
| 8 | Settings › Privacy | Rule counts are stale and read once | 176,026 / 43,797 vs the engine's 254,167 / 44,271 | settings-ui |
| 9 | Settings › Live Folders | Closed in 249dd8c2: GitHub, Notion and Google Drive show RN's bundled icons (`siteIcons.ts`, read from the app's `assets/assets/site-icons`), Bitbucket and Confluence the letter tile, as RN (both sources dropped 2026-10-30). A Debug build draws letter tiles for all of them, since Metro serves the icons and the bundle has none. Was: a generic globe | In-process render (SettingsFavicon at 18 and 22 pt, 2x, light and dark) against each PNG drawn RN's way (same size, corner radius 3 / 4): mean difference 1.0–3.7 of 255 for GitHub and Notion, 5.4–6.0 for Drive (colour management on its saturated fills); no visible difference | settings-ui |
| 10 | Developer Mode | Closed (cf31f36c): the in-place editor sits on the resting label's frame, 1 pt down, so the URL doesn't move when editing starts; `developer-toolbar-test.mjs` checks it against RN in light and dark. Developer Mode tabs no longer fall back to the RN toolbar | Rest and edit 688–1173 × 45–65 px, light and dark, as RN; was 2 pt left, 1.5 pt up: (688,45) → (684,42) px | port-omnibox |
| 11 | Onboarding | Closed, not reproduced on current code (2026-10-28): unselected choice rows draw `row` (black 0.015) with the 1 pt `rowBorder`, and only the selected or hovered row draws `button` (black 0.08), as the former RN choice row. The tokens are RN's in light and in dark (where `row` and `button` are both white 0.08, so every row reads the same, as in RN). Was: unselected rows filled like the selected one | In-process render of every step (`OnboardingSnapshotTests`, 2x), "Where do your tabs go?", light: selected 235, unselected 251, as RN; dark: both 40 | settings-ui |
| 12 | Onboarding | Closed, not reproduced on current code (2026-10-28): the mock window follows the picked appearance (`MockWindow.dark`), so with Dark picked it is dark in both system modes, with Light picked light in both, and with Automatic it follows the system. Was: the preview stayed light with Dark selected in dark mode | In-process renders of the step with each choice in light and dark mode | settings-ui |
| 13 | Command panel | Closed with the hosted panel (580bd916) and 66b5dc8a. Same height as RN now (2x snapshot over a grey page, dark: RN rows 1–214, native 2–215), top border row present in both; the whole panel sits 0.5 pt lower, which is the native toolbar text's Dia shift (`NATIVE_URL_TEXT_SHIFT`, see Intentional differences) carried into the panel so the URL stays put. 66b5dc8a fixed the "Open a tab or file" chip's border, which drew a stray vertical stroke off each end (SwiftUI's continuous capsule). Still to check on a real capture: RN's panel shows no shadow in the in-process snapshot while native's does (shadow radius 24, offset 10, as RN asks); Dia's is 0.08 r2 / 0.04 r1 | Was: bottom 217 vs 214 px (383 vs 378 with suggestions); bottom border 58 vs 81 | port-omnibox |
| 14 | Toolbar, dark page | Intentional (2d1118bb, Dia's host colours; see Intentional differences). Was: host darker than the icons | Host 161, icons 220 | port-omnibox |
| 15 | Onboarding | Closed: a measurement artifact. SwiftUI builds a hosting view's accessibility tree only once an assistive client asks, and the audit's dump ran before one had. With a client connected, the step text, choice rows and Back, Continue and Skip are there (51828953, which also hides the decorative mock window). `onboarding-test.mjs --native` reads the New Tab field in the tree during and after onboarding: 5/5 passed on 2026-10-28 | | settings-ui, main |
| 16 | Small layout | Settings part closed: the caption style, row heights and section gaps are superseded by row 4 (Settings is native-styled by the owner's decision and compared on content and behaviour only), and the wording now matches RN's word for word: both say "In the centre" (Appearance › ⌘L opens) and "Colour" (theme editor). Was: Profiles caption style, Shortcuts rows 41 vs 43 pt, section gaps +10 pt, "centre". Closed for port-omnibox: prompt button labels (82664188, 362–386 px as RN) and Site Controls top-row glyphs (0db91fc6, three of four tiles' ink equal to RN's, Cast 225.7 vs 227.2) | | settings-ui |

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
| 9 | 5abac41a, 249dd8c2 | Closed by 249dd8c2, which landed after this re-check: `SettingsFavicon` draws RN's bundled icons before the letter tile (see row 9). Still to check against RN's own window with the same crop, in the owner-away queue |
| 2 | 79a94f86 | Closed in light and dark (see row 2) |
| 6 | c8f13a73 | Closed in light and dark (see row 6) |
| 7 | 6dfce5c4 | Count and "No results" closed; replace-row buttons clipped and offset, labels 0.5 pt low (see row 7) |
| 5 | 25a3b373 (d637be2d documents it) | Matches Dia, including dark mode (Dia sets no dark-specific colour: popover material following the window, white 0.20 border). Dark over white 107/188, 2.81:1; the readability call is with the lead |

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

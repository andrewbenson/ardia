# Native surfaces against RN: parity audit, phases 0–4 (2026-10-26)

Every finished Swift surface turned on (`ARDIA_NATIVE_OMNIBOX=1 ARDIA_NATIVE_ONBOARDING=1`, the rest on by default)
against the RN versions (`ARDIA_NATIVE_OMNIBOX=0 ARDIA_NATIVE_ONBOARDING=0 ARDIA_NATIVE_NEWTAB=0
ARDIA_NATIVE_STATUS_BUBBLE=0 ARDIA_NATIVE_SETTINGS=0`), one Debug build (`build-parity-dbg`) run as two hidden
instances with the same seeded session and fixtures (a white page, a dark page with `theme-color #191A1E`, a dangerous
download, a MIDI prompt on example.com, a pinned unpacked extension with a badge and a popup). Captures are 2x
`screencapture -l`; the in-process `devSnapshotWindow` confirmed the ones that looked wrong. Pixel numbers are raw 2x
pixels, points are half of them.

## Gaps, most noticeable first

| # | Surface | Gap | Numbers | Owner |
|---|---|---|---|---|
| 1 | Settings | A reopened window (⌘W, open again) looks inactive and takes no keys | Typed "x", the search field kept "cookie"; `activation.log` makes it key over and over | settings-ui |
| 2 | Downloads popover | No panel: rows draw straight over the sidebar and page, no fill, border or shadow | Light and dark, screen and in-process captures | port-omnibox |
| 3 | Settings | No title and no back/forward in the titlebar | Content 20 pt higher (first heading y 62 vs 82) | settings-ui |
| 4 | Settings | Colours and chrome differ on every pane | Selected row grey (216) vs blue (108,165,250); sidebar 237/36 vs 219/64; pane 255 vs 240; group box 566 vs 550 pt, no border | settings-ui |
| 5 | Status bubble | Appears 0.5 s after hovering a link instead of at once, then stays 0.5 s and fades 0.1 s (RN: 90 ms fade in, 180 ms + 220 ms out); shows the scheme; dark mode reads grey | Dark: fill 107, text 188 (contrast about 2.8:1); RN fill 44, text 224. Light matches Dia (fill 226, text 113, border 203) | main (matches Dia's timing and light values) |
| 6 | Extension badge | "12" is drawn as "1" | Same box, 2496–2527 × 54–75 px | port-omnibox |
| 7 | Find bar | The total in "1 \| 3" is cut in half | Diff x 2260–2312, y 146–164 px | port-omnibox |
| 8 | Settings › Privacy | Rule counts are stale and read once | 176,026 / 43,797 vs the engine's 254,167 / 44,271 | settings-ui |
| 9 | Settings › Live Folders | Source logos are a generic globe | GitHub, Bitbucket, Notion, Confluence, Drive | settings-ui |
| 10 | Developer Mode | ⌘L edit moves the URL glyphs | 2 pt left, 1.5 pt up: (688,45) → (684,42) px; RN stays put | port-omnibox |
| 11 | Onboarding | Unselected option rows are filled like the selected one | 235 vs RN's 251 with a border | settings-ui |
| 12 | Onboarding | "Light or dark?" preview stays light with Dark selected in dark mode | | settings-ui |
| 13 | Command panel | 1.5 pt taller at the bottom, top 0.5 pt higher, no top border row | Bottom 217 vs 214 px (383 vs 378 with suggestions); bottom border 58 vs 81 | port-omnibox |
| 14 | Toolbar, dark page | Host darker than the icons | Host 161, icons 220; Dia's host matches its icons | port-omnibox |
| 15 | Onboarding | No onboarding controls in the accessibility tree; no New Tab field either | | settings-ui, main |
| 16 | Small layout | Settings extra "About" row, Profiles caption style, Shortcuts rows 41 vs 43 pt, section gaps +10 pt; "centre" → "center"; prompt button labels 0.5 pt lower; Site Controls top-row glyphs a hair lighter | | settings-ui, port-omnibox |

Matching Dia rather than RN, so not gaps: the URL host at SF 13 regular in (51,51,51) light, (149–161) dark; the
status bubble's timings and light colours; the Developer Mode stripes (RN drew none on the dark page in this run, bar
flat 42; native 42–46).

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

# Solara icon

Solara's app icon is "Outrun Classic": a striped synthwave sun half set over a magenta horizon above a neon grid, on a
deep violet sky, with the sun drawn 15% larger than the first cut (the owner's pick, 2026-10-24), still half set on
the same horizon. `classic.svg` is the 1024 px master, drawn as Apple's template (the squircle inset 100 px with a soft
shadow). `classic-128.svg`, `classic-64.svg`, `classic-32.svg` and `classic-16.svg` are hand-simplified for small sizes.

Each PNG is rendered with `rsvg-convert` (`brew install librsvg`) from the nearest source for its pixel size:

| Pixels | Source | Files |
|---|---|---|
| 16 | `classic-16.svg` | `icon_16x16_1x.png` |
| 32 | `classic-32.svg` | `icon_16x16_2x.png`, `icon_32x32_1x.png` |
| 64 | `classic-64.svg` | `icon_32x32_2x.png` |
| 128 | `classic-128.svg` | `icon_128x128_1x.png` |
| 256, 512, 1024 | `classic.svg` | the rest of `SolaraIcon.appiconset`, and `apps/browser/assets/app-icon-solara.png` at 512 |

```sh
set=apps/browser/macos/Solara-macOS/Assets.xcassets/SolaraIcon.appiconset
r() { rsvg-convert -w "$2" -h "$2" -o "$3" "docs/brand/solara/$1.svg"; }
r classic-16 16 $set/icon_16x16_1x.png
r classic-32 32 $set/icon_16x16_2x.png
r classic-32 32 $set/icon_32x32_1x.png
r classic-64 64 $set/icon_32x32_2x.png
r classic-128 128 $set/icon_128x128_1x.png
r classic 256 $set/icon_128x128_2x.png
r classic 256 $set/icon_256x256_1x.png
r classic 512 $set/icon_256x256_2x.png
r classic 512 $set/icon_512x512_1x.png
r classic 1024 $set/icon_512x512_2x.png
r classic 512 apps/browser/assets/app-icon-solara.png
```

The app picks the set with `AC_APP_ICON = SolaraIcon` (`docs/releasing.md` › The app's identity).

## Calm

"Calm" is the same artwork with the horizon taken away: no floor, grid, horizon band or horizon line, only the sun on
the sky. With nothing in front of it the sun is drawn whole: a striped circle at 78% of Classic's radius (255.7, the
owner's pick, 2026-10-27, so it reads the same size as Classic's half-set sun), centred on the squircle at y 512 with
157 px of sky on every side, its gradient spanning the full disc. The glow and Classic's stripe gaps scale with it; the
gaps sit in the lower half, with the bars between them thinning toward a small cap at the bottom. The sky, squircle, rim and shadow are
unchanged. `calm.svg` is the 1024 px master; `calm-128.svg`, `calm-64.svg`, `calm-32.svg` and `calm-16.svg` follow
the classic small masters (their gap heights and rim widths).

Settings › Appearance › App Icon offers it as "Calm" (id `calm`), beside "Classic" (`default`, the bundle icon).
`AppIcons` draws it at runtime from the `SolaraCalm` image set, so only the 1024 master ships, at two scales; the
small masters are kept for a bundle icon or a document icon later.

```sh
set=apps/browser/macos/Solara-macOS/Assets.xcassets/SolaraCalm.imageset
rsvg-convert -w 512 -h 512 -o $set/calm_512.png docs/brand/solara/calm.svg
rsvg-convert -w 1024 -h 1024 -o $set/calm_1024.png docs/brand/solara/calm.svg
```

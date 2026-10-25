# Vista icon

Vista's app icon is "Outrun Classic": a striped synthwave sun half set over a magenta horizon above a neon grid, on a
deep violet sky. `classic.svg` is the 1024 px master, drawn as Apple's template (the squircle inset 100 px with a soft
shadow). `classic-128.svg`, `classic-64.svg`, `classic-32.svg` and `classic-16.svg` are hand-simplified for small sizes.

Each PNG is rendered with `rsvg-convert` (`brew install librsvg`) from the nearest source for its pixel size:

| Pixels | Source | Files |
|---|---|---|
| 16 | `classic-16.svg` | `icon_16x16_1x.png` |
| 32 | `classic-32.svg` | `icon_16x16_2x.png`, `icon_32x32_1x.png` |
| 64 | `classic-64.svg` | `icon_32x32_2x.png` |
| 128 | `classic-128.svg` | `icon_128x128_1x.png` |
| 256, 512, 1024 | `classic.svg` | the rest of `VistaIcon.appiconset`, and `apps/browser/assets/app-icon-vista.png` at 512 |

```sh
set=apps/browser/macos/Ardia-macOS/Assets.xcassets/VistaIcon.appiconset
r() { rsvg-convert -w "$2" -h "$2" -o "$3" "docs/brand/vista/$1.svg"; }
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
r classic 512 apps/browser/assets/app-icon-vista.png
```

The fork picks the set with `AC_APP_ICON = VistaIcon` (`docs/releasing.md` › Shipping your own fork).

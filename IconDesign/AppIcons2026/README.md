# Primuse app icon sources

The public catalog contains one primary icon and six alternates, in this order:

| Source | Asset | Name |
| --- | --- | --- |
| `00-primuse.png` | `AppIcon` | Primuse |
| `20-soft-note.png` | `AppIcon20` | 清新音符 |
| `19-chris-muse.png` | `AppIcon19` | Chris’s Muse |
| `22-kai.png` | `AppIcon22` | Kai |
| `23-ribbon-note.png` | `AppIcon23` | 绸带音符 |
| `15-folded-note.png` | `AppIcon15` | 折页音符 |
| `12-pikaqiu.png` | `AppIcon12` | 皮卡丘 |

咸鱼吃Sushi (`AppIconGroove`) remains a separate hidden alternate in `Primuse/Resources/Assets.xcassets`.
Its only source is that full-colour icon; `save_groove_icon()` in
`scripts/generate_ios_layered_icons.py` lifts the drawing off the cyan plate to
build its dark (deep teal plate) and mono artwork.
Retired icon numbers are not reused.

This directory is a design and generation input, not an app resource directory.
Production assets live in `Primuse/Resources/Assets.xcassets` and
`Primuse/Resources-iOS/AppIcons`; Xcode compiles those assets into the app.
The contact sheet and appearance comparison show the public designs.

`raw/` retains the artwork used by the generators and Chris’s Muse’s original
JPEGs. Ribbon Note's tinted source is a grayscale glyph with alpha. Icon Composer
uses it directly for the glass material, and the flat tinted icon uses a black plate.

Run `python3 scripts/generate_app_icon_assets.py` to regenerate the iconsets,
previews, contact sheets, iOS layered icons, and platform assets. The generators
require Pillow and NumPy. `scripts/generate_brand_marks.py` generates the
transparent marks used in navigation.

Each iOS layered icon has one image layer. The image and material switch with
the appearance: full-color Light/Dark artwork has no glass or specular effect,
while Mono provides the glass glyph for tinted and clear appearances.
`python3 IconDesign/test_layered_icons.py -v` checks the native renderings and
compiled resource layers with Xcode’s Icon Composer and asset tools.

The Mac app uses the same `AppIconPrimary.icon` as its bundle icon, so macOS 26
and later switch it with the system icon style; for macOS 15, actool renders a
flat fallback from it. Run `python3 scripts/generate_mac_icon_styles.py` to render
the alternate Dock icons with Icon Composer and generate their tint maps. To add
or refresh one design using the shipped tint table, pass `--icon AppIcon23`.

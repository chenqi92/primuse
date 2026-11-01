# Primuse app icon sources

The public catalog contains one primary icon and five alternates, in this order:

| Source | Asset | Name |
| --- | --- | --- |
| `00-primuse.png` | `AppIcon` | Primuse |
| `20-soft-note.png` | `AppIcon20` | 清新音符 |
| `19-chris-muse.png` | `AppIcon19` | Chris’s Muse |
| `16-nonoend.png` | `AppIcon16` | NonoEnd |
| `15-folded-note.png` | `AppIcon15` | 折页音符 |
| `12-pikaqiu.png` | `AppIcon12` | 皮卡丘 |

咸鱼吃Sushi (`AppIconGroove`) remains a separate hidden alternate in `Primuse/Resources/Assets.xcassets`.
Retired icon numbers are not reused.

This directory is a design and generation input, not an app resource directory.
Production assets live in `Primuse/Resources/Assets.xcassets` and
`Primuse/Resources-iOS/AppIcons`; Xcode compiles those assets into the app.
The contact sheet and appearance comparison show only the six public designs.

`raw/` retains the artwork used by the generators and Chris’s Muse’s original
JPEGs. The soft-note generator uses its raw dark glyph to produce the current
green artwork; its default and dark appearances are identical.

Run `python3 scripts/generate_app_icon_assets.py` to regenerate the iconsets,
previews, contact sheets, iOS layered icons, and platform assets. The generators
require Pillow and NumPy. `scripts/generate_brand_marks.py` generates the
transparent marks used in navigation.

Each iOS layered icon has one image layer. The image and material switch with
the appearance: full-color Light/Dark artwork has no glass or specular effect,
while Mono provides the glass glyph for tinted and clear appearances.
`python3 IconDesign/test_layered_icons.py -v` checks the native renderings and
compiled resource layers with Xcode’s Icon Composer and asset tools.

# Primuse app icon system

The production catalog contains one primary icon and four alternates:

- `00-folded-note.png` — primary folded-note icon.
- `12-pikaqiu.png` — user-submitted gradient music-note icon on an adaptive light, dark, or tinted background.
- `09-classic-record.png` — historical record-and-note artwork restored as the classic icon.
- `11-color-brush.png` — a multicolor lacquer brush that fuses the Primuse P, Jingu Bang, and music note.
- `06-soft-note.png` — restored original soft-gradient music note.

Private Library, Lossless Audio, Record Collection, Speaker Play, and Muse Spark are intentionally no longer part of the catalog.

## Appearance system

The folded note, Pikaqiu, classic record, and soft note preserve their Light, Dark, and Tinted PNGs without palette normalization. Color Brush derives pure-white Light plus grayscale Tinted artwork from its selected pure-black source.

All iOS masters are 1024×1024 full-bleed RGB PNGs with no baked platform corner mask. macOS sizes are derived from the primary Light icon with the platform-specific inset and rounded mask. watchOS uses the primary Light artwork so the white-background default remains consistent across all three platforms.

## tvOS

tvOS uses the folded-note design in independently composed landscape/parallax assets. The square-icon generator leaves these layers unchanged.

The asset structure remains:

- transparent `Front` plus opaque `Back` at 400×240 and 800×480;
- App Store `Front` plus `Back` at 1280×768;
- Top Shelf at 1920×720 and 3840×1440;
- Top Shelf Wide at 2320×720 and 4640×1440.

## Regeneration

Run `python3 scripts/generate_app_icon_assets.py` from the repository root. The script regenerates the retained iOS iconsets and previews, the macOS and watchOS primary icons, the contact sheet, and the Light/Dark comparison sheet.

The source inputs live in `raw/`. `00-folded-note*.png`, `06-soft-note*.png`, and `09-classic-record*.png` preserve their exact artwork. `11-color-brush*.png` is a deterministic output refreshed by the generator.

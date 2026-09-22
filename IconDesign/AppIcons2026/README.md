# Primuse app icon system

The production catalog contains one primary icon and six alternates:

- `00-splash.png` — primary icon: a milky-white dimensional splash with an engraved ring and a note in its opening, on solid berry pink.
- `16-nonoend.png` — NonoEnd: a pink-violet beamed eighth-note pair, lit from the top edge, on a deep indigo-to-plum gradient plate.
- `14-letter-p.png` — the letter P in the same material in pure white on solid cobalt blue. Its bowl is an open counter; the note sits at the lower right on the P's own baseline, where its stem and flag double as a lowercase r — together they read Pr.
- `15-folded-note.png` — the previous primary folded-note icon, retained as an alternate.
- `12-pikaqiu.png` — user-submitted gradient music-note icon on an adaptive light, dark, or tinted background.
- `06-soft-note.png` — restored original soft-gradient music note.
- `13-chris-muse.png` — Chris’s Muse, designed by Chris, with a white dimensional note on red in Light and a pink-red note on charcoal in Dark.

Private Library, Lossless Audio, Record Collection, Speaker Play, Muse Spark, Color Brush, and Classic Record are intentionally no longer part of the catalog.

## Appearance system

The folded note, Pikaqiu, and soft note preserve their Light, Dark, and Tinted PNGs without palette normalization.

Splash and Letter P share one material: a white glyph with its own shading and a soft cast shadow over a single solid colour. Their Dark variants keep the identical composition with a colour-tinted glyph on charcoal, and their Tinted variants use a silver glyph on near-black.

NonoEnd ships a single supplied Light plate. Its backdrop never rises above ~55 luminance and its note never falls below ~85, so one soft luminance threshold separates them: the Dark variant sinks the backdrop a stop while the note keeps its own brightness, and the Tinted variant is a neutral grayscale rendering with a near-black field and the note lifted into the light band.

Chris’s Muse preserves the artwork from `13-chris-muse-light-original.jpg` and `13-chris-muse-dark-original.jpg`. The supplied rounded outer rim is removed so platform masking does not create a second edge; the note's dimensional highlights are retained. Its Tinted variant uses a silver-white note on charcoal. The selected original JPEGs are retained alongside the prepared PNGs in `raw/`.

All iOS masters are 1024×1024 full-bleed RGB PNGs with no baked platform corner mask. macOS sizes are derived from the primary Light icon with the platform-specific inset and rounded mask. watchOS uses the primary Light artwork so the default remains consistent across all three platforms.

## tvOS

tvOS uses the primary Splash design in independently composed landscape/parallax assets: the glyph and its cast shadow form the transparent `Front` layer, the solid berry-pink field is the `Back` layer. The square-icon generator leaves these layers unchanged.

The asset structure remains:

- transparent `Front` plus opaque `Back` at 400×240 and 800×480;
- App Store `Front` plus `Back` at 1280×768;
- Top Shelf at 1920×720 and 3840×1440;
- Top Shelf Wide at 2320×720 and 4640×1440.

## Regeneration

Run `python3 scripts/generate_app_icon_assets.py` from the repository root. The script regenerates the retained iOS iconsets and previews, the macOS and watchOS primary icons, the contact sheet, and the Light/Dark comparison sheet.

The source inputs live in `raw/`. `15-folded-note*.png` and `06-soft-note*.png` preserve their exact artwork. In-app preview imagesets are written at 512×512.

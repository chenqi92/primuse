# Primuse app icon system

The production catalog contains one primary icon and six alternates:

- `00-soft-note.png` — primary icon: a cream dimensional eighth note with a soft cast shadow, on a mint-to-aqua gradient. It was the primary icon before Chris’s Muse, spent a day as alternate 18, and is primary again; number 18 is retired.
- `19-chris-muse.png` — the previous primary icon, retained as an alternate: Chris’s Muse, designed by Chris, with a white dimensional note on red in Light and a pink-red note on charcoal in Dark.
- `16-nonoend.png` — NonoEnd: a pink-violet bass clef. Light sets it on a neutral grey gradient with a top-left rim light and a cast shadow; Dark sets the same clef on a deep indigo-to-plum plate.
- `17-splash.png` — an earlier primary icon, retained as an alternate: a milky-white dimensional splash with an engraved ring and a note in its opening, on solid berry pink.
- `14-letter-p.png` — the letter P in the same material in pure white on solid cobalt blue. Its bowl is an open counter; the note sits at the lower right on the P's own baseline, where its stem and flag double as a lowercase r — together they read Pr.
- `15-folded-note.png` — an earlier primary folded-note icon, retained as an alternate.
- `12-pikaqiu.png` — user-submitted gradient music-note icon on an adaptive light, dark, or tinted background.

Private Library, Lossless Audio, Record Collection, Speaker Play, Muse Spark, Color Brush, and Classic Record are intentionally no longer part of the catalog.

## Appearance system

The soft note, folded note, and Pikaqiu preserve their Light, Dark, and Tinted PNGs without palette normalization. The soft note's Tinted plate is the one exception to the catalog's usual polarity: it carries a dark glyph on a light field rather than a light glyph on a near-black one.

The splash and Letter P share one material: a white glyph with its own shading and a soft cast shadow over a single solid colour. Their Dark variants keep the identical composition with a colour-tinted glyph on charcoal, and their Tinted variants use a silver glyph on near-black.

NonoEnd started from two supplied plates carrying a beamed eighth-note pair. That composition — a rounded square with a centred beamed pair — reads as Apple Music's, so the glyph was replaced with a bass clef while the plates and the material were kept. The clef is drawn as a signed-distance stroke field (a sampled centre line plus a half-width that tapers along it), then dressed in the material measured off the original artwork: a linear vertical fill from (248,135,231) at the top to (161,87,204) at the bottom, and, on the Light plate only, a white rim up-left with a cast shadow down-right, matching a top-left key light. Both backdrops are polynomial fits of the supplied plates taken well clear of the old glyph and its shadow (residual rms 0.46 Light, 0.83 Dark), so the grounds are the delivered ones. The Tinted variant is derived from the rebuilt Dark plate: its backdrop never rises above ~55 luminance and its glyph never falls below ~85, so one soft luminance threshold separates them — the field drops to near-black and the glyph is lifted into the light band.

Chris’s Muse preserves the artwork from `19-chris-muse-light-original.jpg` and `19-chris-muse-dark-original.jpg`. It was alternate 13, then briefly the primary icon, and is now alternate 19; number 13 is retired. The supplied rounded outer rim is removed so platform masking does not create a second edge; the note's dimensional highlights are retained. Its Tinted variant uses a silver-white note on charcoal. The selected original JPEGs are retained alongside the prepared PNGs in `raw/`.

All iOS masters are 1024×1024 full-bleed RGB PNGs with no baked platform corner mask. macOS sizes are derived from the primary Light icon with the platform-specific inset and rounded mask. watchOS uses the primary Light artwork so the default remains consistent across all three platforms.

## tvOS

tvOS uses the primary soft-note design in independently composed landscape/parallax assets: the glyph and its cast shadow form the transparent `Front` layer, the mint-to-aqua field is the `Back` layer. Compositing `Front` over `Back` reproduces the square plate, so the shadow is encoded as black-with-alpha rather than baked into the ground. The two are separated by channel difference — the cream glyph has R ≈ G while the mint field keeps G ≫ R — and the ground is a polynomial fit sampled clear of the glyph and its shadow. `BrandMark` is the square plate at 256×256. The square-icon generator does not produce any of these; `Front` sits at 63% of canvas height, the Top Shelf mark at 50%.

The asset structure remains:

- transparent `Front` plus opaque `Back` at 400×240 and 800×480;
- App Store `Front` plus `Back` at 1280×768;
- Top Shelf at 1920×720 and 3840×1440;
- Top Shelf Wide at 2320×720 and 4640×1440.

## Regeneration

Run `python3 scripts/generate_app_icon_assets.py` from the repository root. The script regenerates the retained iOS iconsets and previews, the macOS and watchOS primary icons, the contact sheet, and the Light/Dark comparison sheet.

The source inputs live in `raw/`. `00-soft-note*.png` and `15-folded-note*.png` preserve their exact artwork. A `NN-` prefix is the icon's alternate number; `00-` marks whichever design is currently primary. Retired numbers are never reused. In-app preview imagesets are written at 512×512.

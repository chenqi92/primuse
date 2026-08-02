#!/usr/bin/env python3
"""Generate the retained iOS, macOS, and watchOS app-icon assets."""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageOps


ROOT = Path(__file__).resolve().parents[1]
DESIGN_DIR = ROOT / "IconDesign" / "AppIcons2026"
RAW_DIR = DESIGN_DIR / "raw"
IOS_ASSETS = ROOT / "Primuse" / "Resources" / "Assets.xcassets"
MAC_ICONSET = IOS_ASSETS / "AppIcon-Mac.appiconset"
WATCH_ICONSET = ROOT / "PrimuseWatch" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"
TINTED_PALETTE = [
    (0x18, 0x18, 0x18),
    (0xF2, 0xF2, 0xF2),
    (0xB8, 0xB8, 0xB8),
    (0xD4, 0xD4, 0xD4),
    (0xE2, 0xE2, 0xE2),
    (0xFA, 0xFA, 0xFA),
]

VINYL_APE_SOURCE_PALETTE = [
    (0xFF, 0xFF, 0xFF),  # pure-white background and negative space
    (0x11, 0x11, 0x11),  # ape / vinyl silhouette
    (0xD3, 0x3A, 0x2C),  # record label
]
VINYL_APE_LIGHT_PALETTE = VINYL_APE_SOURCE_PALETTE
VINYL_APE_DARK_PALETTE = [
    (0x00, 0x00, 0x00),  # pure-black background and negative space
    (0xF5, 0xF5, 0xF5),  # inverted ape / vinyl silhouette
    (0xEF, 0x4B, 0x3C),  # brighter record label
]
VINYL_APE_TINTED_PALETTE = [
    (0x00, 0x00, 0x00),
    (0xF2, 0xF2, 0xF2),
    (0x8E, 0x8E, 0x8E),
]

SECONDARY_SOURCE_PALETTE = [
    (0x18, 0x14, 0x2F),  # midnight violet
    (0x8B, 0x6C, 0xFF),  # electric violet
    (0x63, 0xE6, 0xD6),  # mint cyan
    (0xFF, 0x5F, 0x8F),  # vivid pink
    (0xC9, 0xF0, 0x5A),  # acid lime
    (0xF7, 0xF5, 0xFF),  # soft white
]
SECONDARY_LIGHT_PALETTE = [
    (0xF3, 0xF0, 0xFF),  # pale lavender background
    (0x68, 0x47, 0xE6),  # violet
    (0x00, 0x8F, 0x87),  # cyan
    (0xE4, 0x3D, 0x73),  # pink
    (0x86, 0xA9, 0x16),  # lime
    (0x18, 0x14, 0x2F),  # midnight symbol
]
SECONDARY_DARK_PALETTE = [
    (0x0C, 0x09, 0x20),
    (0x9D, 0x83, 0xFF),
    (0x78, 0xF2, 0xE4),
    (0xFF, 0x75, 0x9F),
    (0xD8, 0xF7, 0x72),
    (0xFB, 0xFA, 0xFF),
]

PALETTE_FAMILIES = {
    "secondary": (
        SECONDARY_SOURCE_PALETTE,
        SECONDARY_LIGHT_PALETTE,
        SECONDARY_DARK_PALETTE,
        TINTED_PALETTE,
    ),
    "vinyl_ape": (
        VINYL_APE_SOURCE_PALETTE,
        VINYL_APE_LIGHT_PALETTE,
        VINYL_APE_DARK_PALETTE,
        VINYL_APE_TINTED_PALETTE,
    ),
}

ICONS = [
    ("10-vinyl-ape.png", "10-vinyl-ape", "AppIcon10", "AppIcon10Preview", "vinyl_ape"),
    ("04-music-note-waveform.png", "04-music-note-waveform", "AppIcon4", "AppIcon4Preview", "secondary"),
]

EXACT_ICONS = [
    (
        "00-folded-note",
        "AppIcon",
        "AppIconPreview",
        "00-folded-note.png",
        "00-folded-note-dark.png",
        "00-folded-note-tinted.png",
    ),
    (
        "06-soft-note",
        "AppIcon6",
        "AppIcon6Preview",
        "06-soft-note.png",
        "06-soft-note-dark.png",
        "06-soft-note-tinted.png",
    ),
    (
        "09-classic-record",
        "AppIcon9",
        "AppIcon9Preview",
        "09-classic-record.png",
        "09-classic-record-dark.png",
        "09-classic-record-tinted.png",
    ),
]

SIMPLE_ICONS = [
    ("07-primuse-mark", "AppIcon7", "AppIcon7Preview", "primuse"),
]

BRUSH_ICONS = [
    ("11-color-brush-source.png", "11-color-brush", "AppIcon11", "AppIcon11Preview"),
]

CATALOG_ORDER = ["AppIcon", "AppIcon9", "AppIcon10", "AppIcon11", "AppIcon4", "AppIcon6", "AppIcon7"]


def palette_bytes(colors: list[tuple[int, int, int]]) -> list[int]:
    entries = colors + [colors[0]] * (256 - len(colors))
    return [channel for color in entries for channel in color]


def snap_to_palette(source: Path, colors: list[tuple[int, int, int]]) -> Image.Image:
    """Remove generated gradients/shadows while preserving the exact silhouette."""
    image = Image.open(source).convert("RGB")
    palette = Image.new("P", (1, 1))
    palette.putpalette(palette_bytes(colors))
    return image.quantize(palette=palette, dither=Image.Dither.NONE)


def render_variant(indexed: Image.Image, colors: list[tuple[int, int, int]], size: tuple[int, int]) -> Image.Image:
    variant = indexed.copy()
    variant.putpalette(palette_bytes(colors))
    return variant.convert("RGB").resize(size, Image.Resampling.LANCZOS)


def save_ios_assets(
    indexed: Image.Image,
    master_stem: str,
    icon_name: str,
    preview_name: str,
    light_colors: list[tuple[int, int, int]],
    dark_colors: list[tuple[int, int, int]],
    tinted_colors: list[tuple[int, int, int]],
) -> tuple[Image.Image, Image.Image]:
    any_icon = render_variant(indexed, light_colors, (1024, 1024))
    dark_icon = render_variant(indexed, dark_colors, (1024, 1024))
    tinted_icon = render_variant(indexed, tinted_colors, (1024, 1024))

    return save_direct_ios_assets(
        any_icon,
        dark_icon,
        tinted_icon,
        master_stem,
        icon_name,
        preview_name,
    )


def save_direct_ios_assets(
    any_icon: Image.Image,
    dark_icon: Image.Image,
    tinted_icon: Image.Image,
    master_stem: str,
    icon_name: str,
    preview_name: str,
) -> tuple[Image.Image, Image.Image]:
    any_icon = any_icon.convert("RGB").resize((1024, 1024), Image.Resampling.LANCZOS)
    dark_icon = dark_icon.convert("RGB").resize((1024, 1024), Image.Resampling.LANCZOS)
    tinted_icon = tinted_icon.convert("RGB").resize((1024, 1024), Image.Resampling.LANCZOS)

    master_path = DESIGN_DIR / f"{master_stem}.png"
    any_icon.save(master_path, optimize=True)

    iconset = IOS_ASSETS / f"{icon_name}.appiconset"
    any_icon.save(iconset / f"{icon_name}.png", optimize=True)
    dark_icon.save(iconset / f"{icon_name}-dark.png", optimize=True)
    tinted_icon.save(iconset / f"{icon_name}-tinted.png", optimize=True)

    preview = IOS_ASSETS / f"{preview_name}.imageset"
    any_icon.save(preview / f"{preview_name}.png", optimize=True)
    dark_icon.save(preview / f"{preview_name}-dark.png", optimize=True)
    return any_icon, dark_icon


def diagonal_gradient(start: tuple[int, int, int], end: tuple[int, int, int]) -> Image.Image:
    size = (1024, 1024)
    vertical = Image.linear_gradient("L").resize(size)
    horizontal = vertical.rotate(90)
    mask = Image.blend(vertical, horizontal, 0.5)
    return Image.composite(Image.new("RGB", size, end), Image.new("RGB", size, start), mask)


def apply_soft_symbol(
    background: Image.Image,
    mask: Image.Image,
    symbol_color: tuple[int, int, int],
) -> Image.Image:
    canvas = background.convert("RGBA")
    blurred = mask.filter(ImageFilter.GaussianBlur(24))
    shifted = blurred.transform(mask.size, Image.Transform.AFFINE, (1, 0, 0, 0, 1, -18))
    shadow_alpha = shifted.point(lambda value: round(value * 0.28))
    shadow = Image.new("RGBA", mask.size, (0x08, 0x2A, 0x32, 0))
    shadow.putalpha(shadow_alpha)
    canvas.alpha_composite(shadow)

    symbol = Image.new("RGBA", mask.size, (*symbol_color, 0))
    symbol.putalpha(mask)
    canvas.alpha_composite(symbol)
    return canvas.convert("RGB")


def make_simple_icon(kind: str, appearance: str) -> Image.Image:
    palettes = {
        "primuse": {
            "light": ((0xE9, 0xFF, 0xF9), (0x38, 0xD5, 0xC8), (0xFF, 0xFD, 0xF6)),
            "dark": ((0x06, 0x2C, 0x35), (0x0F, 0x7F, 0x89), (0xFF, 0xF9, 0xED)),
            "tinted": ((0xF2, 0xF2, 0xF2), (0x6F, 0x6F, 0x6F), (0xFA, 0xFA, 0xFA)),
        },
    }
    start, end, symbol_color = palettes[kind][appearance]
    background = diagonal_gradient(start, end)
    mask = Image.new("L", (1024, 1024), 0)
    draw = ImageDraw.Draw(mask)

    if kind != "primuse":
        raise ValueError(f"Unknown simple icon kind: {kind}")

    # A deliberately simple P monogram. The triangular counter makes the
    # letter simultaneously read as Primuse and playback.
    draw.rounded_rectangle((260, 184, 438, 850), radius=89, fill=255)
    draw.ellipse((340, 184, 824, 662), fill=255)
    draw.polygon(((488, 320), (488, 526), (672, 423)), fill=0)

    return apply_soft_symbol(background, mask, symbol_color)


def make_brush_variants(source: Path) -> dict[str, Image.Image]:
    """Preserve the selected brush artwork on pure Light/Dark backgrounds."""
    source_image = Image.open(source).convert("RGB").resize((1024, 1024), Image.Resampling.LANCZOS)

    # The selected artwork was rendered on pure black. Flood-fill only the
    # connected black backdrop so the dark brush texture inside the mark is
    # retained when compositing the Light appearance.
    marker = (0, 255, 0)
    flood = source_image.copy()
    ImageDraw.floodfill(flood, (0, 0), marker, thresh=24)
    ImageDraw.floodfill(flood, (600, 410), marker, thresh=24)
    alpha = Image.new("L", source_image.size, 255)
    alpha.putdata([0 if pixel == marker else 255 for pixel in flood.get_flattened_data()])
    alpha = alpha.filter(ImageFilter.GaussianBlur(0.6))

    foreground = source_image.convert("RGBA")
    foreground.putalpha(alpha)
    light = Image.new("RGBA", source_image.size, (255, 255, 255, 255))
    light.alpha_composite(foreground)
    dark = Image.new("RGBA", source_image.size, (0, 0, 0, 255))
    dark.alpha_composite(foreground)

    dark_rgb = dark.convert("RGB")
    tinted = ImageOps.grayscale(dark_rgb)
    tinted = ImageEnhance.Contrast(tinted).enhance(1.12).convert("RGB")

    return {
        "light": light.convert("RGB"),
        "dark": dark_rgb,
        "tinted": tinted,
    }


def rounded_mac_master(source: Image.Image) -> Image.Image:
    canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    body_size = 824
    body = source.resize((body_size, body_size), Image.Resampling.LANCZOS).convert("RGBA")
    mask = Image.new("L", (body_size, body_size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, body_size - 1, body_size - 1),
        radius=185,
        fill=255,
    )
    body.putalpha(mask)
    canvas.alpha_composite(body, ((1024 - body_size) // 2, (1024 - body_size) // 2))
    return canvas


def save_mac_and_watch(mac_icon: Image.Image, watch_icon: Image.Image) -> None:
    mac_master = rounded_mac_master(mac_icon)
    mac_sizes = {
        "icon_16x16.png": 16,
        "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
        "icon_512x512@2x.png": 1024,
    }
    for filename, side in mac_sizes.items():
        mac_master.resize((side, side), Image.Resampling.LANCZOS).save(MAC_ICONSET / filename, optimize=True)
    watch_icon.save(WATCH_ICONSET / "AppIcon.png", optimize=True)


def save_contact_sheet(icons: list[Image.Image]) -> None:
    thumb = 360
    gap = 48
    columns = 3
    rows = (len(icons) + columns - 1) // columns
    sheet = Image.new(
        "RGB",
        (gap * (columns + 1) + thumb * columns, gap * (rows + 1) + thumb * rows),
        (0xE9, 0xE7, 0xE1),
    )
    for index, icon in enumerate(icons):
        row, column = divmod(index, columns)
        position = (gap + column * (thumb + gap), gap + row * (thumb + gap))
        sheet.paste(icon.resize((thumb, thumb), Image.Resampling.LANCZOS), position)
    sheet.save(DESIGN_DIR / "contact-sheet.png", optimize=True)


def save_appearance_sheet(light_icons: list[Image.Image], dark_icons: list[Image.Image]) -> None:
    """Place each Light/Dark pair side by side for visual QA."""
    thumb = 232
    pair_gap = 16
    gap = 44
    columns = 3
    rows = (len(light_icons) + columns - 1) // columns
    cell_width = thumb * 2 + pair_gap
    sheet = Image.new(
        "RGB",
        (gap * (columns + 1) + cell_width * columns, gap * (rows + 1) + thumb * rows),
        (0xD8, 0xD8, 0xDA),
    )
    for index, (light_icon, dark_icon) in enumerate(zip(light_icons, dark_icons, strict=True)):
        row, column = divmod(index, columns)
        x = gap + column * (cell_width + gap)
        y = gap + row * (thumb + gap)
        sheet.paste(light_icon.resize((thumb, thumb), Image.Resampling.LANCZOS), (x, y))
        sheet.paste(dark_icon.resize((thumb, thumb), Image.Resampling.LANCZOS), (x + thumb + pair_gap, y))
    sheet.save(DESIGN_DIR / "appearance-comparison.png", optimize=True)


def main() -> None:
    rendered_icons: dict[str, tuple[Image.Image, Image.Image]] = {}
    for raw_filename, master_stem, icon_name, preview_name, family in ICONS:
        source_colors, light_colors, dark_colors, tinted_colors = PALETTE_FAMILIES[family]
        indexed = snap_to_palette(RAW_DIR / raw_filename, source_colors)
        light_icon, dark_icon = save_ios_assets(
            indexed,
            master_stem,
            icon_name,
            preview_name,
            light_colors,
            dark_colors,
            tinted_colors,
        )
        rendered_icons[icon_name] = (light_icon, dark_icon)

    for master_stem, icon_name, preview_name, light_name, dark_name, tinted_name in EXACT_ICONS:
        light_icon, dark_icon = save_direct_ios_assets(
            Image.open(RAW_DIR / light_name),
            Image.open(RAW_DIR / dark_name),
            Image.open(RAW_DIR / tinted_name),
            master_stem,
            icon_name,
            preview_name,
        )
        rendered_icons[icon_name] = (light_icon, dark_icon)

    for master_stem, icon_name, preview_name, kind in SIMPLE_ICONS:
        variants = {
            appearance: make_simple_icon(kind, appearance)
            for appearance in ("light", "dark", "tinted")
        }
        variants["light"].save(RAW_DIR / f"{master_stem}.png", optimize=True)
        variants["dark"].save(RAW_DIR / f"{master_stem}-dark.png", optimize=True)
        variants["tinted"].save(RAW_DIR / f"{master_stem}-tinted.png", optimize=True)
        light_icon, dark_icon = save_direct_ios_assets(
            variants["light"],
            variants["dark"],
            variants["tinted"],
            master_stem,
            icon_name,
            preview_name,
        )
        rendered_icons[icon_name] = (light_icon, dark_icon)

    for raw_filename, master_stem, icon_name, preview_name in BRUSH_ICONS:
        variants = make_brush_variants(RAW_DIR / raw_filename)
        variants["light"].save(RAW_DIR / f"{master_stem}.png", optimize=True)
        variants["dark"].save(RAW_DIR / f"{master_stem}-dark.png", optimize=True)
        variants["tinted"].save(RAW_DIR / f"{master_stem}-tinted.png", optimize=True)
        light_icon, dark_icon = save_direct_ios_assets(
            variants["light"],
            variants["dark"],
            variants["tinted"],
            master_stem,
            icon_name,
            preview_name,
        )
        rendered_icons[icon_name] = (light_icon, dark_icon)

    assert set(rendered_icons) == set(CATALOG_ORDER)
    light_icons = [rendered_icons[name][0] for name in CATALOG_ORDER]
    dark_icons = [rendered_icons[name][1] for name in CATALOG_ORDER]
    save_mac_and_watch(rendered_icons["AppIcon"][0], rendered_icons["AppIcon"][1])
    # tvOS keeps its explicit folded-note parallax and Top Shelf compositions;
    # this square-icon generator must not flatten or replace those layers.
    save_contact_sheet(light_icons)
    save_appearance_sheet(light_icons, dark_icons)


if __name__ == "__main__":
    main()

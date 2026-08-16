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
        "12-pikaqiu",
        "AppIcon12",
        "AppIcon12Preview",
        "12-pikaqiu.png",
        "12-pikaqiu-dark.png",
        "12-pikaqiu-tinted.png",
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

BRUSH_ICONS = [
    ("11-color-brush-source.png", "11-color-brush", "AppIcon11", "AppIcon11Preview"),
]

CATALOG_ORDER = ["AppIcon", "AppIcon12", "AppIcon9", "AppIcon11", "AppIcon6"]


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
    save_mac_and_watch(rendered_icons["AppIcon"][0], rendered_icons["AppIcon"][0])
    # tvOS keeps its explicit folded-note parallax and Top Shelf compositions;
    # this square-icon generator must not flatten or replace those layers.
    save_contact_sheet(light_icons)
    save_appearance_sheet(light_icons, dark_icons)


if __name__ == "__main__":
    main()

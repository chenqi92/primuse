#!/usr/bin/env python3
"""Generate the retained iOS, macOS, and watchOS app-icon assets."""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
DESIGN_DIR = ROOT / "IconDesign" / "AppIcons2026"
RAW_DIR = DESIGN_DIR / "raw"
IOS_ASSETS = ROOT / "Primuse" / "Resources" / "Assets.xcassets"
MAC_ICONSET = IOS_ASSETS / "AppIcon-Mac.appiconset"
WATCH_ICONSET = ROOT / "PrimuseWatch" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"

EXACT_ICONS = [
    (
        "13-chris-muse",
        "AppIcon13",
        "AppIcon13Preview",
        "13-chris-muse.png",
        "13-chris-muse-dark.png",
        "13-chris-muse-tinted.png",
    ),
    (
        "00-splash",
        "AppIcon",
        "AppIconPreview",
        "00-splash.png",
        "00-splash-dark.png",
        "00-splash-tinted.png",
    ),
    (
        "14-letter-p",
        "AppIcon14",
        "AppIcon14Preview",
        "14-letter-p.png",
        "14-letter-p-dark.png",
        "14-letter-p-tinted.png",
    ),
    (
        "15-folded-note",
        "AppIcon15",
        "AppIcon15Preview",
        "15-folded-note.png",
        "15-folded-note-dark.png",
        "15-folded-note-tinted.png",
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

CATALOG_ORDER = ["AppIcon", "AppIcon14", "AppIcon15", "AppIcon9", "AppIcon12", "AppIcon6", "AppIcon13"]

# In-app previews render at 60–100 pt (and 512 pt@2x for the macOS Dock icon).
PREVIEW_SIDE = 512


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
    preview_size = (PREVIEW_SIDE, PREVIEW_SIDE)
    any_icon.resize(preview_size, Image.Resampling.LANCZOS).save(preview / f"{preview_name}.png", optimize=True)
    dark_icon.resize(preview_size, Image.Resampling.LANCZOS).save(preview / f"{preview_name}-dark.png", optimize=True)
    return any_icon, dark_icon


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

    assert set(rendered_icons) == set(CATALOG_ORDER)
    light_icons = [rendered_icons[name][0] for name in CATALOG_ORDER]
    dark_icons = [rendered_icons[name][1] for name in CATALOG_ORDER]
    save_mac_and_watch(rendered_icons["AppIcon"][0], rendered_icons["AppIcon"][0])
    # tvOS keeps its explicit parallax and Top Shelf compositions; this
    # square-icon generator must not flatten or replace those layers.
    save_contact_sheet(light_icons)
    save_appearance_sheet(light_icons, dark_icons)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Generate the retained app-icon assets for all Apple platforms."""

from __future__ import annotations

from pathlib import Path

from PIL import Image
from generate_flat_brand_assets import main as save_flat_brand_assets


ROOT = Path(__file__).resolve().parents[1]
DESIGN_DIR = ROOT / "IconDesign" / "AppIcons2026"
RAW_DIR = DESIGN_DIR / "raw"
IOS_ASSETS = ROOT / "Primuse" / "Resources" / "Assets.xcassets"
IOS_PRIMARY_ICON_NAME = "AppIconPrimary"
WATCH_ICONSET = ROOT / "PrimuseWatch" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"

EXACT_ICONS = [
    (
        "00-primuse",
        "AppIcon",
        "AppIconPreview",
        "00-primuse.png",
        "00-primuse-dark.png",
        "00-primuse-tinted.png",
    ),
    (
        "20-soft-note",
        "AppIcon20",
        "AppIcon20Preview",
        "20-soft-note.png",
        "20-soft-note-dark.png",
        "20-soft-note-tinted.png",
    ),
    (
        "19-chris-muse",
        "AppIcon19",
        "AppIcon19Preview",
        "19-chris-muse.png",
        "19-chris-muse-dark.png",
        "19-chris-muse-tinted.png",
    ),
    (
        "22-kai",
        "AppIcon22",
        "AppIcon22Preview",
        "22-kai.png",
        "22-kai-dark.png",
        "22-kai-tinted.png",
    ),
    (
        "23-ribbon-note",
        "AppIcon23",
        "AppIcon23Preview",
        "23-ribbon-note.png",
        "23-ribbon-note-dark.png",
        "23-ribbon-note-tinted.png",
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
]

CATALOG_ORDER = [icon[1] for icon in EXACT_ICONS]

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
    if icon_name == "AppIcon20":
        from generate_brand_marks import soft_note_artwork
        any_icon = soft_note_artwork()
        dark_icon = soft_note_artwork(dark=True)
        tinted_icon = soft_note_artwork(tinted=True)
    any_icon = any_icon.convert("RGB").resize((1024, 1024), Image.Resampling.LANCZOS)
    dark_icon = dark_icon.convert("RGB").resize((1024, 1024), Image.Resampling.LANCZOS)
    if tinted_icon.mode == "RGBA":
        plate = Image.new("RGB", tinted_icon.size, "black")
        plate.paste(tinted_icon, mask=tinted_icon.getchannel("A"))
        tinted_icon = plate
    tinted_icon = tinted_icon.convert("RGB").resize((1024, 1024), Image.Resampling.LANCZOS)

    master_path = DESIGN_DIR / f"{master_stem}.png"
    any_icon.save(master_path, optimize=True)

    asset_name = IOS_PRIMARY_ICON_NAME if icon_name == "AppIcon" else icon_name
    iconset = IOS_ASSETS / f"{asset_name}.appiconset"
    any_icon.save(iconset / f"{icon_name}.png", optimize=True)
    dark_icon.save(iconset / f"{icon_name}-dark.png", optimize=True)
    tinted_icon.save(iconset / f"{icon_name}-tinted.png", optimize=True)

    preview = IOS_ASSETS / f"{preview_name}.imageset"
    preview_size = (PREVIEW_SIDE, PREVIEW_SIDE)
    any_icon.resize(preview_size, Image.Resampling.LANCZOS).save(preview / f"{preview_name}.png", optimize=True)
    dark_icon.resize(preview_size, Image.Resampling.LANCZOS).save(preview / f"{preview_name}-dark.png", optimize=True)
    return any_icon, dark_icon


def save_watch(watch_icon: Image.Image) -> None:
    # The Mac app uses the iOS AppIconPrimary.icon; actool renders its macOS 15 fallback.
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
    save_watch(rendered_icons["AppIcon"][0])
    save_flat_brand_assets()
    save_contact_sheet(light_icons)
    save_appearance_sheet(light_icons, dark_icons)
    from generate_ios_layered_icons import main as save_ios_layered_icons
    save_ios_layered_icons()
    from generate_tvos_app_icons import main as save_tvos_app_icons
    save_tvos_app_icons()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Keep the supplied artwork in color modes and isolate the glyph in mono mode."""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
from PIL import Image

from generate_app_icon_assets import EXACT_ICONS, IOS_PRIMARY_ICON_NAME, RAW_DIR, ROOT
from generate_brand_marks import build_marks, clear_edges, soft_note_artwork


OUTPUT = ROOT / "Primuse" / "Resources-iOS" / "AppIcons"
ASSETS = ROOT / "Primuse" / "Resources" / "Assets.xcassets"
# 咸鱼吃Sushi has no raw folder: its only source is the supplied full-colour icon.
GROOVE_SOURCE = ASSETS / "AppIconGroove.appiconset" / "AppIconGroove.png"
# Deep teal keeps the cyan identity while leaving the black outlines readable.
GROOVE_DARK_PLATE = ((24, 52, 60), (12, 30, 37))
# The black outlines carry the drawing; a wider grey range keeps them in the mono glyph.
GROOVE_MONO_DARKEST = 90


def appearance_values(light: str | bool, dark: str | bool, mono: str | bool) -> list[dict]:
    return [
        {"value": light},
        {"appearance": "dark", "value": dark},
        {"appearance": "tinted", "value": mono},
    ]


def mono_glyph(mark: tuple[np.ndarray, np.ndarray], darkest: float = 180) -> Image.Image:
    colour, alpha = mark
    alpha = clear_edges(alpha)
    luminance = colour @ np.array([0.299, 0.587, 0.114])
    # Keep the dimensional shading while giving every glyph the same light polarity.
    low, high = np.percentile(luminance[alpha > 0.98], [2, 98])
    shade = darkest + (255 - darkest) * np.clip((luminance - low) / max(high - low, 1), 0, 1)
    rgba = np.dstack([shade, shade, shade, alpha * 255]).round().astype(np.uint8)
    rgba[alpha == 0, :3] = 0
    return Image.fromarray(rgba)


def save_icon(icon_name: str, light_name: str, dark_name: str, mono: Image.Image) -> None:
    asset_name = IOS_PRIMARY_ICON_NAME if icon_name == "AppIcon" else icon_name
    folder = OUTPUT / f"{asset_name}.icon"
    assets = folder / "Assets"
    assets.mkdir(parents=True, exist_ok=True)
    for filename, source in [("Light.png", light_name), ("Dark.png", dark_name)]:
        if icon_name == "AppIcon20":
            artwork = soft_note_artwork(dark=filename == "Dark.png")
        else:
            artwork = Image.open(RAW_DIR / source)
        artwork.convert("RGB").resize(
            (1024, 1024), Image.Resampling.LANCZOS
        ).save(assets / filename, optimize=True)
    mono.save(assets / "Mono.png", optimize=True)
    write_icon_document(folder)


def write_icon_document(folder: Path) -> None:
    document = {
        "fill": {"solid": "srgb:1,1,1,1"},
        "groups": [
            {
                "name": "Artwork",
                "shadow": {"kind": "neutral", "opacity": 0},
                "translucency": {"enabled": False, "value": 0},
                "specular-specializations": appearance_values(False, False, True),
                "layers": [
                    {
                        # Hidden layers still compile into transparent entries in Assets.car.
                        # Swap the artwork so SpringBoard receives only one image per appearance.
                        "name": "Artwork",
                        "image-name-specializations": appearance_values("Light.png", "Dark.png", "Mono.png"),
                        "glass-specializations": appearance_values(False, False, True),
                    },
                ],
            }
        ],
        "supported-platforms": {"squares": "shared"},
    }
    (folder / "icon.json").write_text(json.dumps(document, indent=2) + "\n")


def shifted(values: np.ndarray, dy: int, dx: int) -> np.ndarray:
    return np.roll(np.roll(values, dy, 0), dx, 1)


def groove_glyph(source: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Lift the illustration off its flat cyan plate as unmixed colour + alpha."""
    side = source.shape[0]
    # The plate is flat; a plane fit absorbs any faint drift.
    plate_mask = np.linalg.norm(source - np.array([184.5, 239.5, 242.8]), axis=2) < 8
    y, x = np.mgrid[0:side, 0:side] / (side - 1)
    basis = np.stack([np.ones(plate_mask.sum()), x[plate_mask], y[plate_mask]], 1)
    coef = np.linalg.lstsq(basis, source[plate_mask], rcond=None)[0]
    plate = coef[0] + x[..., None] * coef[1] + y[..., None] * coef[2]
    offset = source - plate
    distance = np.linalg.norm(offset, axis=2)
    # Sharpening left a lighter cyan halo along the outlines; it belongs to the plate.
    halo = (np.abs(offset[..., 0]) < 35) & (offset[..., 1] > -6) & (offset[..., 2] > -6)
    background = (distance < 12) | halo
    near = background.copy()
    for dy in range(-3, 4):
        for dx in range(-3, 4):
            near |= shifted(background, dy, dx)
    interior = ~near
    # Carry interior colours outward so every edge pixel knows its unmixed colour.
    colour = np.where(interior[..., None], source, 0.0)
    known = interior.copy()
    for _ in range(8):
        total = np.zeros_like(colour)
        count = np.zeros(known.shape)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                weight = shifted(known, dy, dx)
                total += shifted(colour, dy, dx) * weight[..., None]
                count += weight
        grow = (count > 0) & ~known
        colour[grow] = total[grow] / count[grow][:, None]
        known |= grow
    # Edge coverage = projection onto the line plate -> unmixed colour, so the halo drops out.
    direction = colour - plate
    coverage = (offset * direction).sum(2) / np.maximum((direction * direction).sum(2), 1e-3)
    alpha = np.where(interior, 1.0, np.where(known, np.clip(coverage, 0, 1), 0.0))
    alpha[distance < 5] = 0
    return colour, alpha


def save_groove_icon() -> None:
    light = Image.open(GROOVE_SOURCE).convert("RGB")
    source = np.asarray(light).astype(np.float64)
    colour, alpha = groove_glyph(source)
    side = source.shape[0]
    top, bottom = (np.array(value, dtype=np.float64) for value in GROOVE_DARK_PLATE)
    ramp = np.linspace(0, 1, side)[:, None, None]
    plate = top + (bottom - top) * ramp
    dark = Image.fromarray(
        (alpha[..., None] * colour + (1 - alpha[..., None]) * plate).round().clip(0, 255).astype(np.uint8)
    )
    mono = mono_glyph((colour, alpha), darkest=GROOVE_MONO_DARKEST)

    folder = OUTPUT / "AppIconGroove.icon"
    (folder / "Assets").mkdir(parents=True, exist_ok=True)
    light.save(folder / "Assets" / "Light.png", optimize=True)
    dark.save(folder / "Assets" / "Dark.png", optimize=True)
    mono.save(folder / "Assets" / "Mono.png", optimize=True)
    write_icon_document(folder)

    # iOS 18-25 and the in-app previews use the asset-catalog copies.
    iconset = ASSETS / "AppIconGroove.appiconset"
    dark.save(iconset / "AppIconGroove-dark.png", optimize=True)
    tinted = Image.new("RGBA", light.size, (0, 0, 0, 255))
    tinted.alpha_composite(mono)
    tinted.convert("RGB").save(iconset / "AppIconGroove-tinted.png", optimize=True)
    preview = ASSETS / "AppIconGroovePreview.imageset"
    dark.resize((512, 512), Image.Resampling.LANCZOS).save(preview / "AppIconGroovePreview-dark.png", optimize=True)


def main() -> None:
    marks = build_marks()
    for _, icon_name, _, light_name, dark_name, tinted_name in EXACT_ICONS:
        light, dark = marks[icon_name]
        with Image.open(RAW_DIR / tinted_name) as tinted:
            mono = (tinted.resize((1024, 1024), Image.Resampling.LANCZOS)
                    if tinted.mode == "RGBA" else mono_glyph(dark or light))
        save_icon(icon_name, light_name, dark_name, mono)
    save_groove_icon()


if __name__ == "__main__":
    main()

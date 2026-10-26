#!/usr/bin/env python3
"""Keep the supplied artwork in color modes and isolate the glyph in mono mode."""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
from PIL import Image

from generate_app_icon_assets import EXACT_ICONS, RAW_DIR, ROOT
from generate_brand_marks import build_marks, clear_edges, soft_note_artwork


OUTPUT = ROOT / "Primuse" / "Resources-iOS" / "AppIcons"


def appearance_opacity(light: int, dark: int, mono: int) -> list[dict]:
    return [
        {"value": light},
        {"appearance": "dark", "value": dark},
        {"appearance": "tinted", "value": mono},
    ]


def mono_glyph(mark: tuple[np.ndarray, np.ndarray]) -> Image.Image:
    colour, alpha = mark
    alpha = clear_edges(alpha)
    luminance = colour @ np.array([0.299, 0.587, 0.114])
    # Keep the dimensional shading while giving every glyph the same light polarity.
    low, high = np.percentile(luminance[alpha > 0.98], [2, 98])
    shade = 180 + 75 * np.clip((luminance - low) / max(high - low, 1), 0, 1)
    rgba = np.dstack([shade, shade, shade, alpha * 255]).round().astype(np.uint8)
    rgba[alpha == 0, :3] = 0
    return Image.fromarray(rgba)


def save_icon(icon_name: str, light_name: str, dark_name: str, mono: Image.Image) -> None:
    folder = OUTPUT / f"{icon_name}.icon"
    assets = folder / "Assets"
    assets.mkdir(parents=True, exist_ok=True)
    for filename, source in [("Light.png", light_name), ("Dark.png", dark_name)]:
        artwork = soft_note_artwork() if icon_name == "AppIcon20" else Image.open(RAW_DIR / source)
        artwork.convert("RGB").resize(
            (1024, 1024), Image.Resampling.LANCZOS
        ).save(assets / filename, optimize=True)
    mono.save(assets / "Mono.png", optimize=True)

    document = {
        "fill": {"solid": "srgb:1,1,1,1"},
        "groups": [
            {
                "name": "Artwork",
                "shadow": {"kind": "neutral", "opacity": 0},
                "translucency": {"enabled": False, "value": 0},
                "layers": [
                    {
                        "name": "Light",
                        "image-name": "Light.png",
                        "glass": False,
                        "opacity-specializations": appearance_opacity(1, 0, 0),
                    },
                    {
                        "name": "Dark",
                        "image-name": "Dark.png",
                        "glass": False,
                        "opacity-specializations": appearance_opacity(0, 1, 0),
                    },
                    {
                        "name": "Mono",
                        "image-name": "Mono.png",
                        "glass": True,
                        "opacity-specializations": appearance_opacity(0, 0, 1),
                    },
                ],
            }
        ],
        "supported-platforms": {"squares": "shared"},
    }
    (folder / "icon.json").write_text(json.dumps(document, indent=2) + "\n")


def main() -> None:
    marks = build_marks()
    for _, icon_name, _, light_name, dark_name, _ in EXACT_ICONS:
        light, dark = marks[icon_name]
        save_icon(icon_name, light_name, dark_name, mono_glyph(dark or light))


if __name__ == "__main__":
    main()

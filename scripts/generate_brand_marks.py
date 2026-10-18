#!/usr/bin/env python3
"""Generate the transparent brand marks: each app icon's glyph without its plate.

The Mac sidebar header shows the mark of the selected app icon and the Apple TV
top bar shows the primary one, so the in-app logo reads as the glyph itself
rather than a coloured tile. Requires Pillow and NumPy.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
RAW_DIR = ROOT / "IconDesign" / "AppIcons2026" / "raw"
IOS_ASSETS = ROOT / "Primuse" / "Resources" / "Assets.xcassets"
TV_ASSETS = ROOT / "PrimuseTV" / "Resources" / "Assets.xcassets"

SIDE = 1024
# The Mac sidebar draws the mark at 24 pt, the TV top bar at 50 pt (@2x on 4K).
MAC_MARK_SIDE = 128
TV_MARK_SIDE = 192

_ys, _xs = np.mgrid[0:SIDE, 0:SIDE] / SIDE - 0.5
_BASIS = np.stack(
    [b.ravel() for b in (
        np.ones_like(_xs), _xs, _ys, _xs * _xs, _xs * _ys, _ys * _ys,
        _xs ** 3, _xs * _xs * _ys, _xs * _ys * _ys, _ys ** 3,
    )],
    axis=1,
)


def load(name: str) -> np.ndarray:
    image = Image.open(RAW_DIR / f"{name}.png").convert("RGB")
    return np.asarray(image.resize((SIDE, SIDE), Image.Resampling.LANCZOS)).astype(float)


def luminance(plate: np.ndarray) -> np.ndarray:
    return plate @ np.array([0.299, 0.587, 0.114])


def ground_mask(plate: np.ndarray, polarity: int) -> np.ndarray:
    """Pixels well clear of the glyph, used to fit the plate's ground."""
    lum = luminance(plate)
    band = int(SIDE * 0.04)
    border = np.concatenate([lum[:band].ravel(), lum[-band:].ravel(), lum[:, :band].ravel(), lum[:, -band:].ravel()])
    glyph = polarity * (lum - np.median(border)) > 35
    grown = (
        Image.fromarray((glyph * 255).astype(np.uint8))
        .resize((256, 256))
        .filter(ImageFilter.MaxFilter(25))
        .resize((SIDE, SIDE))
    )
    return np.asarray(grown) < 128


def fit_ground(channel: np.ndarray, keep: np.ndarray) -> np.ndarray:
    """Cubic surface fit, so gradient and vignetted plates are handled too."""
    rows = keep.ravel()
    coefficients, *_ = np.linalg.lstsq(_BASIS[rows], channel.ravel()[rows], rcond=None)
    return (_BASIS @ coefficients).reshape(SIDE, SIDE)


def ramp(difference: np.ndarray, low: float, high: float) -> np.ndarray:
    return np.clip((difference - low) / (high - low), 0, 1)


def luma_alpha(plate: np.ndarray, polarity: int, low: float, high: float) -> np.ndarray:
    """Coverage from how far the glyph's luminance sits from the ground.

    Cast shadows fall on the other side of the ground and drop out.
    """
    lum = luminance(plate)
    return ramp(polarity * (lum - fit_ground(lum, ground_mask(plate, polarity))), low, high)


def chroma_alpha(plate: np.ndarray, polarity: int, low: float, high: float) -> np.ndarray:
    """Coverage from the largest per-channel distance to the ground, for saturated glyphs."""
    keep = ground_mask(plate, polarity)
    distance = np.zeros((SIDE, SIDE))
    for channel in range(3):
        distance = np.maximum(distance, np.abs(plate[..., channel] - fit_ground(plate[..., channel], keep)))
    return ramp(distance, low, high)


def glyph_colour(plate: np.ndarray, alpha: np.ndarray) -> np.ndarray:
    """Un-mix the plate's own ground out of the anti-aliased edges."""
    keep = ground_mask(plate, 1 if luminance(plate)[:20].mean() < 128 else -1)
    colour = np.empty_like(plate)
    for channel in range(3):
        ground = fit_ground(plate[..., channel], keep)
        colour[..., channel] = ground + (plate[..., channel] - ground) / np.maximum(alpha, 1e-3)
    return np.clip(colour, 0, 255)


def tinted_colour(plate: np.ndarray, alpha: np.ndarray, deep: tuple, light: tuple) -> np.ndarray:
    """Recolour a white glyph with the icon's tint, keeping its shading."""
    lum = luminance(plate)
    shade = np.clip(lum / np.percentile(lum[alpha > 0.98], 90), 0, 1.1)[..., None]
    deep_rgb, light_rgb = np.array(deep, float), np.array(light, float)
    colour = deep_rgb + (light_rgb - deep_rgb) * np.clip((shade - 0.7) / 0.35, 0, 1)
    return np.clip(colour * (0.6 + 0.4 * shade), 0, 255)


Layer = tuple[np.ndarray, np.ndarray]


def build_marks() -> dict[str, tuple[Layer, Layer | None]]:
    """(light, dark) colour and coverage per icon set name; no dark layer when one serves both."""
    marks: dict[str, tuple[Layer, Layer | None]] = {}

    # Primuse: the Tinted plate's ground is a flat 28 grey with the note cut out, so
    # a tight ramp keeps the whole shaded ribbon opaque. The Light plate fades the
    # note head into the hole through near-white highlights, so both appearances
    # take the Dark plate's saturated magenta.
    alpha = luma_alpha(load("00-primuse-tinted"), 1, 4, 14)
    marks["AppIcon"] = ((glyph_colour(load("00-primuse-dark"), alpha), alpha), None)

    # Pikaqiu: the Tinted plate's star is drawn offset, so each plate keys itself.
    light_alpha = chroma_alpha(load("12-pikaqiu"), -1, 25, 70)
    dark_alpha = chroma_alpha(load("12-pikaqiu-dark"), 1, 25, 70)
    marks["AppIcon12"] = (
        (glyph_colour(load("12-pikaqiu"), light_alpha), light_alpha),
        (glyph_colour(load("12-pikaqiu-dark"), dark_alpha), dark_alpha),
    )

    # Letter P, splash and Chris's Muse are white glyphs on a colour in Light, which
    # would vanish on a light sidebar; their Dark plates carry the colour-tinted
    # glyph, and NonoEnd's Dark clef has no rim light or cast shadow.
    for name, stem in (
        ("AppIcon14", "14-letter-p"),
        ("AppIcon16", "16-nonoend"),
        ("AppIcon17", "17-splash"),
        ("AppIcon19", "19-chris-muse"),
    ):
        alpha = luma_alpha(load(f"{stem}-tinted"), 1, 10, 40)
        marks[name] = ((glyph_colour(load(f"{stem}-dark"), alpha), alpha), None)

    alpha = luma_alpha(load("15-folded-note-tinted"), 1, 10, 40)
    marks["AppIcon15"] = (
        (glyph_colour(load("15-folded-note"), alpha), alpha),
        (glyph_colour(load("15-folded-note-dark"), alpha), alpha),
    )

    # Soft note: the Tinted plate keeps the cast shadow on the glyph's side of the
    # ground, so key the white note off the Dark plate above its teal glow. Light
    # recolours it with the icon's aqua so it stays visible on a light sidebar.
    dark = load("20-soft-note-dark")
    alpha = luma_alpha(dark, 1, 100, 170)
    marks["AppIcon20"] = (
        (tinted_colour(dark, alpha, (22, 150, 150), (64, 213, 200)), alpha),
        (glyph_colour(dark, alpha), alpha),
    )
    return marks


def crop_box(alphas: list[np.ndarray]) -> tuple[int, int, int, int]:
    """Square around the union of both appearances so they line up."""
    ys, xs = np.where(np.maximum.reduce(alphas) > 0.04)
    top, bottom, left, right = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    side = int(max(bottom - top, right - left) * 1.04)
    centre_y, centre_x = (top + bottom) // 2, (left + right) // 2
    return centre_x - side // 2, centre_y - side // 2, centre_x - side // 2 + side, centre_y - side // 2 + side


def render(layer: Layer, box: tuple[int, int, int, int], side: int) -> Image.Image:
    colour, alpha = layer
    rgba = np.dstack([colour * (alpha[..., None] > 0), alpha * 255]).round().astype(np.uint8)
    # Image.crop pads outside the canvas with transparent pixels.
    return Image.fromarray(rgba, "RGBA").crop(box).resize((side, side), Image.Resampling.LANCZOS)


def save_imageset(folder: Path, name: str, light: Image.Image, dark: Image.Image | None) -> None:
    imageset = folder / f"{name}.imageset"
    imageset.mkdir(exist_ok=True)
    for stale in imageset.glob("*.png"):
        stale.unlink()
    light.save(imageset / f"{name}.png", optimize=True)
    images: list[dict] = [{"filename": f"{name}.png", "idiom": "universal", "scale": "1x"}]
    if dark is not None:
        dark.save(imageset / f"{name}-dark.png", optimize=True)
        images.append({
            "appearances": [{"appearance": "luminosity", "value": "dark"}],
            "filename": f"{name}-dark.png",
            "idiom": "universal",
            "scale": "1x",
        })
    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    (imageset / "Contents.json").write_text(json.dumps(contents, indent=2).replace('": ', '" : ') + "\n")


def clear_edges(alpha: np.ndarray) -> np.ndarray:
    """No glyph reaches the outer 3%; drop stray plate specks there."""
    margin = int(SIDE * 0.03)
    alpha = alpha.copy()
    alpha[:margin], alpha[-margin:], alpha[:, :margin], alpha[:, -margin:] = 0, 0, 0, 0
    return alpha


def main() -> None:
    for name, (light, dark) in build_marks().items():
        light = (light[0], clear_edges(light[1]))
        dark = (dark[0], clear_edges(dark[1])) if dark else None
        box = crop_box([light[1]] + ([dark[1]] if dark else []))
        targets = [(IOS_ASSETS, MAC_MARK_SIDE)]
        if name == "AppIcon":
            # tvOS has no alternate icons; its top bar always shows the primary mark.
            targets.append((TV_ASSETS, TV_MARK_SIDE))
        for folder, side in targets:
            dark_image = render(dark, box, side) if dark else None
            save_imageset(folder, f"{name}Mark", render(light, box, side), dark_image)


if __name__ == "__main__":
    main()

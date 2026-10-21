#!/usr/bin/env python3
"""Export supplied flat artwork into transparent marks and tvOS layers."""

from pathlib import Path
import json

import numpy as np
from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
APP = "Primuse" if (ROOT / "Primuse").exists() else "Viozi"
SOURCE = ROOT / "IconDesign/AppIcons2026/raw" if APP == "Primuse" else ROOT / "scripts/app-icons"
LIGHT = "00-primuse.png" if APP == "Primuse" else "light.png"
DARK = "00-primuse-dark.png" if APP == "Primuse" else "dark.png"


def split_plate(filename):
    image = Image.open(SOURCE / filename).convert("RGB").resize((1024, 1024), Image.Resampling.LANCZOS)
    pixels = np.asarray(image, dtype=float)
    # The supplied flat masters have a vertical gradient and a solid glyph.
    ground = np.broadcast_to(pixels[:, :1], pixels.shape)
    difference = pixels - ground
    distance = np.max(np.abs(difference), axis=2)
    foreground = np.median(pixels[distance > np.max(distance) * .8], axis=0)
    direction = foreground - ground
    alpha = np.clip(np.sum(difference * direction, axis=2) / np.maximum(np.sum(direction * direction, axis=2), 1), 0, 1)
    rgba = np.dstack([np.broadcast_to(foreground, pixels.shape), alpha * 255]).round().astype(np.uint8)
    return image, Image.fromarray(rgba), Image.fromarray(ground.astype(np.uint8))


def save_mark(assets, side, light, dark):
    folder = assets / "AppIconMark.imageset"
    folder.mkdir(exist_ok=True)
    box = light.getbbox()
    left, top, right, bottom = box
    width = max(right - left, bottom - top) * 1.04
    cx, cy = (left + right) / 2, (top + bottom) / 2
    crop = tuple(round(v) for v in (cx - width / 2, cy - width / 2, cx + width / 2, cy + width / 2))
    images = []
    for suffix, artwork in [("", light), ("-dark", dark)]:
        filename = f"AppIconMark{suffix}.png"
        artwork.crop(crop).resize((side, side), Image.Resampling.LANCZOS).save(folder / filename, optimize=True)
        entry = {"filename": filename, "idiom": "universal", "scale": "1x"}
        if suffix:
            entry["appearances"] = [{"appearance": "luminosity", "value": "dark"}]
        images.append(entry)
    (folder / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")


def landscape(glyph, ground, width, height, fraction):
    back = ground.resize((width, height), Image.Resampling.LANCZOS)
    front = Image.new("RGBA", (width, height))
    cropped = glyph.crop(glyph.getbbox())
    target_height = round(height * fraction)
    target_width = round(cropped.width * target_height / cropped.height)
    cropped = cropped.resize((target_width, target_height), Image.Resampling.LANCZOS)
    front.alpha_composite(cropped, ((width - target_width) // 2, (height - target_height) // 2))
    return back, front


def save_default_artwork():
    if APP != "Primuse":
        return
    targets = [ROOT / "PrimuseTV/Resources/Assets.xcassets"]
    for assets in targets:
        folder = assets / "DefaultArtwork.imageset"
        folder.mkdir(exist_ok=True)
        images = []
        for suffix, source in [("", LIGHT), ("-dark", DARK)]:
            filename = f"DefaultArtwork{suffix}.png"
            Image.open(SOURCE / source).convert("RGB").resize((1024, 1024), Image.Resampling.LANCZOS).save(folder / filename, optimize=True)
            entry = {"filename": filename, "idiom": "universal"}
            if suffix:
                entry["appearances"] = [{"appearance": "luminosity", "value": "dark"}]
            images.append(entry)
        (folder / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")


def main():
    save_default_artwork()
    _, light, _ = split_plate(LIGHT)
    plate, dark, ground = split_plate(DARK)
    assets = ROOT / APP / "Resources/Assets.xcassets"
    tv_assets = ROOT / (APP + "TV") / "Resources/Assets.xcassets"
    save_mark(assets, 128, light, dark)
    save_mark(tv_assets, 192, light, dark)
    brand = tv_assets / "BrandMark.imageset/brandmark.png"
    if brand.exists():
        plate.resize((256, 256), Image.Resampling.LANCZOS).save(brand, optimize=True)
    tv = tv_assets / "AppIcon.brandassets"
    for width, height, stack in [(400, 240, "App Icon"), (800, 480, "App Icon"), (1280, 768, "App Icon - App Store")]:
        back, front = landscape(dark, ground, width, height, .56)
        for name, artwork in [("Back", back), ("Front", front)]:
            output = tv / f"{stack}.imagestack/{name}.imagestacklayer/Content.imageset/{name.lower()}_{width}.png"
            artwork.save(output, optimize=True)
    for folder, stem, width in [("Top Shelf Image", "topshelf", 1920), ("Top Shelf Image Wide", "topshelf_wide", 2320)]:
        for scale in [1, 2]:
            back, front = landscape(dark, ground, width * scale, 720 * scale, .44)
            back.paste(front, mask=front.getchannel("A"))
            suffix = "@2x" if scale == 2 else ""
            back.save(tv / f"{folder}.imageset/{stem}{suffix}.png", optimize=True)


if __name__ == "__main__":
    main()

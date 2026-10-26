#!/usr/bin/env python3
"""Build tvOS alternate icon stacks and previews from the retained artwork."""

import json
import shutil

import numpy as np
from PIL import Image

from generate_app_icon_assets import EXACT_ICONS, IOS_ASSETS, RAW_DIR, ROOT
from generate_brand_marks import build_marks, clear_edges, SOFT_NOTE_GREEN
from generate_flat_brand_assets import landscape


TV_ASSETS = ROOT / "PrimuseTV/Resources/Assets.xcassets"
INFO = {"author": "xcode", "version": 1}


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({**data, "info": INFO}, indent=2) + "\n")


def main(only=None):
    marks = build_marks()
    for _, name, preview, _, dark_file, _ in EXACT_ICONS:
        if only is not None and name not in only:
            continue
        shutil.copytree(IOS_ASSETS / f"{preview}.imageset",
                        TV_ASSETS / f"{preview}.imageset", dirs_exist_ok=True)
        if name == "AppIcon":
            # Keep the primary icon and its Top Shelf artwork unchanged.
            continue

        shutil.copytree(IOS_ASSETS / f"{name}Mark.imageset",
                        TV_ASSETS / f"{name}Mark.imageset", dirs_exist_ok=True)
        light, dark = marks[name]
        colour, alpha = dark or light
        alpha = clear_edges(alpha)
        glyph = Image.fromarray(np.dstack([colour, alpha * 255]).clip(0, 255).astype(np.uint8))
        plate = Image.open(RAW_DIR / dark_file).convert("RGB")
        ground = (Image.new("RGB", (1, plate.height), SOFT_NOTE_GREEN)
                  if name == "AppIcon20" else plate.crop((0, 0, 1, plate.height)))
        folder = TV_ASSETS
        for stack_name, sizes in [(name, [(400, 240), (800, 480)])]:
            stack = folder / f"{stack_name}.imagestack"
            layers = {"Back": [], "Front": []}
            for index, (width, height) in enumerate(sizes):
                back, front = landscape(glyph, ground, width, height, .56)
                for layer_name, image in [("Back", back), ("Front", front)]:
                    imageset = stack / f"{layer_name}.imagestacklayer/Content.imageset"
                    imageset.mkdir(parents=True, exist_ok=True)
                    filename = f"{layer_name.lower()}_{width}.png"
                    image.save(imageset / filename, optimize=True)
                    layers[layer_name].append({"idiom": "tv", "filename": filename,
                                               "scale": f"{index + 1}x"})
                if width == 800:
                    back.paste(front, mask=front.getchannel("A"))
                    preview_name = f"{name}TVPreview"
                    preview_folder = TV_ASSETS / f"{preview_name}.imageset"
                    preview_folder.mkdir(exist_ok=True)
                    back.save(preview_folder / f"{preview_name}.png", optimize=True)
                    write_json(preview_folder / "Contents.json", {"images": [
                        {"filename": f"{preview_name}.png", "idiom": "tv", "scale": "1x"}
                    ]})
            for layer_name, images in layers.items():
                layer = stack / f"{layer_name}.imagestacklayer"
                write_json(layer / "Contents.json", {})
                write_json(layer / "Content.imageset/Contents.json", {"images": images})
            write_json(stack / "Contents.json", {"layers": [
                {"filename": "Front.imagestacklayer"}, {"filename": "Back.imagestacklayer"}
            ]})

    if only is not None and "AppIcon" not in only:
        return
    primary = TV_ASSETS / "AppIcon.brandassets/App Icon.imagestack"
    back = Image.open(primary / "Back.imagestacklayer/Content.imageset/back_800.png").convert("RGB")
    front = Image.open(primary / "Front.imagestacklayer/Content.imageset/front_800.png").convert("RGBA")
    back.paste(front, mask=front.getchannel("A"))
    preview = TV_ASSETS / "AppIconTVPreview.imageset"
    preview.mkdir(exist_ok=True)
    back.save(preview / "AppIconTVPreview.png", optimize=True)
    write_json(preview / "Contents.json", {"images": [
        {"filename": "AppIconTVPreview.png", "idiom": "tv", "scale": "1x"}
    ]})


if __name__ == "__main__":
    main()

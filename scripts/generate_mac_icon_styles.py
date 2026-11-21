#!/usr/bin/env python3
"""Pre-render the macOS Dock artwork of every alternate app icon in each system icon style.

macOS 26 起系统按「图标与小组件样式」显示包里的默认图标；备选图标只能在运行时盖到 Dock 上，
系统不会替它换外观。这里用 Icon Composer 的 ictool 把每款备选 .icon 渲染成默认、深色、
透明（浅、深）四张图；着色版随用户选的颜色变化，拟合成「底图 + 系数图 × 着色颜色」两张图，
运行时按颜色合成（见 PrimuseKit/AppIconStylePolicy.swift）。

在装了 Xcode 26+ 的 Mac 上直接运行：
    python3 scripts/generate_mac_icon_styles.py
也可以拆开：Mac 上 `--render-only DIR` 只出渲染图（不需要 Pillow），
再在任意装了 Pillow 和 numpy 的机器上 `--build-from DIR` 生成资源。
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ICON_SOURCES = ROOT / "Primuse" / "Resources-iOS" / "AppIcons"
CATALOG = ROOT / "Primuse" / "Resources-macOS" / "AppIconStyles.xcassets"
TINT_TABLE = ROOT / "PrimuseKit" / "Sources" / "PrimuseKit" / "AppIconTintTable.swift"

ICONS = ["AppIcon20", "AppIcon19", "AppIcon22", "AppIcon23", "AppIcon15", "AppIcon12", "AppIconGroove"]
# 资源名后缀 → ictool rendition
STATIC_RENDITIONS = {
    "RegularLight": "Default",
    "RegularDark": "Dark",
    "ClearLight": "ClearLight",
    "ClearDark": "ClearDark",
}
TINT_MODES = {"TintedLight": "TintedLight", "TintedDark": "TintedDark"}

CANVAS = 512                     # Dock 最大 256 pt @2x
BODY = round(CANVAS * 824 / 1024)  # macOS 图标网格：1024 画布里主体 824
CAL_HUES = [i / 24 for i in range(24)]
CAL_STRENGTHS = [0, 0.25, 0.5, 0.75, 1]
CAL_SIDE = 64                     # 拟合颜色表只用小图
FIT_SAMPLES = [(h / 6, 1.0) for h in range(6)] + [(0.0, 0.0), (0.5, 0.5), (0.75, 0.25)]


def ictool() -> Path:
    developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
    tool = developer.parent / "Applications/Icon Composer.app/Contents/Executables/ictool"
    if not tool.is_file():
        raise SystemExit("Requires Xcode with Icon Composer (ictool)")
    return tool


def render_one(tool: Path, icon: str, rendition: str, side: int, out: Path,
               hue: float | None = None, strength: float | None = None) -> None:
    args = [str(tool), str(ICON_SOURCES / f"{icon}.icon"), "--export-image", "--output-file", str(out),
            "--platform", "macOS", "--rendition", rendition,
            "--width", str(side // 2), "--height", str(side // 2), "--scale", "2"]
    if hue is not None:
        args += ["--tint-color", f"{hue:.6f}", "--tint-strength", f"{strength:.6f}"]
    subprocess.run(args, check=True, capture_output=True, text=True)


def tint_name(icon: str, mode: str, hue: float, strength: float, side: int) -> str:
    return f"{icon}-{mode}-h{hue:.4f}-s{strength:.2f}-{side}.png"


def render_all(work: Path, only_icon: str | None = None) -> None:
    tool = ictool()
    work.mkdir(parents=True, exist_ok=True)
    icons = [only_icon] if only_icon else ICONS
    for icon in icons:
        for suffix, rendition in STATIC_RENDITIONS.items():
            render_one(tool, icon, rendition, BODY, work / f"{icon}-{suffix}.png")
        for mode, rendition in TINT_MODES.items():
            if only_icon is None:
                for hue in CAL_HUES:
                    for strength in CAL_STRENGTHS:
                        render_one(tool, icon, rendition, CAL_SIDE,
                                   work / tint_name(icon, mode, hue, strength, CAL_SIDE), hue, strength)
            for hue, strength in FIT_SAMPLES:
                render_one(tool, icon, rendition, BODY,
                           work / tint_name(icon, mode, hue, strength, BODY), hue, strength)
        print(f"rendered {icon}", flush=True)


# MARK: - build

def build_from(work: Path, only_icon: str | None = None) -> None:
    import numpy as np
    from PIL import Image, ImageFilter

    calibration = {mode: bundled_calibration(mode) for mode in TINT_MODES} if only_icon else {}

    def load(path: Path):
        return np.asarray(Image.open(path).convert("RGBA")).astype(np.float64) / 255

    def premultiplied(img):
        return img[..., :3] * img[..., 3:]

    offset = (CANVAS - BODY) // 2

    def shadow_alpha(body_alpha):
        """系统图标那圈很淡、略往下偏的阴影（量自 Xcode 生成的 macOS 回退图标）。"""
        alpha = Image.new("L", (CANVAS, CANVAS), 0)
        alpha.paste(Image.fromarray(np.round(body_alpha * 255).astype(np.uint8), "L"),
                    (offset, offset + round(CANVAS * 0.006)))
        blurred = alpha.filter(ImageFilter.GaussianBlur(CANVAS * 0.016))
        return np.asarray(blurred).astype(np.float64) / 255 * 0.32

    def place(body):
        """Put a full-bleed ictool render on the macOS icon canvas with the system's soft shadow."""
        body_image = Image.fromarray(np.round(body * 255).astype(np.uint8), "RGBA")
        shadow = np.zeros((CANVAS, CANVAS, 4))
        shadow[..., 3] = shadow_alpha(body[..., 3])
        canvas = Image.fromarray(np.round(shadow * 255).astype(np.uint8), "RGBA")
        canvas.alpha_composite(body_image, (offset, offset))
        return canvas

    def save_imageset(name: str, image) -> None:
        folder = CATALOG / f"{name}.imageset"
        folder.mkdir(parents=True, exist_ok=True)
        for stale in folder.glob("*.png"):
            stale.unlink()
        image.save(folder / f"{name}.png", optimize=True)
        contents = {"images": [{"filename": f"{name}.png", "idiom": "universal", "scale": "2x"}],
                    "info": {"author": "xcode", "version": 1}}
        (folder / "Contents.json").write_text(json.dumps(contents, indent=2).replace('": ', '" : ') + "\n")

    def save_dataset(name: str, image) -> None:
        folder = CATALOG / f"{name}.dataset"
        folder.mkdir(parents=True, exist_ok=True)
        for stale in folder.glob("*.png"):
            stale.unlink()
        image.save(folder / f"{name}.png", optimize=True)
        contents = {"data": [{"filename": f"{name}.png", "idiom": "universal",
                              "universal-type-identifier": "public.png"}],
                    "info": {"author": "xcode", "version": 1}}
        (folder / "Contents.json").write_text(json.dumps(contents, indent=2).replace('": ', '" : ') + "\n")

    CATALOG.mkdir(parents=True, exist_ok=True)
    (CATALOG / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2)
                                           .replace('": ', '" : ') + "\n")

    icons = [only_icon] if only_icon else ICONS
    for icon in icons:
        for suffix in STATIC_RENDITIONS:
            save_imageset(f"{icon}-{suffix}", place(load(work / f"{icon}-{suffix}.png")))

    def fit_tint_table(mode, grid):
        stacks = []
        for icon in ICONS:
            frames = [premultiplied(load(work / tint_name(icon, mode, h, s, CAL_SIDE))) for h, s in grid]
            stacks.append(np.stack(frames, -1).reshape(-1, 3, len(grid)))
        table = np.stack([x.mean(0) for x in stacks]).mean(0)  # 3 x K
        for _ in range(60):
            fits = []
            design = np.stack([np.ones(3 * len(grid)), table.reshape(-1)], 1)
            for x in stacks:
                fits.append(np.linalg.lstsq(design, x.reshape(x.shape[0], -1).T, rcond=None)[0])
            numerator = np.zeros_like(table)
            denominator = 0.0
            for x, (a, b) in zip(stacks, fits):
                numerator += np.einsum("p,pck->ck", b, x - a[:, None, None])
                denominator += b @ b
            table = numerator / denominator
        # A + B × T 的 T 只确定到一个仿射变换；方向翻了就翻回来，让 T 和画出来的颜色同向。
        mean_colour = np.stack([x.mean(0) for x in stacks]).mean(0)
        if np.corrcoef(table.reshape(-1), mean_colour.reshape(-1))[0, 1] < 0:
            table = -table
        # 规范到 0...1，方便存成定点数。
        low, high = table.min(), table.max()
        return (table - low) / (high - low)

    grid = [(h, s) for s in CAL_STRENGTHS for h in CAL_HUES]
    tables = {}
    ranges = {}
    for mode in TINT_MODES:
        # 1. 用参考图标的小图拟合共享颜色表，每款图标各自拟合 A、B。
        if calibration:
            table, fixed_range = calibration[mode]
        else:
            table = fit_tint_table(mode, grid)
            fixed_range = None
        tables[mode] = table

        # 2. 每款图标用大图在固定颜色表下拟合 A、B。
        maps = {}
        for icon in icons:
            frames = [load(work / tint_name(icon, mode, h, s, BODY)) for h, s in FIT_SAMPLES]
            alpha = np.median(np.stack([f[..., 3] for f in frames]), 0)
            x = np.stack([premultiplied(f) for f in frames], -1).reshape(-1, 3, len(FIT_SAMPLES))
            t = np.stack([table[:, grid.index((h, s))] for h, s in FIT_SAMPLES], -1)  # 3 x N
            design = np.stack([np.ones(3 * len(FIT_SAMPLES)), t.reshape(-1)], 1)
            a, b = np.linalg.lstsq(design, x.reshape(x.shape[0], -1).T, rcond=None)[0]
            prediction = a[:, None, None] + b[:, None, None] * t[None]
            error = np.abs(prediction - x) * 255
            print(f"{icon} {mode}: mean {error.mean():.2f}, p99 {np.percentile(error, 99):.1f} (of 255)")
            maps[icon] = (a.reshape(BODY, BODY), b.reshape(BODY, BODY), alpha)
        if fixed_range is not None:
            a_low, a_high, b_low, b_high = fixed_range
        else:
            a_low = min(m[0].min() for m in maps.values())
            a_high = max(m[0].max() for m in maps.values())
            b_low = min(m[1].min() for m in maps.values())
            b_high = max(m[1].max() for m in maps.values())
        ranges[mode] = (a_low, a_high, b_low, b_high)
        for icon, (a, b, alpha) in maps.items():
            encoded = np.stack([
                np.round((a - a_low) / (a_high - a_low) * 255),
                np.round((b - b_low) / (b_high - b_low) * 255),
            ], -1).clip(0, 255).astype(np.uint8)
            # 放进图标网格：主体外 A、B 取 0（阴影是黑色，预乘后颜色为 0），透明度并上阴影。
            canvas = np.zeros((CANVAS, CANVAS, 3), dtype=np.uint8)
            canvas[..., 0] = int(round((0 - a_low) / (a_high - a_low) * 255))
            canvas[..., 1] = int(round((0 - b_low) / (b_high - b_low) * 255))
            canvas[offset:offset + BODY, offset:offset + BODY, :2] = encoded[..., :2]
            body_alpha = np.zeros((CANVAS, CANVAS))
            body_alpha[offset:offset + BODY, offset:offset + BODY] = alpha
            total = body_alpha + shadow_alpha(alpha) * (1 - body_alpha)
            canvas[..., 2] = np.round(total * 255).astype(np.uint8)
            save_dataset(f"{icon}-{mode}", Image.fromarray(canvas, "RGB"))

    if only_icon is None:
        write_tint_table(tables, ranges, grid)


def bundled_calibration(mode: str):
    """Use the same table and quantization ranges as the existing Dock resources."""
    import numpy as np

    source = TINT_TABLE.read_text()
    name = mode.removeprefix("Tinted").lower()
    table_start = source.index(f"static let {name}: [[[Double]]] = [")
    rows = source[table_start:].splitlines()[1:1 + len(CAL_STRENGTHS)]
    table = np.array([json.loads(row.strip().rstrip(",")) for row in rows])
    if table.shape != (len(CAL_STRENGTHS), len(CAL_HUES), 3):
        raise ValueError(f"Invalid {name} tint table")
    declaration = next(line for line in source.splitlines() if f"static let {name}Range =" in line)
    values = dict(re.findall(r"(aLow|aHigh|bLow|bHigh): ([-.0-9]+)", declaration))
    bounds = tuple(float(values[key]) for key in ("aLow", "aHigh", "bLow", "bHigh"))
    return table.reshape(-1, 3).T, bounds


def write_tint_table(tables, ranges, grid) -> None:
    import colorsys

    def row(values):
        return ", ".join(f"{v:.5f}" for v in values)

    dark = tables["TintedDark"]
    display_hues = []
    for index, hue in enumerate(CAL_HUES):
        r, g, b = dark[:, grid.index((hue, 1))]
        display_hues.append(colorsys.rgb_to_hsv(r, g, b)[0])
    lines = [
        "// 由 scripts/generate_mac_icon_styles.py 生成，不要手改。",
        "// 着色样式的颜色表：ictool 按「色相 × 强度」网格渲染全部备选图标后联合拟合出的颜色项 T，",
        "// 每款图标的着色图 = A + B × T（A、B 见 Resources-macOS/AppIconStyles.xcassets）。",
        "",
        "enum AppIconTintTable {",
        f"    static let hues: [Double] = [{row(CAL_HUES)}]",
        f"    static let strengths: [Double] = [{row(CAL_STRENGTHS)}]",
        "    /// 每个网格色相在深色着色下画出来的颜色的色相，用来把系统颜色换算回网格色相。",
        f"    static let displayHues: [Double] = [{row(display_hues)}]",
    ]
    for mode, name in [("TintedLight", "light"), ("TintedDark", "dark")]:
        table = tables[mode]
        lines.append(f"    /// [强度][色相] → (r, g, b)")
        lines.append(f"    static let {name}: [[[Double]]] = [")
        for s in CAL_STRENGTHS:
            cells = ", ".join(f"[{row(table[:, grid.index((h, s))])}]" for h in CAL_HUES)
            lines.append(f"        [{cells}],")
        lines.append("    ]")
        a_low, a_high, b_low, b_high = ranges[mode]
        lines.append(f"    static let {name}Range = AppIconTintMapRange("
                     f"aLow: {a_low:.6f}, aHigh: {a_high:.6f}, bLow: {b_low:.6f}, bHigh: {b_high:.6f})")
    lines.append("}")
    TINT_TABLE.write_text("\n".join(lines) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--render-only", type=Path, help="only render with ictool into this folder")
    parser.add_argument("--build-from", type=Path, help="build assets from renders in this folder")
    parser.add_argument("--icon", choices=ICONS, help="regenerate one icon using the bundled tint calibration")
    options = parser.parse_args()
    if options.render_only:
        render_all(options.render_only, options.icon)
    elif options.build_from:
        build_from(options.build_from, options.icon)
    else:
        with tempfile.TemporaryDirectory() as work:
            render_all(Path(work), options.icon)
            build_from(Path(work), options.icon)


if __name__ == "__main__":
    main()

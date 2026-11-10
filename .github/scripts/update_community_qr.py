#!/usr/bin/env python3
"""根据群二维码的图片内容更新 README 图片版本，避免复用 GitHub 的旧缓存。"""

import argparse
import hashlib
from pathlib import Path
import re
import sys
from urllib.request import Request, urlopen


SOURCE_URL = "https://g2.al/palveni"
MAX_IMAGE_BYTES = 2 * 1024 * 1024
QR_IMAGE = re.compile(r'<img\b[^>]*\balt="Palveni 微信群聊二维码"[^>]*>')
IMAGE_SOURCE = re.compile(r'(?<![\w-])src="[^"]*"')


def fetch_image():
    request = Request(SOURCE_URL, headers={
        "Cache-Control": "no-cache",
        "User-Agent": "Primuse-community-qr-sync/1.0",
    })
    with urlopen(request, timeout=30) as response:
        if response.status != 200:
            raise ValueError("二维码接口未返回完整图片")
        content_type = response.headers.get_content_type()
        image = response.read(MAX_IMAGE_BYTES + 1)

    if not image or len(image) > MAX_IMAGE_BYTES:
        raise ValueError("二维码图片为空或超过 2 MiB")
    png = (len(image) >= 45 and image.startswith(b"\x89PNG\r\n\x1a\n")
           and image[12:16] == b"IHDR"
           and image.endswith(b"\x00\x00\x00\x00IEND\xaeB`\x82"))
    jpeg = (len(image) >= 32 and image.startswith(b"\xff\xd8\xff")
            and image.endswith(b"\xff\xd9"))
    if not ((content_type == "image/png" and png)
            or (content_type == "image/jpeg" and jpeg)):
        raise ValueError("二维码接口未返回 PNG/JPEG 图片，保留现有 README")
    return image


def update_readme(path, image):
    original = path.read_text(encoding="utf-8")
    matches = list(QR_IMAGE.finditer(original))
    if len(matches) != 1:
        raise ValueError("README 必须包含且仅包含一张 Palveni 微信群聊二维码")
    match = matches[0]
    version = hashlib.sha256(image).hexdigest()
    tag, count = IMAGE_SOURCE.subn(f'src="{SOURCE_URL}?v={version}"', match.group())
    if count != 1:
        raise ValueError("二维码图片必须包含且仅包含一个 src 属性")
    updated = original[:match.start()] + tag + original[match.end():]
    if updated == original:
        return False
    path.write_text(updated, encoding="utf-8")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--readme", type=Path,
                        default=Path(__file__).resolve().parents[2] / "README.md")
    args = parser.parse_args()
    try:
        changed = update_readme(args.readme, fetch_image())
    except (OSError, ValueError) as error:
        print(f"群二维码同步失败：{error}", file=sys.stderr)
        return 1
    print("已更新群二维码图片版本" if changed else "群二维码未变化，无需提交")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

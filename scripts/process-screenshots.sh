#!/usr/bin/env bash
#
# Resize App Store screenshots to one of Apple's accepted Mac sizes.
# Center-crops to 16:10 first (Apple's required aspect), then downscales
# to 2880×1800 (high-DPI source) or 1440×900 (smaller source).
#
# Usage:
#   scripts/process-screenshots.sh <input_dir> [output_dir]
#
#   scripts/process-screenshots.sh ~/Downloads/截屏/macos/en
#     → writes to ~/Downloads/截屏/macos/en/processed/
#
# Apple's accepted Mac sizes:
#   2880 × 1800 (recommended, Retina)
#   2560 × 1600
#   1440 × 900
#   1280 × 800

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <input_dir> [output_dir]" >&2
  exit 1
fi

IN_DIR="$1"
OUT_DIR="${2:-$IN_DIR/processed}"

if [ ! -d "$IN_DIR" ]; then
  echo "❌ Input dir not found: $IN_DIR" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
counter=1

# Use a NUL-delimited find loop so filenames with spaces / Chinese chars work.
# Skip already-processed/.DS_Store entries.
while IFS= read -r -d '' src; do
  base="$(basename "$src")"
  case "$base" in
    .DS_Store|*.processed.*) continue ;;
  esac

  src_w="$(/usr/bin/sips -g pixelWidth  "$src" 2>/dev/null | awk '/pixelWidth/  {print $2}')"
  src_h="$(/usr/bin/sips -g pixelHeight "$src" 2>/dev/null | awk '/pixelHeight/ {print $2}')"
  if [ -z "${src_w:-}" ] || [ -z "${src_h:-}" ]; then
    echo "  ⚠️  skipping $base (not an image?)"
    continue
  fi

  # Pick output target:
  #   • Source ≥ 2880 wide  → render at 2880×1800 (Retina, max quality)
  #   • Otherwise           → render at 1440×900  (downscale only, no upscale)
  if [ "$src_w" -ge 2880 ]; then
    out_w=2880; out_h=1800
  else
    out_w=1440; out_h=900
  fi

  # Compute 16:10 crop window (center). Whichever dimension is the
  # "tighter" one stays; the other gets cropped to match 16:10 = 1.6.
  #   ratio_src = src_w / src_h
  #   if ratio_src > 1.6 → image too wide → crop width to src_h * 1.6
  #   if ratio_src < 1.6 → image too tall → crop height to src_w / 1.6
  crop_w=$(awk -v w="$src_w" -v h="$src_h" 'BEGIN {
    r = w / h
    if (r > 1.6)      printf "%d", h * 1.6
    else              printf "%d", w
  }')
  crop_h=$(awk -v w="$src_w" -v h="$src_h" 'BEGIN {
    r = w / h
    if (r < 1.6)      printf "%d", w / 1.6
    else              printf "%d", h
  }')

  out_name="$(printf "%02d" "$counter")-$(echo "$base" | sed 's/\.[^.]*$//' ).png"
  out_path="$OUT_DIR/$out_name"
  tmp_path="$OUT_DIR/.tmp-$$.png"

  # 1) Center crop to 16:10 → 2) Resize to target. sips keeps PNG, no recompress
  #    artefacts, EXIF stripped automatically.
  /usr/bin/sips -c "$crop_h" "$crop_w" "$src" --out "$tmp_path" >/dev/null
  /usr/bin/sips --resampleHeightWidth "$out_h" "$out_w" "$tmp_path" --out "$out_path" >/dev/null
  rm -f "$tmp_path"

  out_size_kb=$(/usr/bin/du -k "$out_path" | awk '{print $1}')
  echo "  ✅ ${src_w}×${src_h}  →  ${out_w}×${out_h}  (${out_size_kb} KB)  $out_name"
  counter=$((counter + 1))
done < <(find "$IN_DIR" -maxdepth 1 -type f \( -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" \) -print0 | sort -z)

echo ""
echo "📁 Output: $OUT_DIR"
echo "📊 Total: $((counter - 1)) screenshots processed"

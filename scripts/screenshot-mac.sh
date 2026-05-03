#!/usr/bin/env bash
#
# Build PrimuseMac and launch it with a chosen language for App Store
# screenshots. Uses -AppleLanguages launch arguments which only affect this
# process — your system language stays untouched.
#
# Usage:
#   scripts/screenshot-mac.sh           # default: English
#   scripts/screenshot-mac.sh en        # English
#   scripts/screenshot-mac.sh zh-Hans   # Simplified Chinese
#   scripts/screenshot-mac.sh ja        # Japanese (falls back to English copy)
#
# Recommended screenshot dimensions for App Store:
#   - Minimum:     1280 × 800
#   - Recommended: 2880 × 1800 (Retina, looks sharpest in store listing)
# Press ⌘⇧4 → Space → click the window to grab a window-only screenshot.

set -euo pipefail

cd "$(dirname "$0")/.."

LANG_CODE="${1:-en-US}"

# Map common shorthands to BCP-47 codes that AppleLanguages understands.
case "$LANG_CODE" in
  en)         LANG_CODE="en-US" ;;
  zh|zh-CN)   LANG_CODE="zh-Hans" ;;
  ja|jp)      LANG_CODE="ja" ;;
esac

LOCALE_CODE="$(echo "$LANG_CODE" | tr '-' '_')"

DERIVED_DATA="build/screenshots"
# Mac target's PRODUCT_NAME is "PrimuseMac" — don't confuse with iOS "Primuse.app".
APP_PATH="$DERIVED_DATA/Build/Products/Debug/PrimuseMac.app"
LOG_FILE="/tmp/primuse-screenshot-build.log"

echo "🔨 Building PrimuseMac (Debug, isolated derived data)…"
xcodebuild \
  -project Primuse.xcodeproj \
  -scheme PrimuseMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  build > "$LOG_FILE" 2>&1

if [ ! -d "$APP_PATH" ]; then
  echo "❌ Build failed. Last 40 lines of log:" >&2
  tail -40 "$LOG_FILE" >&2
  exit 1
fi

# Kill any existing Primuse instance so the new one picks up our launch args.
pkill -x Primuse 2>/dev/null || true
sleep 1

SHOTS_DIR="build/screenshots/$LANG_CODE"
mkdir -p "$SHOTS_DIR"

echo ""
echo "🌐 Launching Primuse with locale: $LANG_CODE"
echo ""

open "$APP_PATH" --args -AppleLanguages "($LANG_CODE)" -AppleLocale "$LOCALE_CODE"

# Wait briefly for the app to come up and become the active window.
sleep 2

cat <<EOF
📸 Screenshot helper ready. Two modes — pick whichever you prefer:

  A) Manual:  press ⌘⇧4 then Space then click the Primuse window.
              Files land on your Desktop.

  B) Auto:    arrange Primuse the way you want, switch back to this terminal,
              and press [Enter]. The frontmost window is captured to:
              $SHOTS_DIR/<timestamp>.png

  Type 'q' + Enter (or Ctrl+C) to stop. Quit Primuse with ⌘Q when done.

EOF

# Resize Primuse window to 1440×909 logical points. The extra 9 points of
# height absorb SwiftUI's toolbar / title-bar offset, so the eventual
# screencapture lands at ≥ 2880×1800 — `normalize_to_app_store` then
# center-crops it down to exactly 2880×1800 (16:10).
resize_window() {
  /usr/bin/osascript <<'APPLESCRIPT' 2>/dev/null || true
tell application "System Events"
  tell process "PrimuseMac"
    if (count of windows) > 0 then
      set position of window 1 to {60, 60}
      set size of window 1 to {1440, 909}
    end if
  end tell
end tell
APPLESCRIPT
}

# Crop to 16:10 (centered) then resample to 2880×1800. Idempotent — a
# screenshot already at 2880×1800 is a no-op pass-through.
normalize_to_app_store() {
  local file="$1"
  local cur_w cur_h crop_w crop_h
  cur_w=$(/usr/bin/sips -g pixelWidth  "$file" 2>/dev/null | awk '/pixelWidth/  {print $2}')
  cur_h=$(/usr/bin/sips -g pixelHeight "$file" 2>/dev/null | awk '/pixelHeight/ {print $2}')
  [ -z "${cur_w:-}" ] && return

  # 16:10 = 1.6. Crop the longer dimension; keep the shorter one as-is.
  crop_w=$(awk -v w="$cur_w" -v h="$cur_h" 'BEGIN {
    if (w/h > 1.6) printf "%d", h * 1.6; else printf "%d", w
  }')
  crop_h=$(awk -v w="$cur_w" -v h="$cur_h" 'BEGIN {
    if (w/h < 1.6) printf "%d", w / 1.6; else printf "%d", h
  }')

  local tmp="${file}.tmp.png"
  /usr/bin/sips -c "$crop_h" "$crop_w" "$file" --out "$tmp" >/dev/null
  /usr/bin/sips --resampleHeightWidth 1800 2880 "$tmp" --out "$file" >/dev/null
  rm -f "$tmp"
}

# screencapture flags: -o = drop window shadow, -l <id> = grab a specific
# window by id, -i = interactive selection (drag a rectangle), -R = grab a
# fixed region.
counter=1
while true; do
  read -r -p "[Enter=auto window, r=resize only, s=select region (sheets/popovers), m=manual, q=quit] " input || break
  case "$input" in
    q) break ;;
    r) resize_window; echo "  📐 window set to 1440×909 (will normalize to 2880×1800)"; continue ;;
    s) capture_mode="select" ;;
    m) capture_mode="manual" ;;
    *) capture_mode="window" ;;
  esac

  if [ "$capture_mode" = "window" ]; then
    resize_window
    sleep 0.4   # let SwiftUI re-layout before grab
  fi

  TS="$(date +%H%M%S)"
  OUT="$SHOTS_DIR/shot-$(printf "%02d" "$counter")-$TS.png"

  case "$capture_mode" in
    window)
      WINDOW_ID="$(/usr/bin/osascript -e \
        'tell application "System Events" to tell process "PrimuseMac" to id of window 1' \
        2>/dev/null || true)"
      if [ -n "$WINDOW_ID" ]; then
        /usr/sbin/screencapture -o -l "$WINDOW_ID" "$OUT"
      else
        echo "  ⚠️  Primuse window not found — using interactive picker"
        /usr/sbin/screencapture -o -W "$OUT"
      fi
      ;;
    select)
      echo "  🎯 Drag a rectangle around the window + popover (Esc to abort)"
      /usr/sbin/screencapture -o -i "$OUT"
      ;;
    manual)
      /usr/sbin/screencapture -o -W "$OUT"
      ;;
  esac

  if [ ! -f "$OUT" ]; then
    echo "  ⚠️  capture aborted"
    continue
  fi

  PRE="$(/usr/bin/sips -g pixelWidth -g pixelHeight "$OUT" 2>/dev/null \
    | awk '/pixel(Width|Height)/ {print $2}' | paste -sd' x ' -)"
  normalize_to_app_store "$OUT"
  POST="$(/usr/bin/sips -g pixelWidth -g pixelHeight "$OUT" 2>/dev/null \
    | awk '/pixel(Width|Height)/ {print $2}' | paste -sd' x ' -)"

  if [ "$PRE" = "$POST" ]; then
    echo "  ✅ saved $OUT  ($POST)"
  else
    echo "  ✅ saved $OUT  ($PRE → $POST normalized)"
  fi
  counter=$((counter + 1))
done

echo ""
echo "📁 Screenshots saved to: $SHOTS_DIR"
ls -la "$SHOTS_DIR" 2>/dev/null | tail -n +2 | awk 'NR>1 {print "   " $NF}'

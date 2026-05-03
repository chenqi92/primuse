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
APP_PATH="$DERIVED_DATA/Build/Products/Debug/Primuse.app"
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

echo ""
echo "🌐 Launching Primuse with locale: $LANG_CODE"
echo "📸 Screenshot tips:"
echo "   • ⌘⇧4 then Space then click the window  → save to Desktop"
echo "   • Recommended size: 2880 × 1800 (or 1440 × 900 minimum)"
echo "   • App Store needs ≥1 mac screenshot per listing language"
echo "   • Quit with ⌘Q when done"
echo ""

open "$APP_PATH" --args -AppleLanguages "($LANG_CODE)" -AppleLocale "$LOCALE_CODE"

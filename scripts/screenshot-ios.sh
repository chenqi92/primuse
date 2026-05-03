#!/usr/bin/env bash
#
# Build PrimuseApp, install on a simulator, launch with chosen language,
# then capture App-Store-ready screenshots on demand.
#
# Default device is iPhone 17 Pro Max (1320×2868 — Apple's 6.9" master size).
# Override via $DEVICE env var or 2nd positional arg.
#
# Usage:
#   scripts/screenshot-ios.sh                          # English on iPhone 17 Pro Max
#   scripts/screenshot-ios.sh en                       # explicit English
#   scripts/screenshot-ios.sh zh-Hans                  # Simplified Chinese
#   scripts/screenshot-ios.sh en "iPad Pro 13-inch"    # 13" iPad shots

set -euo pipefail

cd "$(dirname "$0")/.."

LANG_CODE="${1:-en-US}"
DEVICE_NAME="${2:-${DEVICE:-iPhone 17 Pro Max}}"

case "$LANG_CODE" in
  en)         LANG_CODE="en-US" ;;
  zh|zh-CN)   LANG_CODE="zh-Hans" ;;
  ja|jp)      LANG_CODE="ja" ;;
esac
LOCALE_CODE="$(echo "$LANG_CODE" | tr '-' '_')"

BUNDLE_ID="com.welape.yuanyin"
DERIVED_DATA="build/screenshots-ios"
LOG_FILE="/tmp/primuse-ios-screenshot-build.log"
SHOTS_DIR="$DERIVED_DATA/$LANG_CODE"
mkdir -p "$SHOTS_DIR"

# ── 1. Pick the most recent runtime that hosts $DEVICE_NAME ────────────────
echo "🔍 Looking for '$DEVICE_NAME'…"
UDID="$(xcrun simctl list devices available --json | python3 -c "
import json, sys, re
data = json.load(sys.stdin)
target = '$DEVICE_NAME'
hits = []
for runtime, devices in data['devices'].items():
    if 'iOS' not in runtime: continue
    ver = re.search(r'iOS-(\d+)-(\d+)', runtime)
    ver_tuple = (int(ver.group(1)), int(ver.group(2))) if ver else (0, 0)
    for d in devices:
        if d['name'] == target:
            hits.append((ver_tuple, d['udid']))
hits.sort(reverse=True)
print(hits[0][1] if hits else '')
")"

if [ -z "$UDID" ]; then
  echo "❌ No simulator found for '$DEVICE_NAME'." >&2
  echo "   Available iPhones / iPads:" >&2
  xcrun simctl list devices available | grep -E "iPhone|iPad Pro" | sed 's/^/     /' >&2
  exit 1
fi
echo "  ✓ $DEVICE_NAME — $UDID"

# ── 2. Boot simulator + bring Simulator.app to front ──────────────────────
STATE="$(xcrun simctl list devices --json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data['devices'].items():
    for d in devices:
        if d['udid'] == '$UDID':
            print(d['state']); sys.exit(0)
")"

if [ "$STATE" != "Booted" ]; then
  echo "🚀 Booting simulator…"
  xcrun simctl boot "$UDID"
fi

open -a Simulator --args -CurrentDeviceUDID "$UDID"
echo "  ✓ simulator visible"

# Give SpringBoard a moment to come up cleanly before status-bar override.
sleep 2

# ── 3. Marketing-style status bar (9:41 / full battery / full bars) ────────
echo "📱 Applying marketing status bar override…"
xcrun simctl status_bar "$UDID" override \
  --time "9:41" \
  --dataNetwork wifi \
  --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 \
  --batteryState charged --batteryLevel 100 \
  >/dev/null 2>&1 || true

# ── 4. Build for the simulator + install ───────────────────────────────────
echo "🔨 Building Primuse for simulator (Debug)…"
xcodebuild \
  -project Primuse.xcodeproj \
  -scheme Primuse \
  -configuration Debug \
  -destination "id=$UDID" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build > "$LOG_FILE" 2>&1

APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Primuse.app"
if [ ! -d "$APP_PATH" ]; then
  echo "❌ Build failed. Last 40 lines of log:" >&2
  tail -40 "$LOG_FILE" >&2
  exit 1
fi

echo "📦 Installing Primuse.app on simulator…"
xcrun simctl install "$UDID" "$APP_PATH"

# ── 5. Launch with locale override (terminate any previous instance first) ─
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
echo "🌐 Launching Primuse with locale: $LANG_CODE"
xcrun simctl launch "$UDID" "$BUNDLE_ID" \
  -AppleLanguages "($LANG_CODE)" -AppleLocale "$LOCALE_CODE" >/dev/null

# ── 6. Screenshot loop ────────────────────────────────────────────────────
cat <<EOF

────────────────────────────────────────────────────────────────
📸 Screenshot helper ready.

  • Drive the simulator into the screen you want, then:
      Enter        → capture  (saves to $SHOTS_DIR/)
      r + Enter    → re-apply status bar override (if it expires)
      l + Enter    → re-launch app with $LANG_CODE locale
      q + Enter    → quit

  Output is the simulator's native resolution (matches Apple's master
  size for this device — no resizing needed).
────────────────────────────────────────────────────────────────

EOF

counter=1
while true; do
  read -r -p "[Enter=capture, r=status bar, l=relaunch, q=quit] " input || break
  case "$input" in
    q) break ;;
    r)
      xcrun simctl status_bar "$UDID" override \
        --time "9:41" --dataNetwork wifi \
        --wifiMode active --wifiBars 3 \
        --cellularMode active --cellularBars 4 \
        --batteryState charged --batteryLevel 100 \
        >/dev/null 2>&1
      echo "  📡 status bar refreshed"
      continue ;;
    l)
      xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
      xcrun simctl launch "$UDID" "$BUNDLE_ID" \
        -AppleLanguages "($LANG_CODE)" -AppleLocale "$LOCALE_CODE" >/dev/null
      echo "  🔄 relaunched with $LANG_CODE"
      continue ;;
  esac

  TS="$(date +%H%M%S)"
  OUT="$SHOTS_DIR/shot-$(printf "%02d" "$counter")-$TS.png"
  xcrun simctl io "$UDID" screenshot "$OUT" >/dev/null 2>&1

  if [ -f "$OUT" ]; then
    DIM="$(/usr/bin/sips -g pixelWidth -g pixelHeight "$OUT" 2>/dev/null \
      | awk '/pixel(Width|Height)/ {print $2}' | paste -sd' x ' -)"
    SIZE_KB="$(/usr/bin/du -k "$OUT" | awk '{print $1}')"
    echo "  ✅ saved $OUT  ($DIM, ${SIZE_KB} KB)"
    counter=$((counter + 1))
  else
    echo "  ⚠️  capture failed"
  fi
done

echo ""
echo "📁 Screenshots saved to: $SHOTS_DIR"
ls -la "$SHOTS_DIR"/*.png 2>/dev/null | awk '{print "   " $NF}'

# Tidy up the status-bar override so the simulator doesn't permanently
# pretend it's 9:41 next time you use it for development.
xcrun simctl status_bar "$UDID" clear >/dev/null 2>&1 || true

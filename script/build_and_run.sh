#!/bin/bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Primuse"
PROJECT="Primuse.xcodeproj"
SCHEME="PrimuseMac"
CONFIGURATION="${CONFIGURATION:-Debug}"
BUNDLE_ID="com.welape.yuanyin"
SCREENSHOT_SIZE="${SCREENSHOT_SIZE:-1280x800}"
APP_LANGUAGE="${APP_LANGUAGE:-}"
APP_LOCALE="${APP_LOCALE:-}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/build/CodexDerivedData"
BUILD_APP_BUNDLE="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
RUN_ROOT="${PRIMUSE_RUN_ROOT:-/tmp/primuse-codex-run}"
APP_BUNDLE="$RUN_ROOT/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
PACKAGE_RPATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/PackageFrameworks"
FIX_DEBUG_RUNPATHS="${FIX_DEBUG_RUNPATHS:-0}"

cd "$ROOT_DIR"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
for _ in {1..50}; do
  if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
pkill -9 -x "$APP_NAME" >/dev/null 2>&1 || true

xcodebuild \
  -quiet \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  build

stage_app_bundle() {
  rm -rf "$RUN_ROOT"
  mkdir -p "$RUN_ROOT"
  ditto "$BUILD_APP_BUNDLE" "$APP_BUNDLE"
}

fix_debug_runpaths() {
  local changed=0
  local sign_identity="${CODE_SIGN_IDENTITY_OVERRIDE:-}"

  while IFS= read -r binary; do
    if ! file "$binary" | grep -q "Mach-O"; then
      continue
    fi
    if otool -l "$binary" | grep -Fq "$PACKAGE_RPATH"; then
      install_name_tool -delete_rpath "$PACKAGE_RPATH" "$binary"
      changed=1
    fi
  done < <(find "$APP_BUNDLE/Contents/MacOS" \
                 "$APP_BUNDLE/Contents/Frameworks" \
                 "$APP_BUNDLE/Contents/PlugIns" \
                 -type f -perm -111 2>/dev/null)

  if [[ "$changed" -eq 0 ]]; then
    return
  fi

  if [[ -z "$sign_identity" ]]; then
    sign_identity="$(codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 \
      | awk -F= '/^Authority=Apple Development/ && !found { print $2; found=1 }')"
  fi
  if [[ -z "$sign_identity" ]]; then
    sign_identity="-"
  fi

  if [[ -d "$APP_BUNDLE/Contents/Frameworks" ]]; then
    while IFS= read -r -d "" item; do
      codesign --force --sign "$sign_identity" \
        --preserve-metadata=entitlements,requirements,flags \
        --timestamp=none \
        "$item"
    done < <(find "$APP_BUNDLE/Contents/Frameworks" -maxdepth 1 -name "*.framework" -print0)
  fi

  if [[ -d "$APP_BUNDLE/Contents/PlugIns" ]]; then
    while IFS= read -r -d "" item; do
      codesign --force --sign "$sign_identity" \
        --preserve-metadata=entitlements,requirements,flags \
        --timestamp=none \
        "$item"
    done < <(find "$APP_BUNDLE/Contents/PlugIns" -maxdepth 1 -name "*.appex" -print0)
  fi

  codesign --force --sign "$sign_identity" \
    --preserve-metadata=entitlements,requirements,flags \
    --timestamp=none \
    "$APP_BUNDLE"
}

stage_app_bundle
if [[ "$FIX_DEBUG_RUNPATHS" == "1" ]]; then
  fix_debug_runpaths
fi

language_args=()
if [[ -n "$APP_LANGUAGE" ]]; then
  language_args+=("-AppleLanguages" "($APP_LANGUAGE)")
fi
if [[ -n "$APP_LOCALE" ]]; then
  language_args+=("-AppleLocale" "$APP_LOCALE")
fi

open_bundle_with_args() {
  if [[ "$#" -gt 0 ]]; then
    /usr/bin/open -n "$APP_BUNDLE" --args "$@"
  else
    /usr/bin/open -n "$APP_BUNDLE"
  fi
}

open_app() {
  if [[ "${#language_args[@]}" -gt 0 ]]; then
    open_bundle_with_args "${language_args[@]}"
  else
    open_bundle_with_args
  fi
}

open_screenshot_app() {
  if [[ "${#language_args[@]}" -gt 0 ]]; then
    open_bundle_with_args "${language_args[@]}" "--primuse-screenshot-window=$SCREENSHOT_SIZE"
  else
    open_bundle_with_args "--primuse-screenshot-window=$SCREENSHOT_SIZE"
  fi
}

wait_for_app_ready() {
  local pid=""
  for _ in {1..90}; do
    pid="$(pgrep -f "$APP_BINARY" | head -n 1 || true)"
    if [[ -n "$pid" ]] && lsof -p "$pid" 2>/dev/null \
      | grep -Fq "$APP_BUNDLE/Contents/Frameworks/PrimuseKit.framework"; then
      return 0
    fi
    sleep 1
  done

  if [[ -n "$pid" ]]; then
    echo "$APP_NAME started but did not finish loading frameworks within 90s (pid $pid)." >&2
  else
    echo "$APP_NAME did not start within 90s." >&2
  fi
  return 1
}

case "$MODE" in
  run)
    open_app
    ;;
  --screenshot|screenshot)
    open_screenshot_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    wait_for_app_ready
    ;;
  *)
    echo "usage: $0 [run|--screenshot|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

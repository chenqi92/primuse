#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "Brand check failed: $*" >&2
  exit 1
}

# The official names are 猿音 in Chinese storefront/UI copy and Primuse in
# international/product identifiers. These visually similar typos previously
# leaked into generated App Store copy, so scan ignored local release docs too.
tracked_hits="$(git grep -n -E '猫音|貓音' -- . ':(exclude)scripts/check-branding.sh' || true)"
if [[ -n "$tracked_hits" ]]; then
  echo "$tracked_hits" >&2
  fail "found forbidden 猫音/貓音 spelling in tracked files"
fi

if command -v rg >/dev/null 2>&1; then
  workspace_hits="$(rg -n -S '猫音|貓音' "$REPO_ROOT" \
    --hidden --no-ignore \
    --glob '*.{md,markdown,txt,swift,plist,strings,xcstrings,html,htm,jsx,tsx,js,ts,json,yml,yaml,sh,xcconfig,pbxproj}' \
    --glob '!.git/**' \
    --glob '!build/**' \
    --glob '!build_device/**' \
    --glob '!.playwright-cli/**' \
    --glob '!.codex-logs/**' \
    --glob '!.codex-tmp/**' \
    --glob '!scripts/check-branding.sh' || true)"
  if [[ -n "$workspace_hits" ]]; then
    echo "$workspace_hits" >&2
    fail "found forbidden 猫音/貓音 spelling in the workspace"
  fi
fi

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

expect_plist_value() {
  local file="$1"
  local key="$2"
  local expected="$3"
  local actual
  actual="$(plist_value "$file" "$key")"
  [[ "$actual" == "$expected" ]] || fail "$file $key expected '$expected', got '$actual'"
}

expect_plist_value Primuse/Info.plist CFBundleDisplayName 猿音
expect_plist_value Primuse/Info.plist CFBundleName Primuse
expect_plist_value Primuse/Info-macOS.plist CFBundleDisplayName Primuse
expect_plist_value PrimuseTV/Info.plist CFBundleDisplayName Primuse
expect_plist_value PrimuseWatch/Info.plist CFBundleDisplayName 猿音
expect_plist_value PrimuseWidgetExtension/Info.plist CFBundleDisplayName 猿音小组件
expect_plist_value PrimuseWatchWidgets/Info.plist CFBundleDisplayName 猿音表盘

grep -Fqx '# Primuse（猿音）' README.md || fail "README.md must use the official Chinese name 猿音"

echo "Brand check passed: 猿音 / Primuse"

#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "Brand check failed: $*" >&2
  exit 1
}

# Primuse is the product name everywhere, including Chinese copy. 猿音 stays
# registered as an alternative app name so Siri and long-time users can still
# reach the app by the old name, and README keeps it as a searchable alias.
# The 猫音/貓音 typos previously leaked into generated App Store copy, so scan
# ignored local release docs too.
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

# 备用名称是数组，PlistBuddy 逐项打印，这里只确认目标名字在其中。
expect_alternative_app_name() {
  local file="$1"
  local expected="$2"
  local index=0
  while :; do
    local value
    value="$(plist_value "$file" "INAlternativeAppNames:$index:INAlternativeAppName")" || break
    [[ -n "$value" ]] || break
    [[ "$value" == "$expected" ]] && return 0
    index=$((index + 1))
  done
  fail "$file must list '$expected' in INAlternativeAppNames"
}

expect_plist_value() {
  local file="$1"
  local key="$2"
  local expected="$3"
  local actual
  actual="$(plist_value "$file" "$key")"
  [[ "$actual" == "$expected" ]] || fail "$file $key expected '$expected', got '$actual'"
}

expect_plist_value Primuse/Info.plist CFBundleDisplayName Primuse
expect_plist_value Primuse/Info.plist CFBundleName Primuse
expect_plist_value Primuse/Info-macOS.plist CFBundleDisplayName Primuse
expect_plist_value PrimuseTV/Info.plist CFBundleDisplayName Primuse
expect_plist_value PrimuseWatch/Info.plist CFBundleDisplayName Primuse
expect_plist_value PrimuseWidgetExtension/Info.plist CFBundleDisplayName 'Primuse 小组件'
expect_plist_value PrimuseWatchWidgets/Info.plist CFBundleDisplayName 'Primuse 表盘'

# 旧名必须继续能唤起 app，否则老用户对 Siri 说「用猿音播放」会落空。
expect_alternative_app_name Primuse/Info.plist 猿音
expect_alternative_app_name PrimuseWatch/Info.plist 猿音

grep -Fqx '# Primuse（猿音）' README.md || fail "README.md must keep 猿音 as a searchable alias"

echo "Brand check passed: Primuse (alias 猿音)"

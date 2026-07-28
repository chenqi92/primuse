#!/usr/bin/env bash

set -euo pipefail

fail() {
  echo "Apple signing preflight failed: $*" >&2
  exit 1
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  fail "this check must run on macOS"
fi

identity_pattern="${SIGNING_IDENTITY_PATTERN:-Apple Development:}"
keychain_path="${SIGNING_KEYCHAIN_PATH:-${HOME}/Library/Keychains/login.keychain-db}"

[[ -f "$keychain_path" ]] || fail "keychain not found: $keychain_path"

search_list="$({ security list-keychains -d user || true; } \
  | sed -E 's/^[[:space:]]*"?//; s/"?[[:space:]]*$//')"
if ! grep -Fqx "$keychain_path" <<<"$search_list"; then
  fail "keychain is not in the user search list: $keychain_path"
fi

identity_line="$(security find-identity -v -p codesigning "$keychain_path" \
  | grep -F "\"$identity_pattern" \
  | head -n 1 || true)"
[[ -n "$identity_line" ]] || fail "no valid '$identity_pattern' identity in $keychain_path"

identity_hash="$(sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-F]{40}).*/\1/' <<<"$identity_line")"
[[ "$identity_hash" =~ ^[0-9A-F]{40}$ ]] || fail "could not parse the signing identity hash"

identity_name="$(sed -E 's/^[^"]*"([^"]+)".*/\1/' <<<"$identity_line")"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/primuse-signing-preflight.XXXXXX")"
cleanup() {
  rm -rf -- "$probe_dir"
}
trap cleanup EXIT

probe="$probe_dir/primuse-signing-probe"
cp /usr/bin/true "$probe"

sign_output=""
if ! sign_output="$(/usr/bin/codesign --force --sign "$identity_hash" --timestamp=none "$probe" 2>&1)"; then
  [[ -n "$sign_output" ]] && echo "$sign_output" >&2
  fail "identity '$identity_name' exists, but its private key is unavailable to /usr/bin/codesign. Unlock the login keychain and authorize codesign before building for a physical device."
fi

/usr/bin/codesign --verify --strict "$probe" \
  || fail "the disposable signing probe could not be verified"

echo "Apple signing preflight passed: $identity_name"

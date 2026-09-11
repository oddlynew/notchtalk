#!/usr/bin/env bash
set -euo pipefail
# Usage: build_keychain_helper.sh OUTPUT_DIRECTORY EXISTING_INSTALLED_DIRECTORY
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="$1"
EXISTING="${2:-/Applications/notchtalk.app/Contents/MacOS}"
IDENTITY="${NOTCHTALK_SIGNING_IDENTITY:-NotchTalk Local Development}"
IDENTITY_HASH="$(security find-identity -p codesigning | awk -v identity="$IDENTITY" 'index($0, identity) && $2 ~ /^[0-9A-Fa-f]+$/ { print $2; exit }')"
if [[ ${#IDENTITY_HASH} != 40 ]]; then
  echo "Missing or invalid NotchTalk signing identity." >&2
  exit 1
fi
REQUIREMENT="identifier \"oddlynew.notchtalk.keychain\" and certificate leaf = H\"$IDENTITY_HASH\""
FINGERPRINT="$( { cat "$ROOT_DIR/keychain-helper/main.swift" "$ROOT_DIR/notchtalk/KeychainBridge.swift"; printf '%s' "$IDENTITY_HASH"; uname -m; } | shasum -a 256 | awk '{print $1}')"
CACHE="$ROOT_DIR/.build/keychain-helper/$FINGERPRINT"
BINARY="NotchTalkKeychain"
MARKER="NotchTalkKeychain.source"
valid() { codesign --verify --strict -R "=$REQUIREMENT" "$1" >/dev/null 2>&1; }
mkdir -p "$CACHE" "$DESTINATION" "$DESTINATION/../Resources"
if [[ -f "$CACHE/$BINARY" ]] && valid "$CACHE/$BINARY"; then
  :
elif [[ -f "$EXISTING/../Resources/$MARKER" ]] && [[ "$(cat "$EXISTING/../Resources/$MARKER")" == "$FINGERPRINT" ]] && valid "$EXISTING/$BINARY"; then
  cp "$EXISTING/$BINARY" "$CACHE/$BINARY"
else
  echo "Building credential helper; its next credential access may require one approval."
  swiftc -O -whole-module-optimization -suppress-warnings \
    -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$ROOT_DIR/.build/manual/module-cache" \
    "$ROOT_DIR/notchtalk/KeychainBridge.swift" "$ROOT_DIR/keychain-helper/main.swift" \
    -o "$CACHE/$BINARY"
  codesign --force --options runtime --timestamp=none --sign "$IDENTITY_HASH" \
    --identifier oddlynew.notchtalk.keychain "$CACHE/$BINARY"
fi
valid "$CACHE/$BINARY"
cp "$CACHE/$BINARY" "$DESTINATION/$BINARY"
printf '%s\n' "$FINGERPRINT" > "$DESTINATION/../Resources/$MARKER"

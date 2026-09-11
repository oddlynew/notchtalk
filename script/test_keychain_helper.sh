#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDENTITY="${NOTCHTALK_SIGNING_IDENTITY:-NotchTalk Local Development}"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/notchtalk-helper-test.XXXXXX")"
cleanup() {
  if [[ -f "$TEST_DIR/fixture.keychain-db" && -x "$TEST_DIR/Client" ]]; then
    "$TEST_DIR/Client" cleanup "$TEST_DIR/fixture.keychain-db" "$TEST_DIR/Helper"
  fi
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT
mkdir -p "$ROOT/.build/manual/module-cache"
compile() { swiftc -O -suppress-warnings -module-cache-path "$ROOT/.build/manual/module-cache" "$@"; }
sign() { codesign --force --options runtime --timestamp=none -s "$IDENTITY" --identifier "$1" "$2"; }
run() {
  python3 - "$@" <<'PY'
import subprocess, sys
subprocess.run(sys.argv[1:], check=True, timeout=15)
PY
}
compile -D KEYCHAIN_BRIDGE_TEST "$ROOT/notchtalk/KeychainBridge.swift" "$ROOT/keychain-helper/main.swift" -o "$TEST_DIR/Helper"
sign oddlynew.notchtalk.keychain "$TEST_DIR/Helper"
compile "$ROOT/notchtalk/KeychainBridge.swift" "$ROOT/script/fixtures/KeychainHelperClient.swift" -o "$TEST_DIR/Client"
sign oddlynew.notchtalk "$TEST_DIR/Client"
run "$TEST_DIR/Client" setup "$TEST_DIR/fixture.keychain-db" "$TEST_DIR/Helper"
FIRST_HASH="$(shasum -a 256 "$TEST_DIR/Client" | awk '{print $1}')"
HELPER_HASH="$(shasum -a 256 "$TEST_DIR/Helper" | awk '{print $1}')"
compile -D SECOND_BUILD "$ROOT/notchtalk/KeychainBridge.swift" "$ROOT/script/fixtures/KeychainHelperClient.swift" -o "$TEST_DIR/Next"
sign oddlynew.notchtalk "$TEST_DIR/Next"
[[ "$(shasum -a 256 "$TEST_DIR/Next" | awk '{print $1}')" != "$FIRST_HASH" ]]
mv "$TEST_DIR/Next" "$TEST_DIR/Client"
run "$TEST_DIR/Client" read "$TEST_DIR/fixture.keychain-db" "$TEST_DIR/Helper"
[[ "$(shasum -a 256 "$TEST_DIR/Helper" | awk '{print $1}')" == "$HELPER_HASH" ]]
cp "$TEST_DIR/Client" "$TEST_DIR/WrongClient"
sign oddlynew.unrelated "$TEST_DIR/WrongClient"
run "$TEST_DIR/WrongClient" denied "$TEST_DIR/fixture.keychain-db" "$TEST_DIR/Helper"

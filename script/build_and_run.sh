#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="notchtalk"
BUNDLE_ID="oddlynew.notchtalk"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/manual"
MODULE_CACHE_DIR="$BUILD_DIR/module-cache"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
INSTALLED_APP_BUNDLE="/Applications/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

mkdir -p "$BUILD_DIR" "$MODULE_CACHE_DIR"
SDK_PATH="$(xcrun --show-sdk-path)"

SWIFT_SOURCES=()
while IFS= read -r source; do
  SWIFT_SOURCES+=("$source")
done < <(find "$ROOT_DIR/notchtalk" -name '*.swift' | sort)

swiftc \
  -target "$(uname -m)-apple-macosx$MIN_SYSTEM_VERSION" \
  -sdk "$SDK_PATH" \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -o "$BUILD_DIR/$APP_NAME" \
  "${SWIFT_SOURCES[@]}" \
  -framework AppKit \
  -framework AVFoundation \
  -framework Carbon \
  -framework CoreAudio \
  -framework Security \
  -framework SwiftUI \
  -framework UniformTypeIdentifiers

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
cp "$BUILD_DIR/$APP_NAME" "$APP_BINARY"
chmod +x "$APP_BINARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Notchtalk needs microphone access to record audio for transcription.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

xattr -cr "$APP_BUNDLE"
codesign \
  --force \
  --deep \
  --sign - \
  --requirements "=designated => identifier \"$BUNDLE_ID\"" \
  "$APP_BUNDLE" >/dev/null

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
rm -rf "$INSTALLED_APP_BUNDLE"
cp -R "$APP_BUNDLE" "$INSTALLED_APP_BUNDLE"
xattr -cr "$INSTALLED_APP_BUNDLE"
codesign \
  --force \
  --deep \
  --sign - \
  --requirements "=designated => identifier \"$BUNDLE_ID\"" \
  "$INSTALLED_APP_BUNDLE" >/dev/null
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$INSTALLED_APP_BUNDLE" >/dev/null 2>&1 || true

open_app() {
  /usr/bin/open -n "$INSTALLED_APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$INSTALLED_APP_BUNDLE/Contents/MacOS/$APP_NAME"
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
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

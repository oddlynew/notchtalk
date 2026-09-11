#!/usr/bin/env bash
set -euo pipefail
SOURCE="$SRCROOT/dist/notchtalk.app/Contents/MacOS/NotchTalkKeychain"
DESTINATION="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/NotchTalkKeychain"
if [[ ! -f "$SOURCE" || -z "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  echo 'Build the helper first: NOTCHTALK_SIGNING_IDENTITY=<Xcode identity> ./script/build_and_run.sh --build-only' >&2
  exit 1
fi
codesign --verify --strict -R "=identifier \"oddlynew.notchtalk.keychain\" and certificate leaf = H\"$EXPANDED_CODE_SIGN_IDENTITY\"" "$SOURCE"
mkdir -p "$(dirname "$DESTINATION")" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
cp "$SOURCE" "$DESTINATION"
cp "$SRCROOT/dist/notchtalk.app/Contents/Resources/NotchTalkKeychain.source" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/NotchTalkKeychain.source"

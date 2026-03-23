#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT/build}"
CLONED_SOURCE_PACKAGES_DIR_PATH="${CLONED_SOURCE_PACKAGES_DIR_PATH:-$ROOT/.spm-cache}"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
APP_NAME="ClawKeep.app"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/$BUILD_CONFIGURATION/$APP_NAME"
ZIP_PATH="$DIST_DIR/ClawKeep-macos-$BUILD_CONFIGURATION-unsigned.zip"
DMG_PATH="$DIST_DIR/ClawKeep-macos-$BUILD_CONFIGURATION-unsigned.dmg"
KEEPD_PATH="$APP_PATH/Contents/Resources/keepd"
CONFIG_PATH="$APP_PATH/Contents/Resources/config.example.toml"
INSTALLER_HELPER_PATH="$APP_PATH/Contents/Resources/install-update.sh"

mkdir -p "$DIST_DIR"

BUILD_CONFIGURATION="$BUILD_CONFIGURATION" \
DERIVED_DATA_PATH="$DERIVED_DATA_PATH" \
CLONED_SOURCE_PACKAGES_DIR_PATH="$CLONED_SOURCE_PACKAGES_DIR_PATH" \
"$ROOT/scripts/build.sh"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

mkdir -p "$APP_PATH/Contents/Resources"
cp "$ROOT/keepd/keepd" "$KEEPD_PATH"
chmod +x "$KEEPD_PATH"
cp "$ROOT/config.example.toml" "$CONFIG_PATH"
cp "$ROOT/scripts/install-update.sh" "$INSTALLER_HELPER_PATH"
chmod +x "$INSTALLER_HELPER_PATH"

# Re-sign nested helper and bundle after copying resources so macOS
# can launch the embedded daemon from the packaged app.
codesign --force --sign - "$KEEPD_PATH"
codesign --force --deep --sign - "$APP_PATH"

rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

if ! command -v hdiutil >/dev/null 2>&1; then
  echo "hdiutil is required to produce the DMG package" >&2
  exit 1
fi

DMG_STAGING_DIR="$(mktemp -d "$DIST_DIR/dmg-staging.XXXXXX")"
cleanup() {
  rm -rf "$DMG_STAGING_DIR"
}
trap cleanup EXIT

ditto "$APP_PATH" "$DMG_STAGING_DIR/$APP_NAME"
ln -s /Applications "$DMG_STAGING_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "ClawKeep" \
  -srcfolder "$DMG_STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "Unsigned app: $APP_PATH"
echo "Unsigned zip: $ZIP_PATH"
echo "Unsigned dmg: $DMG_PATH"

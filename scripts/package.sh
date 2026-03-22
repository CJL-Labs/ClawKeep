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

echo "Unsigned app: $APP_PATH"
echo "Unsigned zip: $ZIP_PATH"

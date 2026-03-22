#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT/build}"
CLONED_SOURCE_PACKAGES_DIR_PATH="${CLONED_SOURCE_PACKAGES_DIR_PATH:-$ROOT/.spm-cache}"
APP_VERSION="${APP_VERSION:-$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"

if [[ -z "$APP_VERSION" ]]; then
  APP_VERSION="0.1.0"
fi

cd "$ROOT/keepd"
go build -o keepd ./cmd/keepd

cd "$ROOT/app"
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate
elif [[ ! -d "$ROOT/app/ClawKeep.xcodeproj" ]]; then
  echo "xcodegen is required because app/ClawKeep.xcodeproj is missing" >&2
  exit 1
fi

if command -v xcodebuild >/dev/null 2>&1; then
  mkdir -p "$CLONED_SOURCE_PACKAGES_DIR_PATH"
  xcodebuild \
    -project ClawKeep.xcodeproj \
    -scheme ClawKeep \
    -configuration "$BUILD_CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -clonedSourcePackagesDirPath "$CLONED_SOURCE_PACKAGES_DIR_PATH" \
    MARKETING_VERSION="$APP_VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    build
else
  echo "xcodebuild is required to produce the macOS app bundle" >&2
  exit 1
fi

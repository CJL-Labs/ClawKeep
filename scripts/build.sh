#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT/build}"
CLONED_SOURCE_PACKAGES_DIR_PATH="${CLONED_SOURCE_PACKAGES_DIR_PATH:-$ROOT/.spm-cache}"
SKIP_PROTO="${SKIP_PROTO:-1}"

if [[ "$SKIP_PROTO" != "1" ]]; then
  "$ROOT/scripts/gen-proto.sh"
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
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    build
else
  echo "xcodebuild is required to produce the macOS app bundle" >&2
  exit 1
fi

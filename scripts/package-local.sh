#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-Debug}" \
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT/build}" \
CLONED_SOURCE_PACKAGES_DIR_PATH="${CLONED_SOURCE_PACKAGES_DIR_PATH:-$ROOT/.spm-cache}" \
DIST_DIR="${DIST_DIR:-$ROOT/dist}" \
SKIP_PROTO="${SKIP_PROTO:-1}" \
"$ROOT/scripts/package.sh"

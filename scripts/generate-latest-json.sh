#!/usr/bin/env bash
set -euo pipefail

ZIP_PATH="${ZIP_PATH:?missing ZIP_PATH}"
OUTPUT_PATH="${OUTPUT_PATH:?missing OUTPUT_PATH}"
VERSION="${VERSION:?missing VERSION}"
DOWNLOAD_URL="${DOWNLOAD_URL:?missing DOWNLOAD_URL}"
RELEASE_PAGE="${RELEASE_PAGE:?missing RELEASE_PAGE}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
PUBLISHED_AT="${PUBLISHED_AT:-}"

if command -v sha256sum >/dev/null 2>&1; then
  SHA256="$(sha256sum "$ZIP_PATH" | awk '{print $1}')"
else
  SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"

{
  printf '{\n'
  printf '  "version": "%s",\n' "$VERSION"
  if [[ -n "$BUILD_NUMBER" ]]; then
    printf '  "build": %s,\n' "$BUILD_NUMBER"
  else
    printf '  "build": null,\n'
  fi
  if [[ -n "$PUBLISHED_AT" ]]; then
    printf '  "published_at": "%s",\n' "$PUBLISHED_AT"
  else
    printf '  "published_at": null,\n'
  fi
  printf '  "url": "%s",\n' "$DOWNLOAD_URL"
  printf '  "sha256": "%s",\n' "$SHA256"
  printf '  "release_page": "%s"\n' "$RELEASE_PAGE"
  printf '}\n'
} >"$OUTPUT_PATH"

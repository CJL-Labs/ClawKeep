#!/usr/bin/env bash
set -euo pipefail

APP_PID="${1:?missing app pid}"
SOURCE_APP="${2:?missing source app}"
TARGET_APP="${3:?missing target app}"
TARGET_DIR="$(dirname "$TARGET_APP")"
BACKUP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/clawkeep-update.XXXXXX")"
BACKUP_APP="$BACKUP_ROOT/$(basename "$TARGET_APP")"

cleanup() {
  rm -rf "$BACKUP_ROOT"
}

rollback() {
  if [[ -d "$BACKUP_APP" ]]; then
    rm -rf "$TARGET_APP"
    mv "$BACKUP_APP" "$TARGET_APP"
  fi
}

trap cleanup EXIT

for _ in $(seq 1 240); do
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    break
  fi
  sleep 0.25
done

if kill -0 "$APP_PID" 2>/dev/null; then
  echo "Timed out waiting for ClawKeep to exit." >&2
  exit 1
fi

mkdir -p "$TARGET_DIR"

if [[ -d "$TARGET_APP" ]]; then
  mv "$TARGET_APP" "$BACKUP_APP"
fi

if ! /usr/bin/ditto "$SOURCE_APP" "$TARGET_APP"; then
  rollback
  echo "Failed to copy the new app bundle into place." >&2
  exit 1
fi

/usr/bin/xattr -dr com.apple.quarantine "$TARGET_APP" >/dev/null 2>&1 || true
rm -rf "$BACKUP_APP"
/usr/bin/open "$TARGET_APP"

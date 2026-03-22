#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> Stopping old processes..."
pkill -9 -f ClawKeep 2>/dev/null || true
pkill -9 -f keepd 2>/dev/null || true
sleep 1

echo "==> Cleaning caches..."
rm -rf "$ROOT/build"
rm -f "$ROOT/keepd/keepd"
rm -f ~/.claw-keep/bin/keepd

echo "==> Building & packaging..."
bash "$ROOT/scripts/package-local.sh"

echo "==> Launching..."
open "$ROOT/build/Build/Products/Debug/ClawKeep.app"

echo "Done."

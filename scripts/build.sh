#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

"$ROOT/scripts/gen-proto.sh"

cd "$ROOT/keepd"
go build -o keepd ./cmd/keepd

cd "$ROOT/app"
xcodegen generate
if xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
  xcodebuild -project ClawKeep.xcodeproj -scheme ClawKeep -configuration Debug build
else
  swift build
fi

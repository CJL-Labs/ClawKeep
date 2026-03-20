#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROTO_ROOT="$ROOT"
GO_OUT="$ROOT/keepd/gen"
SWIFT_OUT="$ROOT/app/ClawKeep/Gen"

mkdir -p "$GO_OUT" "$SWIFT_OUT"

protoc \
  -I "$PROTO_ROOT" \
  --plugin=protoc-gen-grpc-swift=/opt/homebrew/bin/protoc-gen-grpc-swift-2 \
  --go_out="$GO_OUT" \
  --go_opt=paths=source_relative \
  --go-grpc_out="$GO_OUT" \
  --go-grpc_opt=paths=source_relative \
  --swift_out="$SWIFT_OUT" \
  --swift_opt=Visibility=Public \
  --grpc-swift_out="$SWIFT_OUT" \
  --grpc-swift_opt=Visibility=Public,Client=true,Server=false \
  "$ROOT"/proto/keep/v1/*.proto

ROOT_FOR_PY="$ROOT" python3 - <<'PY'
import os
from pathlib import Path

root = Path(os.environ["ROOT_FOR_PY"])
path = root / "app/ClawKeep/Gen/proto/keep/v1/keep.grpc.swift"
content = path.read_text()
content = content.replace(',\n                type: .unary', '')
content = content.replace(',\n                type: .serverStreaming', '')
path.write_text(content)
PY

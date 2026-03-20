#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

"$ROOT/scripts/build.sh"

echo "Packaging is not yet wired to signing identities. Use Xcode on a machine with full Xcode installed for signed .app packaging."

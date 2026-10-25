#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-thumbnail-store.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
CANONICAL="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$CHECK_DIR")"
xcrun clang++ -std=c++20 -fobjc-arc -fblocks -Wall -Wextra -Werror \
  -I "$ROOT/Modules/MediaCore/Bridge" "$ROOT/Scripts/tests/persistent_thumbnail_store.mm" \
  -framework Foundation -framework ImageIO -framework CoreGraphics -o "$CHECK_DIR/checks"
"$CHECK_DIR/checks" "$CANONICAL"

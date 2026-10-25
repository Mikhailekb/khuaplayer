#!/bin/bash
# Exercise production picture controls on native Metal without opening a player.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
  echo "SKIP: picture adjustment checks require macOS and a Metal device." >&2
  exit 77
fi
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-picture-adjust.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun clang++ -std=c++20 -O2 -fobjc-arc -fblocks -mmacosx-version-min=14.0 \
  "$ROOT/Scripts/tests/picture_adjust.mm" -framework Foundation -framework Metal \
  -o "$CHECK_DIR/picture-adjust-checks"
"$CHECK_DIR/picture-adjust-checks" "$ROOT/Modules/MediaCore/Shaders/Video.metal"

#!/bin/bash
# Exercise the production HDR viewing-preset shader on a native Metal device.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
  echo "SKIP: HDR shadow-lift checks require macOS and a Metal device." >&2
  exit 77
fi
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/khua-hdr-shadow-lift.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

xcrun clang++ -std=c++20 -O2 -fobjc-arc -fblocks \
  -mmacosx-version-min=14.0 \
  "$ROOT/Scripts/tests/hdr_shadow_lift.mm" \
  -framework Foundation -framework Metal \
  -o "$CHECK_DIR/hdr-shadow-lift-checks"
"$CHECK_DIR/hdr-shadow-lift-checks" "$ROOT/Modules/MediaCore/Shaders/Video.metal"

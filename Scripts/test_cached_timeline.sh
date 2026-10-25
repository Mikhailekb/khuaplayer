#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-cached-timeline.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun clang++ -std=c++17 -Wall -Wextra -Werror \
  -I "$ROOT/Modules/MediaCore/Core" \
  "$ROOT/Scripts/tests/cached_timeline.cpp" -o "$CHECK_DIR/checks"
"$CHECK_DIR/checks"

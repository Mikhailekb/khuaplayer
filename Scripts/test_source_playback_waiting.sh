#!/bin/bash
# Check source waits and their explanations without media, networking or UI.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-source-waiting.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

xcrun clang++ -std=c++17 -Wall -Wextra -Werror \
  -I "$ROOT/Modules/MediaCore/Core" \
  "$ROOT/Scripts/tests/source_playback_waiting.cpp" \
  -o "$CHECK_DIR/source-waiting-checks"
"$CHECK_DIR/source-waiting-checks"

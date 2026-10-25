#!/bin/bash
# Check video single/double-click arbitration without launching the player.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-video-click.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

xcrun swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Apps/Mac/UI/VideoClickGesture.swift" \
  "$ROOT/Scripts/tests/video_click_gesture.swift" \
  -o "$CHECK_DIR/video-click-checks"
"$CHECK_DIR/video-click-checks"

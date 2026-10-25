#!/bin/bash
# Test owned hidden AppKit windows; never launch or control the user player.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-floating-video.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Apps/Mac/UI/Localization.swift" \
  "$ROOT/Apps/Mac/UI/FloatingVideoController.swift" \
  "$ROOT/Scripts/tests/floating_video.swift" \
  -o "$CHECK_DIR/floating-video-checks"
"$CHECK_DIR/floating-video-checks"

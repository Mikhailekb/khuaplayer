#!/bin/bash
# Exercise the menu model and target routing without presenting user interface.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-video-context-menu.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Apps/Mac/UI/Localization.swift" \
  "$ROOT/Apps/Mac/UI/VideoContextMenu.swift" \
  "$ROOT/Scripts/tests/video_context_menu.swift" \
  -o "$CHECK_DIR/video-context-menu-checks"
"$CHECK_DIR/video-context-menu-checks"

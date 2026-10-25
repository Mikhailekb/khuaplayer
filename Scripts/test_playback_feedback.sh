#!/bin/bash
# Exercise the actual AppKit feedback view without opening or controlling a player.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-playback-feedback.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

xcrun swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Apps/Mac/UI/PlaybackFeedbackView.swift" \
  "$ROOT/Scripts/tests/playback_feedback.swift" \
  -o "$CHECK_DIR/playback-feedback-checks"
"$CHECK_DIR/playback-feedback-checks" "$@"

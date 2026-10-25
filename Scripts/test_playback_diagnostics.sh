#!/bin/bash
# Exercise the private numerical logger only in an owned temporary directory.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-playback-diagnostics.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  "$ROOT/Apps/Mac/UI/PlaybackDiagnostics.swift" \
  "$ROOT/Scripts/tests/playback_diagnostics.swift" \
  -o "$CHECK_DIR/playback-diagnostics-checks"
"$CHECK_DIR/playback-diagnostics-checks" "$CHECK_DIR"

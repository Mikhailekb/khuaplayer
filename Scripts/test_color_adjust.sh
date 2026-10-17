#!/bin/bash
# Compile focused picture-adjustment checks without the full app dependency build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/khua-color-adjust.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

xcrun swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Apps/Mac/UI/ColorAdjust.swift" \
  "$ROOT/Scripts/tests/color_adjust.swift" \
  -o "$CHECK_DIR/color-adjust-checks"
"$CHECK_DIR/color-adjust-checks"

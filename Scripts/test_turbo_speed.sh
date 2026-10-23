#!/bin/bash
# Compile the Space tap/hold regression checks without the media dependency build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/khua-turbo-speed.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

xcrun swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Apps/Mac/UI/Localization.swift" \
  "$ROOT/Apps/Mac/UI/PlayerUIModel.swift" \
  "$ROOT/Apps/Mac/UI/TurboSpeed.swift" \
  "$ROOT/Scripts/tests/turbo_speed.swift" \
  -o "$CHECK_DIR/turbo-speed-checks"
"$CHECK_DIR/turbo-speed-checks"

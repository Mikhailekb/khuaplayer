#!/bin/bash
# Verify cross-window admission using owned lifetimes and an in-memory gate.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-background-admission.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  "$ROOT/Apps/Mac/UI/TorrentBackgroundAdmission.swift" \
  "$ROOT/Scripts/tests/torrent_background_admission.swift" -o "$CHECK_DIR/checks"
"$CHECK_DIR/checks"

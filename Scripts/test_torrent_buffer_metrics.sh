#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-buffer-metrics.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  "$ROOT/Apps/Mac/UI/TorrentModels.swift" "$ROOT/Apps/Mac/UI/TorrentBufferMetrics.swift" \
  "$ROOT/Scripts/tests/torrent_buffer_metrics.swift" -o "$CHECK_DIR/checks"
"$CHECK_DIR/checks"

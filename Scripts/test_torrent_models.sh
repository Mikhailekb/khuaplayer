#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/khua-torrent-models.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Apps/Mac/UI/TorrentModels.swift" \
  "$ROOT/Scripts/tests/torrent_models.swift" \
  -o "$CHECK_DIR/torrent-model-checks"
"$CHECK_DIR/torrent-model-checks"

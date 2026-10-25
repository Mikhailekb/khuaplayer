#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-preview-cache.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  "$ROOT/Apps/Mac/UI/TorrentPreviewCacheStore.swift" \
  "$ROOT/Scripts/tests/torrent_preview_cache.swift" -o "$CHECK_DIR/checks"
"$CHECK_DIR/checks" "$CHECK_DIR"

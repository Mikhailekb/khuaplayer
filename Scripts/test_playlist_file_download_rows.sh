#!/bin/bash
# Production row/action/progress views in an owned hidden native AppKit window.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-playlist-download-rows.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Apps/Mac/UI/TorrentViews.swift" \
  "$ROOT/Apps/Mac/UI/TorrentBufferStatusView.swift" \
  "$ROOT/Apps/Mac/UI/PlaylistView.swift" \
  "$ROOT/Scripts/tests/playlist_file_download_rows.swift" \
  -o "$CHECK_DIR/playlist-download-rows-checks"
SP_PLAYLIST_ROW_CATALOG="$ROOT/Apps/Mac/Resources/Localizable.xcstrings" "$CHECK_DIR/playlist-download-rows-checks"

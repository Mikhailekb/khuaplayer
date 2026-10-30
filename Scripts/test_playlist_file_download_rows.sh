#!/bin/bash
# Production row/action/progress views in an owned hidden native AppKit window.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-playlist-download-rows.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
python3 - "$ROOT" "$CHECK_DIR" <<'PY'
from pathlib import Path
import sys
root, scratch = map(Path, sys.argv[1:])
source = (root / 'Apps/Mac/UI/Playlist.swift').read_text()
start = source.index('enum SPPlaylistOrder {')
brace = source.index('{', start)
depth, end = 1, brace + 1
while depth:
    if source[end] == '{': depth += 1
    elif source[end] == '}': depth -= 1
    end += 1
(scratch / 'PlaylistOrder.swift').write_text('import Foundation\n' + source[start:end] + '\n')
PY
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$CHECK_DIR/PlaylistOrder.swift" \
  "$ROOT/Apps/Mac/UI/TorrentViews.swift" \
  "$ROOT/Apps/Mac/UI/TorrentBufferStatusView.swift" \
  "$ROOT/Apps/Mac/UI/PlaylistView.swift" \
  "$ROOT/Scripts/tests/playlist_file_download_rows.swift" \
  -o "$CHECK_DIR/playlist-download-rows-checks"
SP_PLAYLIST_ROW_CATALOG="$ROOT/Apps/Mac/Resources/Localizable.xcstrings" "$CHECK_DIR/playlist-download-rows-checks"

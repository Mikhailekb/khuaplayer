#!/bin/bash
# Compile live catalogue checks with the production storage gate and POSIX index.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/khua-playlist-filesystem.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Apps/Mac/UI/SPFileAccessPolicy.swift" \
  "$ROOT/Apps/Mac/UI/SPFileAccess.swift" \
  "$ROOT/Modules/Captions/CaptionSRT.swift" \
  "$ROOT/Apps/Mac/UI/SubtitleAutoload.swift" \
  "$ROOT/Apps/Mac/UI/SPDirectoryMediaIndex.swift" \
  "$ROOT/Apps/Mac/UI/Playlist.swift" \
  "$ROOT/Scripts/tests/playlist_filesystem.swift" \
  -o "$CHECK_DIR/playlist-filesystem-checks"
"$CHECK_DIR/playlist-filesystem-checks"

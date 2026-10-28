#!/bin/bash
# Exercise concurrent file saves with the real coordinator and transport API.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-file-saves.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  "$ROOT/Apps/Mac/UI/TorrentModels.swift" \
  "$ROOT/Apps/Mac/UI/TorrentPreferences.swift" \
  "$ROOT/Apps/Mac/UI/TorrentServer.swift" \
  "$ROOT/Apps/Mac/UI/TorrentFileSaves.swift" \
  "$ROOT/Scripts/tests/torrent_file_saves.swift" -o "$CHECK_DIR/checks"
"$CHECK_DIR/checks"

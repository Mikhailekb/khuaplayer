#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/khua-torrent-recents.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Apps/Mac/UI/TorrentModels.swift" \
  "$ROOT/Apps/Mac/UI/TorrentResumeStore.swift" \
  "$ROOT/Apps/Mac/UI/RecentPlays.swift" \
  "$ROOT/Scripts/tests/torrent_recents.swift" \
  -o "$CHECK_DIR/torrent-recents-checks"
"$CHECK_DIR/torrent-recents-checks"

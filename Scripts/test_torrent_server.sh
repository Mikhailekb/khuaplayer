#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/khua-torrent-server.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Apps/Mac/UI/TorrentModels.swift" \
  "$ROOT/Apps/Mac/UI/TorrentPreferences.swift" \
  "$ROOT/Apps/Mac/UI/TorrentServer.swift" \
  "$ROOT/Scripts/tests/torrent_server.swift" \
  -o "$CHECK_DIR/torrent-server-checks"
"$CHECK_DIR/torrent-server-checks" "$ROOT/Scripts/tests/torrent_worker_fixture.py"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Apps/Mac/UI/TorrentPreferences.swift" \
  "$ROOT/Scripts/tests/torrent_preferences.swift" \
  -o "$CHECK_DIR/torrent-preferences-checks"
"$CHECK_DIR/torrent-preferences-checks"

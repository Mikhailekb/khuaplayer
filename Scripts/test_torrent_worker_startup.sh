#!/bin/bash
# Verify the real worker handshake without launching the app or joining a swarm.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKER="${1:?usage: test_torrent_worker_startup.sh /path/to/Kinolet.app-or-TorrServer}"
python3 "$ROOT/Scripts/check_torrent_worker_version.py"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-real-worker-startup.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

xcrun swiftc -O -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Apps/Mac/UI/TorrentModels.swift" \
  "$ROOT/Apps/Mac/UI/TorrentPreferences.swift" \
  "$ROOT/Apps/Mac/UI/TorrentServer.swift" \
  "$ROOT/Scripts/tests/torrent_worker_startup.swift" \
  -o "$CHECK_DIR/torrent-worker-startup-check"
"$CHECK_DIR/torrent-worker-startup-check" "$WORKER"

#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/khua-torrent-window.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
python3 - "$ROOT" "$CHECK_DIR" <<'PY'
from pathlib import Path
import sys
root, scratch = map(Path, sys.argv[1:])
source = (root / 'Apps/Mac/UI/PlayerViewController.swift').read_text()
start = source.index('    private func cancelTorrentPlaybackWindowPolicy(')
end = source.index('    private func cancelTorrentPauseBuffer(', start)
fixture = (root / 'Scripts/tests/torrent_window_lifecycle.swift').read_text()
assert fixture.count('// INSERT_PRODUCTION_WINDOW_METHODS') == 1
seek_start = source.index('    private func issueForegroundSeek(')
seek_end = source.index('    private func cancelDirectoryScanForSessionBoundary()', seek_start)
assert fixture.count('// INSERT_PRODUCTION_SEEK_METHOD') == 1
(scratch / 'checks.swift').write_text(fixture.replace('// INSERT_PRODUCTION_WINDOW_METHODS', source[start:end])
    .replace('// INSERT_PRODUCTION_SEEK_METHOD', source[seek_start:seek_end]))
PY
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$CHECK_DIR/checks.swift" -o "$CHECK_DIR/checks"
"$CHECK_DIR/checks"

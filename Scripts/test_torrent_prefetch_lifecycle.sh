#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/khua-torrent-prefetch.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
python3 - "$ROOT" "$CHECK_DIR" <<'PY'
from pathlib import Path
import sys
root, scratch = map(Path, sys.argv[1:])
source = (root / 'Apps/Mac/UI/PlayerViewController.swift').read_text()
start = source.index('    private func cancelTorrentPauseBuffer(')
end = source.index('    func beginTorrentOpen(', start)
state_start = source.index('        if state == .playing || state == .paused { startTorrentPlaybackWindowPolicyIfNeeded() }', source.index('    func playerCore(_ core: SPPlayerCore, didChange state: SPPlayerState)'))
state_end = source.index('        if state == .opening, playlistProfileRoot', state_start)
fixture = (root / 'Scripts/tests/torrent_prefetch_lifecycle.swift').read_text()
fixture = fixture.replace('// INSERT_PRODUCTION_PREFETCH_METHODS', source[start:end])
fixture = fixture.replace('// INSERT_PRODUCTION_STATE_BOUNDARY', source[state_start:state_end])
(scratch / 'checks.swift').write_text(fixture)
PY
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$CHECK_DIR/checks.swift" -o "$CHECK_DIR/checks"
"$CHECK_DIR/checks"

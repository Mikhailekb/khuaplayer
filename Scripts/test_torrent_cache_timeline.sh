#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-cached-times.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
python3 - "$ROOT" "$CHECK_DIR" <<'PY'
from pathlib import Path
import sys
root, scratch = map(Path, sys.argv[1:])
helper = (root/'Apps/Mac/UI/TorrentPlayback.swift').read_text()
helper = helper.split('// BEGIN_BUFFERED_TIMELINE_PRESENTATION\n',1)[1].split('// END_BUFFERED_TIMELINE_PRESENTATION',1)[0]
source = (root/'Apps/Mac/UI/PlayerViewController.swift').read_text()
start = source.index('    private func clearTorrentCacheTimeline(')
end = source.index('    private func showTorrentLoading(',start)
notice_start = source.index('        if waiting {', source.index('    func playerCoreDidChangeSourceGrowth('))
notice_end = source.index('\n    }',notice_start)
fixture = (root/'Scripts/tests/torrent_cache_timeline.swift').read_text()
(scratch/'checks.swift').write_text(fixture.replace('// INSERT_PRESENTATION',helper)
    .replace('// INSERT_CONTROLLER',source[start:end])
    .replace('// INSERT_WAIT_NOTICE',source[notice_start:notice_end]))
PY
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$CHECK_DIR/checks.swift" -o "$CHECK_DIR/checks"
"$CHECK_DIR/checks"

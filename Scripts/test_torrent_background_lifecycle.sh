#!/bin/bash
# Execute the actual controller background lifecycle without media, network or disk I/O.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-background-lifecycle.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
python3 - "$ROOT" "$CHECK_DIR" <<'PY'
from pathlib import Path
import sys
root, scratch = map(Path, sys.argv[1:])
source = (root/'Apps/Mac/UI/PlayerViewController.swift').read_text()
start = source.index('    private final class TorrentBackgroundSession {')
session = source[start:source.index('    private let torrentBackgroundOwner', start)]
start = source.index('    private func torrentBackgroundSessionIsCurrent(')
methods = source[start:source.index('    private func updatePlaybackDiagnosticTimer(', start)]
callback_start = methods.index('                [weak self, weak session] subtitles, previews in')
callback_end = methods.index('\n            }', callback_start)
callback = '{\n' + methods[callback_start:callback_end] + '\n        }'
fixture = (root/'Scripts/tests/torrent_background_lifecycle.swift').read_text()
(scratch/'checks.swift').write_text(fixture.replace('// INSERT_SESSION', session)
    .replace('// INSERT_METHODS', methods).replace('// INSERT_ADMISSION_CALLBACK', callback))
PY
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  "$ROOT/Apps/Mac/UI/TorrentBackgroundAdmission.swift" "$CHECK_DIR/checks.swift" -o "$CHECK_DIR/checks"
"$CHECK_DIR/checks"

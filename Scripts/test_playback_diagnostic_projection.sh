#!/bin/bash
# Execute the controller's actual numerical projection with owned fake snapshots.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-diagnostic-projection.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
python3 - "$ROOT" "$CHECK_DIR" <<'PY'
from pathlib import Path
import sys
root, scratch = map(Path, sys.argv[1:])
source = (root/'Apps/Mac/UI/PlayerViewController.swift').read_text()
begin = source.index('    private func updatePlaybackDiagnosticTimer(')
end = source.index('    private lazy var playlistController:', begin)
methods = source[begin:end]
helper = (root/'Apps/Mac/UI/PlaybackDiagnostics.swift').read_text()
schema_begin = helper.index('    enum Event:')
schema_end = helper.index('    private let window', schema_begin)
fixture = (root/'Scripts/tests/playback_diagnostic_projection.swift').read_text()
(scratch/'checks.swift').write_text(fixture.replace('// INSERT_METHODS', methods)
    .replace('// INSERT_SCHEMA', helper[schema_begin:schema_end]))
PY
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  "$CHECK_DIR/checks.swift" -o "$CHECK_DIR/checks"
"$CHECK_DIR/checks"

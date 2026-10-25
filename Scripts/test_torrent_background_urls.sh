#!/bin/bash
# Exercise the actual additive server URL/retirement methods in an owned fixture.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-background-urls.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
python3 - "$ROOT" "$CHECK_DIR" <<'PY'
from pathlib import Path
import sys
root, scratch = map(Path, sys.argv[1:])
source = (root/'Apps/Mac/UI/TorrentServer.swift').read_text()
start = source.index('    func backgroundStreamURL(')
end = source.index('    /// Release the old playback reservation', start)
fixture = (root/'Scripts/tests/torrent_background_urls.swift').read_text()
(scratch/'checks.swift').write_text(fixture.replace('// INSERT_METHODS', source[start:end]))
PY
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  "$CHECK_DIR/checks.swift" -o "$CHECK_DIR/checks"
"$CHECK_DIR/checks"

#!/bin/bash
# Exercise the actual asynchronous owner methods with controlled loopback replies.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-cache-polling.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
python3 - "$ROOT" "$CHECK_DIR" <<'PY'
from pathlib import Path
import sys
root, scratch = map(Path, sys.argv[1:])
model = (root/'Apps/Mac/UI/TorrentPlayback.swift').read_text()
model = model.split('// BEGIN_BUFFERED_TIMELINE_PRESENTATION\n',1)[1].split('// END_BUFFERED_TIMELINE_PRESENTATION',1)[0]
source = (root/'Apps/Mac/UI/PlayerViewController.swift').read_text()
start = source.index('    private func startTorrentStatusUpdates(')
end = source.index('    private func showTorrentLoading(',start)
pip_start = source.index('    private func updateFloatingVideoPresentation(')
pip_end = source.index('    private var currentVolumeBoostPresentation:',pip_start)
fixture = (root/'Scripts/tests/torrent_cache_polling.swift').read_text()
(scratch/'checks.swift').write_text(fixture.replace('// INSERT_MODEL',model)
    .replace('// INSERT_POLLING_METHODS',source[start:end])
    .replace('// INSERT_PIP_UPDATE',source[pip_start:pip_end]))
PY
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$CHECK_DIR/checks.swift" -o "$CHECK_DIR/checks"
"$CHECK_DIR/checks"

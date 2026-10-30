#!/bin/bash
# Exercise actual Dust grain generation and its Metal shader without a window.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-particle-cache.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
python3 - "$ROOT" "$CHECK_DIR" <<'PY'
from pathlib import Path
import sys
root, scratch = map(Path, sys.argv[1:])
source = (root / 'Apps/Mac/UI/SPDustLayer.swift').read_text()
# Expose internal particle state to this detached executable; algorithms,
# geometry, shader and Metal setup are copied verbatim from production.
source = source.replace('fileprivate ', '').replace('private ', '')
floating = (root / 'Apps/Mac/UI/FloatingVideoController.swift').read_text()
helper = floating[floating.index('enum SPBufferedTimeline {'):floating.index('/// The floating window')]
fixture = (root / 'Scripts/tests/particle_buffered_timeline.swift').read_text()
(scratch / 'checks.swift').write_text(fixture.replace('// INSERT_NORMALIZATION', helper)
    .replace('// INSERT_DUST', source))
PY
xcrun swiftc -swift-version 6 -parse-as-library "$CHECK_DIR/checks.swift" -o "$CHECK_DIR/checks"
"$CHECK_DIR/checks" "$@"

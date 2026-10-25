#!/bin/bash
# Exercise the actual progress view with deterministic peripheral dependencies.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-buffered-timeline.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
python3 - "$ROOT" "$CHECK_DIR" <<'PY'
from pathlib import Path
import sys
root, scratch = map(Path, sys.argv[1:])
source = (root / 'Apps/Mac/UI/SPChrome.swift').read_text()
progress = source[source.index('final class SPProgressView:'):source.index('// ── Hover time bubble')]
tokens = source[source.index('enum SPT {'):source.index('struct SPDamageBand:')]
floating = (root / 'Apps/Mac/UI/FloatingVideoController.swift').read_text()
helper = floating[floating.index('enum SPBufferedTimeline {'):floating.index('/// The floating window')]
fixture = (root / 'Scripts/tests/buffered_timeline.swift').read_text()
(scratch / 'checks.swift').write_text(fixture.replace('// INSERT_PRODUCTION_TOKENS', tokens)
    .replace('// INSERT_PRODUCTION_NORMALIZATION', helper)
    .replace('// INSERT_PRODUCTION_PROGRESS', progress))
PY
xcrun swiftc -swift-version 6 -parse-as-library "$CHECK_DIR/checks.swift" -o "$CHECK_DIR/checks"
"$CHECK_DIR/checks" "$@"

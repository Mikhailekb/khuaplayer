#!/bin/bash
# Exercise actual controller cleanup/control methods against an owned fake Core.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-control-intent.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
python3 - "$ROOT" "$CHECK_DIR" "${SP_CONTROL_SOURCE:-}" <<'PY'
from pathlib import Path
import sys
root, scratch = map(Path, sys.argv[1:3])
source = Path(sys.argv[3]).read_text() if sys.argv[3] else (root/'Apps/Mac/UI/PlayerViewController.swift').read_text()
def method(start, end):
    begin = source.index(start)
    return source[begin:source.index(end, begin)]
methods = [
    method('    private func togglePlaybackNow(', '    private func turboSpaceDown('),
    method('    private func turboSpaceDown(', '    private func endTurbo('),
    method('    private func stopRepeat(', '    @discardableResult\n    private func cancelTransientInteractions('),
    method('    private func endPlaybackScrollSeek(', '    private func pumpPlaybackGestureSeek('),
    method('    private func cancelPlaybackScroll(', '    private func handlePlaybackMagnify('),
]
perform_prefix = method('    private func perform(', '        var context = commandContext')
perform_prefix += '        if requestedCommand == .togglePlayback { togglePlaybackNow() }\n    }\n'
turbo = (root/'Apps/Mac/UI/TurboSpeed.swift').read_text()
turbo = turbo[:turbo.index('enum SPTurboSettings')] + turbo[turbo.index('struct SPTurboGesture'):]
fixture = (root/'Scripts/tests/playback_control_intent.swift').read_text()
(scratch/'checks.swift').write_text(fixture.replace('// INSERT_METHODS', '\n'.join(methods)+perform_prefix)
    .replace('// INSERT_TURBO', turbo))
PY
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$CHECK_DIR/checks.swift" "$ROOT/Apps/Mac/UI/PlaybackScrollGesture.swift" \
  "$ROOT/Apps/Mac/UI/PlaybackGestureSeek.swift" -o "$CHECK_DIR/checks"
"$CHECK_DIR/checks"

#!/bin/bash
# Exercise the production views in a hidden native AppKit responder chain.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/khua-playlist-keyboard.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

python3 - "$ROOT" "$CHECK_DIR" <<'PY'
from pathlib import Path
import sys
root, scratch = map(Path, sys.argv[1:])
source = (root / 'Apps/Mac/UI/Playlist.swift').read_text()
start = source.index('enum SPPlaylistOrder {')
brace = source.index('{', start)
depth, end = 1, brace + 1
while depth:
    if source[end] == '{': depth += 1
    elif source[end] == '}': depth -= 1
    end += 1
(scratch / 'PlaylistOrder.swift').write_text('import Foundation\n' + source[start:end] + '\n')
PY

xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$CHECK_DIR/PlaylistOrder.swift" \
  "$ROOT/Apps/Mac/UI/PlaylistView.swift" "$ROOT/Apps/Mac/UI/TorrentViews.swift" \
  "$ROOT/Apps/Mac/UI/TorrentBufferStatusView.swift" "$ROOT/Scripts/tests/playlist_keyboard.swift" \
  -o "$CHECK_DIR/playlist-keyboard-checks"
"$CHECK_DIR/playlist-keyboard-checks"

# Optional regression proof against a pre-fix source snapshot. Instrument only
# method entry with a depth budget, so the real old AppKit loop fails without
# a stack overflow, crash report, or window/dialog.
if [[ -n "${PLAYLIST_KEYBOARD_BASELINE_SOURCE:-}" ]]; then
  python3 - "$PLAYLIST_KEYBOARD_BASELINE_SOURCE" "$CHECK_DIR/PlaylistView-baseline.swift" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
needle = "override func keyDown(with event: NSEvent) {"
assert source.count(needle) == 2
source = source.replace(needle, needle + "\n        guard SPPlaylistKeyboardProbe.enter() else { return }; defer { SPPlaylistKeyboardProbe.leave() }")
source += '''
@MainActor enum SPPlaylistKeyboardProbe {
    static var depth = 0
    static var maximumDepth = 0
    static var tripped = 0
    static func enter() -> Bool {
        if depth >= 24 { tripped += 1; return false }
        depth += 1
        maximumDepth = max(maximumDepth, depth)
        return true
    }
    static func leave() { depth -= 1 }
}
'''
pathlib.Path(sys.argv[2]).write_text(source)
PY
  xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
    -D PLAYLIST_KEYBOARD_BASELINE "$CHECK_DIR/PlaylistView-baseline.swift" \
    "$CHECK_DIR/PlaylistOrder.swift" \
    "$ROOT/Apps/Mac/UI/TorrentViews.swift" "$ROOT/Apps/Mac/UI/TorrentBufferStatusView.swift" \
    "$ROOT/Scripts/tests/playlist_keyboard.swift" -o "$CHECK_DIR/baseline-checks"
  set +e
  "$CHECK_DIR/baseline-checks" > "$CHECK_DIR/baseline.log" 2>&1
  BASELINE_STATUS=$?
  set -e
  cat "$CHECK_DIR/baseline.log"
  [[ "$BASELINE_STATUS" -eq 1 ]]
  rg -q 'BASELINE FAILURE: responder recursion stopped safely' "$CHECK_DIR/baseline.log"
fi

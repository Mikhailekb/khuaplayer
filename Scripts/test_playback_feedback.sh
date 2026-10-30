#!/bin/bash
# Exercise the actual AppKit feedback view without opening or controlling a player.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-playback-feedback.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

xcrun swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Apps/Mac/UI/PlaybackFeedbackView.swift" \
  "$ROOT/Scripts/tests/playback_feedback.swift" \
  -o "$CHECK_DIR/playback-feedback-checks"
"$CHECK_DIR/playback-feedback-checks" "$@"

python3 - "$ROOT" "$CHECK_DIR" <<'PY'
from pathlib import Path
import os, sys
root, scratch = map(Path, sys.argv[1:])
source = (root / 'Apps/Mac/UI/PlayerViewController.swift').read_text()
baseline = os.environ.get('PIP_FEEDBACK_BASELINE_SOURCE')
projection = Path(baseline).read_text() if baseline else source
def function(text, signature):
    assert text.count(signature) == 1, signature
    start = text.index(signature); brace = text.index('{', start); depth = 1; end = brace + 1
    while depth:
        if text[end] == '{': depth += 1
        elif text[end] == '}': depth -= 1
        end += 1
    return text[start:end].replace('private ', '')
methods = '\n'.join(function(projection, name) for name in [
    '    private func showPlaybackFeedback(isPlaying: Bool)',
    '    private func placeVideoOverlay(_ overlay: NSView)',
    '    private func relocateVideoOverlays()'])
entry = function(source, '    @objc func videoPictureInPictureAction(_ sender: NSMenuItem)')
assert entry.index('playbackFeedback?.dismiss()') < entry.index('floatingVideo.present(')
fixture = (root / 'Scripts/tests/pip_playback_feedback.swift').read_text()
assert fixture.count('    // INSERT_PRODUCTION_METHODS') == 1
(scratch / 'pip-feedback.swift').write_text(fixture.replace('    // INSERT_PRODUCTION_METHODS', methods))
PY
xcrun swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Apps/Mac/UI/Localization.swift" \
  "$ROOT/Apps/Mac/UI/FloatingVideoController.swift" \
  "$ROOT/Apps/Mac/UI/PlaybackFeedbackView.swift" \
  "$CHECK_DIR/pip-feedback.swift" -o "$CHECK_DIR/pip-feedback-checks"
"$CHECK_DIR/pip-feedback-checks" "$@"

#!/bin/bash
# Exercise the actual controller input/timer/effect methods with an owned AppKit
# PlayerView and controlled physical-input/core/HUD boundaries; never post input.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-video-hold.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
python3 - "$ROOT" "$CHECK_DIR" <<'PY'
import os, pathlib, sys
root, output = map(pathlib.Path, sys.argv[1:])
source = pathlib.Path(os.environ.get('VIDEO_HOLD_CONTROLLER_SOURCE', str(root / 'Apps/Mac/UI/PlayerViewController.swift'))).read_text()
def region(start, end):
    assert source.count(start) == 1, start
    return source.split(start, 1)[1].split(end, 1)[0]
def function(signature):
    assert source.count(signature) == 1, signature
    start = source.index(signature)
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        if source[end] == '{': depth += 1
        elif source[end] == '}': depth -= 1
        end += 1
    return source[start:end]
methods = '    private var videoClick' + region('    private var videoClick', '    private var videoActionIdentity:')
if baseline := os.environ.get('VIDEO_HOLD_BASELINE_SOURCE'):
    old = pathlib.Path(baseline).read_text()
    start, end = '    private var videoClick', '    private var videoActionIdentity:'
    assert old.count(start) == 1 and old.count(end) == 1
    methods = start + old.split(start, 1)[1].split(end, 1)[0]
    # Compile old mouse routing against today's timer/owner interfaces so the
    # runtime assertion, not a missing API, proves the absent feature.
    methods += '\n' + function('    private func startVideoHoldMonitor()')
    methods += '\n' + function('    private func validateVideoHold()')
    methods += '\n' + function('    private func finishVideoPress(sameWindow: Bool)')
for signature in ['    private static func turboAllowedKey(_ event: NSEvent) -> Bool',
                  '    private func togglePlaybackNow()',
                  '    private func handleKeyUp(_ event: NSEvent)',
                  '    private func turboSpaceDown()',
                  '    private func beginTurbo(owner: SPTurboGesture.Owner)',
                  '    private func endTurbo(reason: String)',
                  '    private func applyTurbo(_ effects: [SPTurboGesture.Effect], reason: String)']:
    methods += '\n' + function(signature) + '\n'
# Substitute only non-deterministic input/configuration boundaries. Timer,
# ownership, token arbitration and effect routing remain the production code.
methods = methods.replace('NSEvent.mouseLocation', 'SPHoldFixtureInput.pointer')
methods = methods.replace('NSEvent.pressedMouseButtons', 'SPHoldFixtureInput.buttons')
methods = methods.replace('SPTurboSettings.isEnabled', 'SPHoldFixtureInput.enabled')
methods = methods.replace('SPTurboSettings.rate', 'SPHoldFixtureInput.configuredRate')
fixture = (root / 'Scripts/tests/video_hold_turbo.swift').read_text()
assert fixture.count('    // INSERT_PRODUCTION_METHODS') == 1
(output / 'checks.swift').write_text(fixture.replace('    // INSERT_PRODUCTION_METHODS', methods))
# Guard the production call sites which are intentionally outside this focused
# projection (full controller compilation is the application build's job).
assert 'case turboSpaceKeyCode, 53, 125, 126: return true' in source
assert 'if !turbo.hasOwner(.mouse) { cancelVideoClick() }' in source
assert 'self?.cancelClickCandidateIfDragged()' in source
assert 'self?.endTurbo(reason: "fullscreenTransition")' in source
assert 'self?.endTurbo(reason: "resignFirstResponder")' in source
assert 'self?.endTurbo(reason: "resignKey")' in source
PY
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  "$ROOT/Apps/Mac/UI/Localization.swift" "$ROOT/Apps/Mac/UI/PlayerUIModel.swift" \
  "$ROOT/Apps/Mac/UI/TurboSpeed.swift" "$ROOT/Apps/Mac/UI/VideoClickGesture.swift" \
  "$ROOT/Apps/Mac/UI/PlayerView.swift" "$CHECK_DIR/checks.swift" \
  -o "$CHECK_DIR/video-hold-checks"
"$CHECK_DIR/video-hold-checks"

#!/bin/bash
# Use production preference models and exact controller capture/save/restore
# methods against owned, isolated session/core boundaries. No live player I/O.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-playlist-tracks.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  "$ROOT/Apps/Mac/UI/PlaylistPreferences.swift" "$ROOT/Scripts/tests/playlist_preferences.swift" \
  -o "$CHECK_DIR/model-checks"
"$CHECK_DIR/model-checks"
python3 - "$ROOT" "$CHECK_DIR" <<'PY'
import os, pathlib, sys
root, output = map(pathlib.Path, sys.argv[1:])
source = (root / 'Apps/Mac/UI/PlayerViewController.swift').read_text()
baseline_path = os.environ.get('PLAYLIST_TRACK_BASELINE_CONTROLLER')
restore_source = pathlib.Path(baseline_path).read_text() if baseline_path else source

def function(text, signature):
    assert text.count(signature) == 1, signature
    start = text.index(signature)
    brace = text.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        if text[end] == '{': depth += 1
        elif text[end] == '}': depth -= 1
        end += 1
    return text[start:end]

methods = ''
for signature in ['    private func prepareTorrentPlaylist()',
                  '    private func savePlaylistProfile()',
                  '    private func rememberPlaylistAudioSelection(_ index: Int)',
                  '    private func rememberPlaylistSubtitleSelection(_ index: Int)',
                  '    private func restorePlaylistTrackPreferences()']:
    methods += function(source, signature) + '\n'
methods += function(restore_source, '    private func restorePlaylistProfileIfReady()')
if capture_path := os.environ.get('PLAYLIST_TRACK_BASELINE_CAPTURE'):
    old = pathlib.Path(capture_path).read_text()
    begin = '            if let track = core?.audioTrackList.first(where:'
    end = '            if core?.currentAudioTrackIndex != index {'
    assert old.count(begin) == 1
    old_capture = begin + old.split(begin, 1)[1].split(end, 1)[0]
    # Mechanical Any collection boundary adaptation; retain the old capture's
    # exact preference initializer and nil/unsupported-metadata behavior.
    old_capture = old_capture.replace('core?.audioTrackList.first', 'core?.audioTrackList.compactMap({ $0 as? [String: Any] }).first')
    old_capture = old_capture.replace('}) as? [String: Any] {', '}) {')
    current_capture = function(source, '    private func rememberPlaylistAudioSelection(_ index: Int)')
    methods = methods.replace(current_capture, '    private func rememberPlaylistAudioSelection(_ index: Int) {\n' + old_capture + '    }')
# The isolated store is the sole substituted boundary; production session
# ownership, metadata matching, pending guards, setters and side effects remain.
methods = methods.replace('SPPlaylistPreferencesStore.shared', 'fixtureStore')
fixture = (root / 'Scripts/tests/playlist_track_inheritance.swift').read_text()
assert fixture.count('    // INSERT_PRODUCTION_METHODS') == 1
(output / 'checks.swift').write_text(fixture.replace('    // INSERT_PRODUCTION_METHODS', methods))
# Cover call sites outside the focused projection and keep every explicit UI
# track action routed to capture before Core changes the selected track.
assert 'case .selectAudioTrack(let index):' in source
assert 'rememberPlaylistAudioSelection(index)' in source
assert 'case .selectSubtitleTrack(let index):\n            rememberPlaylistSubtitleSelection(index)' in source
assert 'if incomingTorrentContext != nil { prepareTorrentPlaylist() }' in source
assert 'if let context = torrentContext, let file = context.file(for: url)' in source
assert 'open(url: mediaList[currentMediaIndex + 1])' in source
assert 'self.playNextMedia()' in function(source, '    private func schedulePlaylistAdvanceIfFinished(_ core: SPPlayerCore)')
PY
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  "$ROOT/Apps/Mac/UI/PlaylistPreferences.swift" "$ROOT/Apps/Mac/UI/ColorAdjust.swift" \
  "$CHECK_DIR/checks.swift" -o "$CHECK_DIR/controller-checks"
"$CHECK_DIR/controller-checks"

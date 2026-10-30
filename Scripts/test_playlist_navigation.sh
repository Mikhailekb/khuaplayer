#!/bin/bash
# Actual AppKit Chrome and controller navigation methods; no media runtime,
# network, live app windows or persistent user preferences are used.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-playlist-navigation.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
python3 - "$ROOT" "$CHECK_DIR" <<'PY'
from pathlib import Path
import sys
root, scratch = map(Path, sys.argv[1:])
chrome=(root/'Apps/Mac/UI/SPChrome.swift').read_text()
# Expose fields for detached inspection; no behavior or renderer is replaced.
(scratch/'chrome.swift').write_text(chrome.replace('fileprivate ','').replace('private ',''))
floating=(root/'Apps/Mac/UI/FloatingVideoController.swift').read_text()
(scratch/'normalization.swift').write_text('import Foundation\n'+floating[floating.index('enum SPBufferedTimeline {'):floating.index('/// The floating window')])
source=(root/'Apps/Mac/UI/PlayerViewController.swift').read_text()
def member(signature):
    assert source.count(signature)==1,signature
    begin=source.index(signature);brace=source.index('{',begin);level=1;end=brace+1
    while level:
        if source[end]=='{':level+=1
        elif source[end]=='}':level-=1
        end+=1
    return source[begin:end].replace('private ','')
methods='\n'.join(member(s) for s in ['    private var playlistNavigationPresentation: SPPlaylistNavigationPresentation',
 '    private func refreshPlaylistNavigationControls()', '    private func navigatePlaylist(forward: Bool)',
 '    func playPreviousMedia()', '    func playNextMedia()'])
controller='''
private enum FixtureState { case ready,playing,paused,ended,opening }
@MainActor private final class FixtureCore { var state:FixtureState = .playing }
private enum FixtureCommand { case previousMedia,nextMedia }
@MainActor private final class NavigationFixtureOwner {
    let chrome:SPChromeView?
    var hasMediaSession=true
    var core:FixtureCore?=FixtureCore()
    var mediaList=(1...3).map { URL(fileURLWithPath:"/fixture/E\\($0).mp4") }
    var currentMediaIndex=1
    var playbackIdentityURL:URL?=URL(fileURLWithPath:"/fixture/E2.mp4")
    var torrentResolving=false
    var torrentCacheRestartToken:UUID?
    var isPlaylistShown=false
    var opened:[URL]=[]
    init(chrome:SPChromeView){self.chrome=chrome
        let c=chrome
        BINDINGS
    }
    func open(url:URL){opened.append(url);currentMediaIndex=mediaList.firstIndex(of:url)!;playbackIdentityURL=url
        core!.state = .opening
        // Torrent opens have historically shown their sidebar internally.
        isPlaylistShown=true
        refreshPlaylistNavigationControls()
    }
    func setPlaylistShown(_ value:Bool){isPlaylistShown=value}
    func perform(_ command:FixtureCommand){switch command {case .previousMedia:playPreviousMedia();case .nextMedia:playNextMedia()}}
    METHODS
}
'''
bindings='\n'.join(line.strip() for line in source.splitlines() if 'c.onPreviousMedia =' in line or 'c.onNextMedia =' in line)
assert bindings.count('navigatePlaylist(forward:')==2
controller=controller.replace('BINDINGS',bindings).replace('METHODS',methods)
fixture=(root/'Scripts/tests/playlist_navigation.swift').read_text()
(scratch/'checks.swift').write_text(fixture.replace('// INSERT_CONTROLLER_FIXTURE',controller))
# Catalogue publication must not depend on ever creating/opening the sidebar.
refresh=member('    private func refreshPlaylistView()')
assert refresh.index('refreshPlaylistNavigationControls()') < refresh.index('guard isPlaylistShown')
assert 'refreshPlaylistNavigationControls()' in member('    private func transitionPresentation(_ event: PlayerPresentationEvent)')
assert 'refreshPlaylistNavigationControls()' in member('    private func applyDirectorySnapshot(_ snapshot: SPDirectoryMediaSnapshot,')
assert 'c.setPlaylistNavigation(playlistNavigationPresentation)' in source
PY
if ! xcrun swiftc -swift-version 6 -strict-concurrency=minimal -parse-as-library -D SP_ENHANCE \
 "$ROOT/Apps/Mac/UI/Localization.swift" "$ROOT/Apps/Mac/UI/PlayerUIModel.swift" \
 "$ROOT/Apps/Mac/UI/SPTimeText.swift" "$ROOT/Apps/Mac/UI/SPFeatures.swift" \
 "$ROOT/Apps/Mac/UI/MotionButton.swift" "$ROOT/Apps/Mac/UI/TurboSpeed.swift" \
 "$CHECK_DIR/normalization.swift" "$CHECK_DIR/chrome.swift" "$CHECK_DIR/checks.swift" \
 -o "$CHECK_DIR/checks" > "$CHECK_DIR/build.log" 2>&1; then
 cat "$CHECK_DIR/build.log"
 exit 1
fi
PLAYLIST_NAV_ENHANCE=1 "$CHECK_DIR/checks" "$@"
PLAYLIST_NAV_ENHANCE=0 "$CHECK_DIR/checks" "$@"

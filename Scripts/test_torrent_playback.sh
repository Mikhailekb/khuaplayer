#!/bin/bash
# Stable torrent identities plus actual sidebar tree order; no worker/network.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kinolet-torrent-playback.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
python3 - "$ROOT" "$CHECK_DIR" <<'PY'
from pathlib import Path
import sys,os
root,out=map(Path,sys.argv[1:])
view=(root/'Apps/Mac/UI/PlaylistView.swift').read_text()
node=view[view.index('private final class SPPlaylistNode:'):view.index('/// Keyboard selection')].replace('private ','')
signature='    private func buildTree()';start=view.index(signature);brace=view.index('{',start);depth=1;end=brace+1
while depth:
 if view[end]=='{':depth+=1
 elif view[end]=='}':depth-=1
 end+=1
build=view[start:end].replace('private ','')
projection='''
@MainActor final class FixturePlaylistTree {
 var rootURL:URL?
 var entries:[SPPlaylistEntry]
 var nodes:[String:SPPlaylistNode]=[:]
 var rootNode:SPPlaylistNode?
 init(root:URL,entries:[SPPlaylistEntry]){rootURL=root;self.entries=entries;buildTree()}
 var flattenedEntries:[SPPlaylistEntry] {
   func flatten(_ node:SPPlaylistNode)->[SPPlaylistEntry] { if let entry=node.entry{return[entry]};return node.children.flatMap(flatten) }
   return rootNode.map(flatten) ?? []
 }
 BUILD
}
'''.replace('BUILD',build)
fixture=(root/'Scripts/tests/torrent_playback.swift').read_text().replace('// INSERT_PRODUCTION_TREE',node+projection)
(out/'checks.swift').write_text(fixture)
if baseline:=os.environ.get('TORRENT_PLAYBACK_ORDER_BASELINE'):
 source=Path(baseline).read_text()
 # Old context has no sorted initial-selection API. Supply current pure helper
 # only to keep this runtime comparison compiling; actual old playableFiles
 # and entries logic remain untouched and fail the unsorted-manifest check.
 insert='''
    static func orderedPlayableFiles(in descriptor: SPTorrentDescriptor) -> [SPTorrentFile] {
        descriptor.files.filter(\\.isPlayable).sorted { SPPlaylistOrder.pathLess($0.path, $1.path) }
    }
'''
 if 'static func orderedPlayableFiles(' not in source:
  source=source.replace('struct SPTorrentPlaybackContext: Sendable {','struct SPTorrentPlaybackContext: Sendable {'+insert)
 (out/'TorrentPlayback.swift').write_text(source)
else:(out/'TorrentPlayback.swift').write_bytes((root/'Apps/Mac/UI/TorrentPlayback.swift').read_bytes())
PY
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
 "$ROOT/Apps/Mac/UI/Playlist.swift" "$ROOT/Apps/Mac/UI/TorrentModels.swift" \
 "$CHECK_DIR/TorrentPlayback.swift" "$CHECK_DIR/checks.swift" -o "$CHECK_DIR/checks"
"$CHECK_DIR/checks"

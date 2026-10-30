import AppKit

// Playlist.swift is compiled in full so these checks use the production entry
// type. Its unused filesystem scanner needs only these storage-policy services.
struct SPBackgroundDiskIOPolicyLease { func restore() {} }
enum SPBackgroundStorageGate {
    static func waitUntilAllowed(shouldCancel: () -> Bool) -> Bool { !shouldCancel() }
}

// INSERT_PRODUCTION_TREE

@main @MainActor struct TorrentPlaybackChecks {
    static var checks = 0
    static func main() {
        let first = SPTorrentFile(id: 9, path: "Show/Season 1/E1.mkv", length: 100)
        let second = SPTorrentFile(id: 4, path: "Show/Season 2/E2.mp4", length: 200)
        let ignored = SPTorrentFile(id: 21, path: "Show/readme.txt", length: 20)
        let prefixed = context(name: "Show", files: [first, second, ignored])
        check(prefixed.entries.map(\.relativePath) == ["Season 1/E1.mkv", "Season 2/E2.mp4"], "strip one matching torrent root from display hierarchy")
        check(prefixed.playableFiles.map(\.id) == [9, 4], "natural playback order preserves server file IDs")
        check(prefixed.entries.map(\.displayName) == ["E1.mkv", "E2.mp4"], "display cleanup preserves leaf names")
        check(prefixed.entries.allSatisfy { !$0.isGrowing }, "torrent entries retain their original growth state")
        for (file, entry) in zip(prefixed.playableFiles, prefixed.entries) {
            let previousIdentity = prefixed.rootURL.appendingPathComponent(file.path, isDirectory: false)
            check(entry.url == previousIdentity, "display path cleanup does not change original virtual media identity")
            check(prefixed.identityURL(for: file) == previousIdentity, "identityURL still includes the authoritative file path")
            check(prefixed.file(for: entry.url) == file, "entry identity maps back to the exact original server file")
        }
        check(prefixed.identityURL == prefixed.identityURL(for: first), "current media identity stays unchanged")
        check(prefixed.entries.count == 2, "nonplayable torrent files remain excluded")
        let plain = context(name: "Show", files: [SPTorrentFile(id: 3, path: "Season 1/E1.mkv", length: 1)])
        check(plain.entries.map(\.relativePath) == ["Season 1/E1.mkv"], "unprefixed path remains intact")
        check(plain.entries[0].url == plain.rootURL.appendingPathComponent("Season 1/E1.mkv"), "unprefixed identity remains intact")
        let single = context(name: "movie.mkv", files: [SPTorrentFile(id: 42, path: "movie.mkv", length: 500)])
        check(single.entries.map(\.relativePath) == ["movie.mkv"], "single-file torrents keep their filename")
        check(single.file(for: single.identityURL)?.id == 42, "single-file server ID survives round trip")
        let similar = context(name: "Show", files: [SPTorrentFile(id: 7, path: "Showcase/E1.mkv", length: 1)])
        check(similar.entries[0].relativePath == "Showcase/E1.mkv", "a sibling sharing only the name prefix is not stripped")
        let repeated = context(name: "Show", files: [SPTorrentFile(id: 8, path: "Show/Show/E1.mkv", length: 1)])
        check(repeated.entries[0].relativePath == "Show/E1.mkv", "only the leading torrent root is stripped")
        let differentCase = context(name: "Show", files: [SPTorrentFile(id: 5, path: "show/E1.mkv", length: 1)])
        check(differentCase.entries[0].relativePath == "show/E1.mkv", "case-distinct server path is preserved")
        let mixedPrefix = context(name: "Show", files: [
            SPTorrentFile(id: 2, path: "Season 2/E2.mp4", length: 1),
            SPTorrentFile(id: 1, path: "Show/Season 1/E1.mp4", length: 1)
        ])
        check(mixedPrefix.playableFiles.map(\.id) == [1, 2] &&
              mixedPrefix.entries.map(\.relativePath) == ["Season 1/E1.mp4", "Season 2/E2.mp4"],
              "mixed prefixed and plain server paths sort by their exact visible hierarchy")
        let visibleNameCollision = context(name: "Show", files: [
            SPTorrentFile(id: 1, path: "Show/Collision.mp4", length: 1),
            SPTorrentFile(id: 2, path: "Collision.mp4/E1.mp4", length: 1)
        ])
        check(visibleNameCollision.playableFiles.map(\.id) == [2, 1],
              "a shared visible component still puts folders before terminal files")
        check(!prefixed.entries.map(\.url.absoluteString).joined().contains("secret"), "stable identities never include stream credentials")
        let unsorted = [
            SPTorrentFile(id: 30, path: "Show/Season 2/E10.mp4", length: 100),
            SPTorrentFile(id: 90, path: "Show/E0.mp4", length: 100),
            SPTorrentFile(id: 40, path: "Show/Season 10/E1.mp4", length: 100),
            SPTorrentFile(id: 20, path: "Show/Season 2/E2.mp4", length: 100),
            SPTorrentFile(id: 10, path: "Show/Season 2/E1.mp4", length: 100),
            SPTorrentFile(id: 5, path: "Show/Season 2/Extras/E1.mp4", length: 100),
            SPTorrentFile(id: 2, path: "Show/Season 1/E2.mp4", length: 100)
        ]
        let ordered = context(name: "Show", files: unsorted)
        check(ordered.playableFiles.map(\.id) == [2, 5, 10, 20, 30, 40, 90],
              "unsorted manifests follow natural folders-first depth-first playback order")
        check(SPTorrentPlaybackContext.orderedPlayableFiles(in: ordered.descriptor).first?.id == 2,
              "initial torrent selection uses the same first episode as the tree")
        check(ordered.file == unsorted[0] && ordered.identityURL == ordered.identityURL(for: unsorted[0]),
              "sorting never changes current file identity or original server ID")
        let tree = FixturePlaylistTree(root: ordered.rootURL, entries: ordered.entries)
        let visible = tree.flattenedEntries
        check(visible.map(\.url) == ordered.entries.map(\.url),
              "actual production sidebar tree traversal matches Previous/Next sequence")
        let local = unsorted.map { item in
            SPPlaylistEntry(url: URL(fileURLWithPath: "/fixture/\(item.path)"),
                relativePath: item.path, displayName: item.displayName, isGrowing: false)
        }
        let localTree = FixturePlaylistTree(root: URL(fileURLWithPath: "/fixture"), entries: local)
        check(local.sorted { SPPlaylistOrder.pathLess($0.relativePath, $1.relativePath) }.map(\.url) == localTree.flattenedEntries.map(\.url),
              "filesystem path ordering matches the same visible mixed-depth tree")
        for file in ordered.playableFiles {
            check(ordered.file(for: ordered.identityURL(for: file)) == file,
                  "every sorted episode retains exact identity-to-server-file round trip")
        }
        print("Torrent playback display checks passed (\(checks) assertions).")
    }
    static func context(name: String, files: [SPTorrentFile]) -> SPTorrentPlaybackContext {
        let descriptor = SPTorrentDescriptor(leaseID: UUID(), hash: String(repeating: "a", count: 40), name: name, files: files, originalLink: nil)
        return SPTorrentPlaybackContext(descriptor: descriptor, file: files[0], streamURL: URL(string: "http://user:secret@127.0.0.1:12345/stream/test")!)
    }
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        checks += 1
    }
}

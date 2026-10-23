import Foundation

// Playlist.swift is compiled in full so these checks use the production entry
// type. Its unused filesystem scanner needs only these storage-policy services.
struct SPBackgroundDiskIOPolicyLease { func restore() {} }
enum SPBackgroundStorageGate {
    static func waitUntilAllowed(shouldCancel: () -> Bool) -> Bool { !shouldCancel() }
}

@main @MainActor struct TorrentPlaybackChecks {
    static var checks = 0
    static func main() {
        let first = SPTorrentFile(id: 9, path: "Show/Season 1/E1.mkv", length: 100)
        let second = SPTorrentFile(id: 4, path: "Show/Season 2/E2.mp4", length: 200)
        let ignored = SPTorrentFile(id: 21, path: "Show/readme.txt", length: 20)
        let prefixed = context(name: "Show", files: [first, second, ignored])
        check(prefixed.entries.map(\.relativePath) == ["Season 1/E1.mkv", "Season 2/E2.mp4"], "strip one matching torrent root from display hierarchy")
        check(prefixed.playableFiles.map(\.id) == [9, 4], "display cleanup preserves server file IDs and order")
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
        check(!prefixed.entries.map(\.url.absoluteString).joined().contains("secret"), "stable identities never include stream credentials")
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

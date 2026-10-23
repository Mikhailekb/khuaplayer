import Foundation

/// Stable media identities are independent of the worker's private port and
/// credentials. They share the local playlist's settings and resume policies.
struct SPTorrentPlaybackContext: Sendable {
    let descriptor: SPTorrentDescriptor
    let file: SPTorrentFile
    let streamURL: URL

    var rootURL: URL {
        let title = (descriptor.name as NSString).lastPathComponent
        let safeTitle = title.isEmpty || title == "." || title == ".." ? descriptor.hash : title
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/Khua/Torrent Playlists", isDirectory: true)
            .appendingPathComponent(descriptor.hash, isDirectory: true)
            .appendingPathComponent(safeTitle, isDirectory: true)
    }

    var playableFiles: [SPTorrentFile] { descriptor.files.filter(\.isPlayable) }
    var identityURL: URL { identityURL(for: file) }

    func identityURL(for file: SPTorrentFile) -> URL {
        rootURL.appendingPathComponent(file.path, isDirectory: false)
    }

    var entries: [SPPlaylistEntry] {
        playableFiles.map { item in
            let prefix = descriptor.name + "/"
            let relative = item.path.hasPrefix(prefix) ? String(item.path.dropFirst(prefix.count)) : item.path
            return SPPlaylistEntry(url: identityURL(for: item), relativePath: relative,
                displayName: item.displayName, isGrowing: false)
        }
    }

    func file(for identity: URL) -> SPTorrentFile? {
        playableFiles.first { identityURL(for: $0) == identity.standardizedFileURL }
    }
}

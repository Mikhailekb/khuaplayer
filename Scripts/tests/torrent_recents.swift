import Foundation

@main @MainActor
struct TorrentRecentsChecks {
    static var assertions = 0
    enum Failure: Error { case check(String) }
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure.check(message) }
        assertions += 1
        print("PASS \(assertions): \(message)")
    }
    static func descriptor(_ index: Int) throws -> SPTorrentDescriptor {
        let title = "Show \(index)"
        let data = Data("d4:infod4:name\(title.utf8.count):\(title)ee".utf8)
        let hash = try SPTorrentInput.infoHash(in: data)
        let files = [SPTorrentFile(id: 7, path: "Show/Season 2/Episode 10.mkv", length: 12345),
                     SPTorrentFile(id: 9, path: "Show/Season 2/Episode 11.mkv", length: 12346)]
        return SPTorrentDescriptor(leaseID: UUID(), hash: hash, name: title, files: files,
                                  originalLink: nil, originalTorrentData: data)
    }
    static func main() throws {
        let suite = "dev.khuaplayer.tests.torrent-recents." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let scratch = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("khua-torrent-recents-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let metadata = scratch.appendingPathComponent("metadata", isDirectory: true)
        let store = SPTorrentResumeStore(directory: metadata)
        let first = try descriptor(1)
        let ref = try store.reference(for: first, file: first.files[0])
        let managedFile = metadata.appendingPathComponent(first.hash + ".torrent", isDirectory: false)
        let legacy: [String: Any] = ["path": "/Movies/Local.mp4", "title": "Local", "position": 42.0,
                                     "duration": 600.0, "lastPlayedAt": 100.0]
        defaults.set(try JSONSerialization.data(withJSONObject: [legacy]), forKey: "sp.recent")
        let loadedLegacy = RecentPlays.load(defaults: defaults)
        try check(loadedLegacy.count == 1 && loadedLegacy[0].torrent == nil && loadedLegacy[0].position == 42,
                  "legacy five-field history decodes unchanged")
        let identity = "/virtual/\(first.hash)/Episode10.mkv"
        RecentPlays.record(path: identity, title: "Episode 10", position: 120, duration: 600,
                           torrent: ref, defaults: defaults, torrentStore: store)
        let ledgerData = defaults.data(forKey: "sp.recent")!
        let text = String(data: ledgerData, encoding: .utf8)!
        try check(RecentPlays.load(defaults: defaults).first?.torrent == ref,
                  "typed history preserves exact selected episode reference")
        try check(!text.contains(first.originalTorrentData!.base64EncodedString()) && !text.contains("d4:infod") && !text.contains("leaseID"),
                  "ledger contains no metainfo bytes or worker lease")
        try check(!text.contains("127.0.0.1") && !text.contains("Authorization") && !text.contains("password") && !text.contains("http:"),
                  "durable metainfo reference contains no worker address or credentials")
        RecentPlays.record(path: identity, title: "Episode 10", position: 150, duration: 600,
                           insert: false, defaults: defaults, torrentStore: store)
        try check(RecentPlays.load(defaults: defaults).first?.torrent == ref && RecentPlays.load(defaults: defaults).first?.position == 150,
                  "position-only update preserves existing torrent payload")
        let magnet = "magnet:?xt=urn:btih:" + first.hash
        let magnetRef = try SPTorrentResumeReference(hash: first.hash, torrentName: first.name,
            filePath: first.files[0].path, length: first.files[0].length, fileID: first.files[0].id,
            source: .magnet(magnet))
        RecentPlays.record(path: identity, title: "Episode 10", position: 151, duration: 600,
                           torrent: magnetRef, defaults: defaults, torrentStore: store)
        try check(RecentPlays.load(defaults: defaults).first?.torrent == ref && FileManager.default.fileExists(atPath: managedFile.path),
                  "older magnet checkpoint cannot downgrade a healthy matching metainfo source")
        try FileManager.default.removeItem(at: managedFile)
        RecentPlays.record(path: identity, title: "Episode 10", position: 152, duration: 600,
                           torrent: magnetRef, defaults: defaults, torrentStore: store)
        try check(RecentPlays.load(defaults: defaults).first?.torrent == magnetRef,
                  "valid incoming magnet recovers a missing metainfo source")
        _ = try store.reference(for: first, file: first.files[0])
        RecentPlays.record(path: identity, title: "Episode 10", position: 153, duration: 600,
                           torrent: ref, defaults: defaults, torrentStore: store)
        try Data("tampered".utf8).write(to: managedFile)
        RecentPlays.record(path: identity, title: "Episode 10", position: 154, duration: 600,
                           torrent: magnetRef, defaults: defaults, torrentStore: store)
        try check(RecentPlays.load(defaults: defaults).first?.torrent == magnetRef,
                  "valid incoming magnet recovers tampered metainfo instead of preserving it")
        _ = try store.reference(for: first, file: first.files[0])
        RecentPlays.record(path: identity, title: "Episode 10", position: 155, duration: 600,
                           torrent: ref, defaults: defaults, torrentStore: store)
        let otherEpisode = try SPTorrentResumeReference(hash: first.hash, torrentName: first.name,
            filePath: first.files[1].path, length: first.files[1].length, fileID: first.files[1].id,
            source: .magnet(magnet))
        RecentPlays.record(path: identity, title: "Episode 11", position: 156, duration: 600,
                           torrent: otherEpisode, defaults: defaults, torrentStore: store)
        try check(RecentPlays.load(defaults: defaults).first?.torrent == otherEpisode,
                  "source retention never reuses a different episode")
        _ = try store.reference(for: first, file: first.files[0])
        RecentPlays.record(path: identity, title: "Episode 10", position: 157, duration: 600,
                           torrent: ref, defaults: defaults, torrentStore: store)
        let otherLength = try SPTorrentResumeReference(hash: first.hash, torrentName: first.name,
            filePath: first.files[0].path, length: first.files[0].length + 1, fileID: first.files[0].id,
            source: .magnet(magnet))
        RecentPlays.record(path: identity, title: "Changed file", position: 157, duration: 600,
                           torrent: otherLength, defaults: defaults, torrentStore: store)
        try check(RecentPlays.load(defaults: defaults).first?.torrent == otherLength,
                  "source retention requires the same file length as well as path")
        _ = try store.reference(for: first, file: first.files[0])
        RecentPlays.record(path: identity, title: "Episode 10", position: 157, duration: 600,
                           torrent: ref, defaults: defaults, torrentStore: store)
        let different = try descriptor(99)
        let otherHash = try SPTorrentResumeReference(hash: different.hash, torrentName: different.name,
            filePath: first.files[0].path, length: first.files[0].length, fileID: first.files[0].id,
            source: .magnet("magnet:?xt=urn:btih:" + different.hash))
        RecentPlays.record(path: identity, title: "Other torrent", position: 158, duration: 600,
                           torrent: otherHash, defaults: defaults, torrentStore: store)
        try check(RecentPlays.load(defaults: defaults).first?.torrent == otherHash,
                  "source retention never reuses metadata from a different torrent hash")
        _ = try store.reference(for: first, file: first.files[0])
        RecentPlays.record(path: identity, title: "Episode 10", position: 159, duration: 600,
                           torrent: ref, defaults: defaults, torrentStore: store)
        var corrupted = try JSONSerialization.jsonObject(with: defaults.data(forKey: "sp.recent")!) as! [[String: Any]]
        corrupted[0]["torrent"] = ["hash": "invalid", "source": ["magnet": ["_0": "http://user:secret@127.0.0.1:9999/stream"]]]
        corrupted.append(["path": "/broken", "position": 0])
        defaults.set(try JSONSerialization.data(withJSONObject: corrupted), forKey: "sp.recent")
        let surviving = RecentPlays.load(defaults: defaults)
        try check(surviving.count == 2 && surviving.first?.path == identity && surviving.first?.torrent == nil && surviving.last?.path == "/Movies/Local.mp4",
                  "corrupt optional payload and corrupt row do not erase good legacy history")
        RecentPlays.record(path: identity, title: "Episode 10", position: 150, duration: 600,
                           torrent: ref, defaults: defaults, torrentStore: store)
        let renamed = "/virtual/\(first.hash)/Renamed.mkv"
        RecentPlays.rename(from: identity, to: renamed, title: "Renamed", defaults: defaults, torrentStore: store)
        try check(RecentPlays.load(defaults: defaults).first?.torrent == ref && FileManager.default.fileExists(atPath: managedFile.path),
                  "rename preserves source metadata and selected episode path")
        let secondEpisode = try store.reference(for: first, file: first.files[1])
        RecentPlays.record(path: "/virtual/\(first.hash)/Episode11.mkv", title: "Episode 11", position: 2, duration: 600,
                           torrent: secondEpisode, defaults: defaults, torrentStore: store)
        RecentPlays.remove(path: renamed, defaults: defaults, torrentStore: store)
        try check(FileManager.default.fileExists(atPath: managedFile.path), "removing one episode retains shared torrent metadata")
        RecentPlays.remove(path: "/virtual/\(first.hash)/Episode11.mkv", defaults: defaults, torrentStore: store)
        try check(!FileManager.default.fileExists(atPath: managedFile.path), "removing the final reference prunes its metainfo sidecar")
        let orphan = try descriptor(2)
        let orphanRef = try store.reference(for: orphan, file: orphan.files[0])
        RecentPlays.record(path: "/not-in-history", title: "Absent", position: 10, duration: 600,
                           insert: false, torrent: orphanRef, defaults: defaults, torrentStore: store)
        try check(!FileManager.default.fileExists(atPath: metadata.appendingPathComponent(orphan.hash + ".torrent").path),
                  "non-inserting checkpoint prunes a prepared but unreferenced sidecar")
        RecentPlays.clear(defaults: defaults, torrentStore: store)
        let movie = metadata.appendingPathComponent("saved.mp4", isDirectory: false)
        try Data("user saved movie".utf8).write(to: movie)
        var references: [SPTorrentResumeReference] = []
        for index in 0..<11 {
            let descriptor = try descriptor(index + 10)
            let reference = try store.reference(for: descriptor, file: descriptor.files[0])
            references.append(reference)
            RecentPlays.record(path: "/virtual/\(descriptor.hash)/episode.mkv", title: descriptor.name,
                               position: Double(index + 3), duration: 1000, torrent: reference,
                               defaults: defaults, torrentStore: store)
        }
        try check(RecentPlays.load(defaults: defaults).count == RecentPlays.capacity, "torrent history remains bounded to ten recent entries")
        let sidecars = try FileManager.default.contentsOfDirectory(at: metadata, includingPropertiesForKeys: nil).filter { $0.pathExtension == "torrent" }
        try check(sidecars.count == 10 && !FileManager.default.fileExists(atPath: metadata.appendingPathComponent(references[0].hash + ".torrent").path),
                  "ledger eviction prunes the oldest managed torrent metadata")
        defaults.synchronize()
        let restartedDefaults = UserDefaults(suiteName: suite)!
        let restartedStore = SPTorrentResumeStore(directory: metadata)
        let restored = RecentPlays.load(defaults: restartedDefaults).first!
        if case .torrentFile(let url) = try restartedStore.resolve(restored.torrent!) {
            try check(FileManager.default.fileExists(atPath: url.path), "fresh store instance resolves durable metainfo after ledger reload")
        } else { throw Failure.check("expected durable metainfo source") }
        RecentPlays.clear(defaults: defaults, torrentStore: store)
        try check(RecentPlays.load(defaults: defaults).isEmpty && (try FileManager.default.contentsOfDirectory(at: metadata, includingPropertiesForKeys: nil)).filter { $0.pathExtension == "torrent" }.isEmpty,
                  "clear removes ledger and managed torrent sidecars")
        try check((try Data(contentsOf: movie)) == Data("user saved movie".utf8), "cleanup never removes saved media")
        let afterClear = try store.reference(for: first, file: first.files[0])
        RecentPlays.record(path: identity, title: "Episode 10", position: 160, duration: 600,
                           insert: false, torrent: afterClear, defaults: defaults, torrentStore: store)
        try check(RecentPlays.load(defaults: defaults).isEmpty && !FileManager.default.fileExists(atPath: managedFile.path),
                  "closing an existing player after clear cannot recreate history or orphan metadata")
        print("Torrent recents checks passed (\(assertions) assertions).")
    }
}

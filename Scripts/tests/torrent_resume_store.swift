import Foundation
import Darwin

@main @MainActor
struct TorrentResumeStoreChecks {
    static var checks = 0
    nonisolated static let file = SPTorrentFile(id: 4, path: "Show/Season 1/Film.mkv", length: 123)

    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("khua-resume-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let directory = root.appendingPathComponent("private/metadata", isDirectory: true)
        let store = SPTorrentResumeStore(directory: directory)
        check(!fm.fileExists(atPath: directory.path), "initialization performs no filesystem writes")
        let first = try descriptor("first")
        let reference = try store.reference(for: first, file: file)
        check(reference.hash == first.hash && reference.filePath == file.path && reference.length == 123 && reference.fileID == 4,
              "reference preserves stable hash/path/length and optional ID hint")
        if case .metainfo = reference.source { check(true, "original metadata takes precedence over link") }
        else { fatalError("expected metainfo source") }
        let sidecar = directory.appendingPathComponent(first.hash + ".torrent")
        try check(Data(contentsOf: sidecar) == first.originalTorrentData, "sidecar contains the original bytes")
        check(mode(directory) == 0o700 && mode(sidecar) == 0o600, "directory and sidecar have private permissions")
        let encoded = try JSONEncoder().encode(reference)
        let decoded = try JSONDecoder().decode(SPTorrentResumeReference.self, from: encoded)
        check(decoded == reference, "Codable reference survives restart")
        let restarted = SPTorrentResumeStore(directory: directory)
        if case .torrentFile(let url) = try restarted.resolve(decoded) {
            let resolvedData = try Data(contentsOf: url)
            check(url == sidecar && resolvedData == first.originalTorrentData,
                  "restarted store resolves app-owned source")
        } else { fatalError("expected torrent sidecar") }

        let magnetDirectory = root.appendingPathComponent("magnet-only", isDirectory: true)
        let magnetStore = SPTorrentResumeStore(directory: magnetDirectory)
        let magnet = "magnet:?xt=urn:btih:" + first.hash + "&tr=https%3A%2F%2Ftracker.example%2Fannounce%3Fpasskey%3Doriginal&tr=https%3A%2F%2Fmember%3Asecret%40tracker.example%2Fannounce&dn=Original%20Name"
        let magnetic = SPTorrentDescriptor(leaseID: UUID(), hash: first.hash, name: "Original Name", files: [file], originalLink: magnet)
        let magneticReference = try magnetStore.reference(for: magnetic, file: file)
        if case .magnet(let resolved) = try magnetStore.resolve(magneticReference) {
            check(resolved == magnet, "original tracker parameters are preserved exactly")
        } else { fatalError("expected magnet") }
        check(!fm.fileExists(atPath: magnetDirectory.path), "magnet history needs no sidecar or storage directory")

        for badLink in ["http://user:password@127.0.0.1:8090/stream?link=" + first.hash,
                        "magnet:?xt=urn:btih:" + first.hash + "&xs=http%3A%2F%2Fuser%3Apassword%40127.0.0.1%3A8090%2Fstream",
                        "magnet:?xt=urn:btih:" + first.hash + "&xs=http%3A%2F%2F127.0.0.1%3A8090%2Fplay%2Fid",
                        "magnet:?xt=urn:btih:" + String(repeating: "f", count: 40)] {
            let bad = SPTorrentDescriptor(leaseID: UUID(), hash: first.hash, name: "Bad", files: [file], originalLink: badLink)
            expectFailure("worker URLs, credentials and wrong magnet hashes are rejected") { _ = try store.reference(for: bad, file: file) }
        }
        let noSource = SPTorrentDescriptor(leaseID: UUID(), hash: first.hash, name: "Missing", files: [file], originalLink: nil)
        expectFailure("missing original source is explicit") { _ = try store.reference(for: noSource, file: file) }
        let wrongBytes = SPTorrentDescriptor(leaseID: UUID(), hash: first.hash, name: "Wrong", files: [file], originalLink: magnet,
                                            originalTorrentData: try descriptor("different").originalTorrentData)
        expectFailure("metainfo hash mismatch is rejected despite a valid magnet fallback") { _ = try store.reference(for: wrongBytes, file: file) }
        let hugeBytes = SPTorrentDescriptor(leaseID: UUID(), hash: first.hash, name: "Huge", files: [file], originalLink: nil,
                                           originalTorrentData: Data(repeating: 0, count: 32 * 1_024 * 1_024 + 1))
        expectFailure("metadata over 32 MiB is rejected before persistence") { _ = try store.reference(for: hugeBytes, file: file) }
        let unknownFile = SPTorrentFile(id: 9, path: "Other.mkv", length: 1)
        expectFailure("a file outside the descriptor cannot create a reference") { _ = try store.reference(for: first, file: unknownFile) }

        for (key, value) in [("hash", "../escape" as Any), ("hash", first.hash.uppercased()),
                             ("torrentName", ""), ("torrentName", "bad\0name"), ("length", 0), ("fileID", 0),
                             ("filePath", "/absolute.mkv"), ("filePath", "../escape.mkv"), ("filePath", "a/../b.mkv"),
                             ("filePath", "a/./b.mkv"), ("filePath", "a//b.mkv"), ("filePath", "a\\b.mkv"),
                             ("filePath", "a\0b.mkv"), ("filePath", "a/"), ("filePath", String(repeating: "a", count: 8_193))] {
            var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            object[key] = value
            let corrupt = try JSONSerialization.data(withJSONObject: object)
            expectFailure("corrupt history fields fail decoding") { _ = try JSONDecoder().decode(SPTorrentResumeReference.self, from: corrupt) }
        }
        var sourceInjection = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        sourceInjection["source"] = ["magnet": ["_0": "http://user:secret@127.0.0.1:8090/stream"]]
        let injected = try JSONSerialization.data(withJSONObject: sourceInjection)
        expectFailure("source injection in persisted JSON fails decoding") { _ = try JSONDecoder().decode(SPTorrentResumeReference.self, from: injected) }

        try Data("broken".utf8).write(to: sidecar)
        expectFailure("corrupt sidecar fails resolution") { _ = try restarted.resolve(reference) }
        _ = try store.reference(for: first, file: file)
        try descriptor("other").originalTorrentData!.write(to: sidecar)
        expectFailure("valid bencode with another hash fails resolution") { _ = try restarted.resolve(reference) }
        let oversizedFD = Darwin.open(sidecar.path, O_WRONLY | O_TRUNC)
        check(oversizedFD >= 0 && ftruncate(oversizedFD, off_t(32 * 1_024 * 1_024 + 1)) == 0, "oversized sparse fixture is created")
        close(oversizedFD)
        expectFailure("oversized on-disk source is bounded before read") { _ = try restarted.resolve(reference) }
        try fm.removeItem(at: sidecar)
        expectFailure("deleted sidecar reports missing source") { _ = try restarted.resolve(reference) }

        let external = root.appendingPathComponent("user-original.torrent")
        try first.originalTorrentData!.write(to: external)
        try fm.createSymbolicLink(at: sidecar, withDestinationURL: external)
        expectFailure("sidecar symlink cannot be resolved") { _ = try restarted.resolve(reference) }
        expectFailure("sidecar symlink cannot be overwritten") { _ = try store.reference(for: first, file: file) }
        store.prune(keeping: [])
        let externalData = try Data(contentsOf: external)
        check(fm.fileExists(atPath: sidecar.path) && externalData == first.originalTorrentData,
              "prune preserves symlinks and their external targets")
        try fm.removeItem(at: sidecar)
        let targetDirectory = root.appendingPathComponent("external-directory", isDirectory: true)
        try fm.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let linkedDirectory = root.appendingPathComponent("linked-directory", isDirectory: true)
        try fm.createSymbolicLink(at: linkedDirectory, withDestinationURL: targetDirectory)
        let linkedStore = SPTorrentResumeStore(directory: linkedDirectory.appendingPathComponent("metadata", isDirectory: true))
        expectFailure("symlinked ancestor directory cannot redirect a write") { _ = try linkedStore.reference(for: first, file: file) }
        try check(fm.contentsOfDirectory(atPath: targetDirectory.path).isEmpty, "ancestor symlink target is untouched")

        let quotaDirectory = root.appendingPathComponent("quota", isDirectory: true)
        let quotaStore = SPTorrentResumeStore(directory: quotaDirectory)
        var references: [SPTorrentResumeReference] = []
        for index in 0..<11 { references.append(try quotaStore.reference(for: descriptor("quota-\(index)"), file: file)) }
        try check(fm.contentsOfDirectory(atPath: quotaDirectory.path).filter { $0.hasSuffix(".torrent") }.count == 10,
              "eleventh metadata file evicts the oldest and stays bounded at ten")
        expectFailure("oldest source is evicted") { _ = try quotaStore.resolve(references[0]) }
        _ = try quotaStore.resolve(references[10])
        check(true, "newest quota source remains readable")
        let movie = quotaDirectory.appendingPathComponent("movie.mkv")
        let saved = quotaDirectory.appendingPathComponent("saved-file.torrent")
        let managedDirectory = quotaDirectory.appendingPathComponent(String(repeating: "a", count: 40) + ".torrent", isDirectory: true)
        try Data("movie".utf8).write(to: movie)
        try Data("saved".utf8).write(to: saved)
        try fm.createDirectory(at: managedDirectory, withIntermediateDirectories: true)
        quotaStore.prune(keeping: [references[10]])
        try check(fm.contentsOfDirectory(atPath: quotaDirectory.path).filter { $0.hasSuffix(".torrent") }.count == 3,
              "prune keeps one managed sidecar, an unrelated saved file and a directory")
        check(fm.fileExists(atPath: movie.path) && fm.fileExists(atPath: saved.path) && fm.fileExists(atPath: managedDirectory.path),
              "prune never deletes movies, unrelated files or directories")

        let concurrentDirectory = root.appendingPathComponent("concurrent", isDirectory: true)
        let fixtures = try (0..<24).map { try descriptor("concurrent-\($0)") }
        let failureLock = NSLock()
        nonisolated(unsafe) var failures = 0
        DispatchQueue.concurrentPerform(iterations: fixtures.count) { index in
            do {
                _ = try SPTorrentResumeStore(directory: concurrentDirectory).reference(for: fixtures[index], file: file)
            } catch {
                failureLock.lock(); failures += 1; failureLock.unlock()
            }
        }
        check(failures == 0, "independent concurrent store instances write without failure")
        try check(fm.contentsOfDirectory(atPath: concurrentDirectory.path).filter { $0.hasSuffix(".torrent") }.count == 10,
              "directory lock enforces the quota across independent concurrent instances")
        try check(fm.contentsOfDirectory(atPath: concurrentDirectory.path).allSatisfy { !$0.hasSuffix(".torrent-tmp") },
              "atomic write temporary files are cleaned up")
        print("Torrent resume store checks passed (\(checks) checks)")
    }

    nonisolated static func descriptor(_ name: String) throws -> SPTorrentDescriptor {
        let data = Data(("d4:infod4:name\(name.utf8.count):" + name + "ee").utf8)
        return SPTorrentDescriptor(leaseID: UUID(), hash: try SPTorrentInput.infoHash(in: data), name: name,
                                   files: [file], originalLink: "http://user:worker-password@127.0.0.1:8090/stream",
                                   originalTorrentData: data)
    }

    static func mode(_ url: URL) -> mode_t {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { fatalError("missing permissions fixture") }
        return info.st_mode & 0o777
    }

    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        guard try condition() else { fatalError(message) }
        checks += 1
    }

    static func expectFailure(_ message: String, _ action: () throws -> Void) {
        do { try action(); fatalError(message) } catch { checks += 1 }
    }
}

import Darwin
import Foundation

private actor Rejections {
    private var value = 0
    func note() { value += 1 }
    func count() -> Int { value }
}

@main @MainActor private struct TorrentPreviewCacheChecks {
    private static var checks = 0
    private static func check(_ value: Bool, _ message: String) {
        precondition(value, message)
        checks += 1
    }
    static func main() async throws {
        typealias Cache = SPTorrentPreviewCacheStore
        let hash = String(repeating: "aB", count: 20)
        let identity = Cache.Identity(infoHash: hash, fileID: 5, fileLength: 8_140_713_626)!
        check(identity == Cache.Identity(infoHash: hash.lowercased(), fileID: 5, fileLength: 8_140_713_626), "Hash casing is not identity")
        check(identity.directoryName.count == 64, "Digest uses fixed-size hex")
        check(!identity.directoryName.contains(hash.lowercased()), "Raw torrent hash is absent from namespace")
        check(identity != Cache.Identity(infoHash: hash, fileID: 6, fileLength: 8_140_713_626), "File selection changes namespace")
        check(identity != Cache.Identity(infoHash: hash, fileID: 5, fileLength: 8_140_713_627), "Source length changes namespace")
        check(identity != Cache.Identity(infoHash: hash, fileID: 5, fileLength: 8_140_713_626, schemaVersion: 2), "Schema changes namespace")
        check(identity != Cache.Identity(infoHash: hash, fileID: 5, fileLength: 8_140_713_626, videoStreamIndex: 0), "Explicit video selection changes namespace")
        for malformed in ["", "a", String(repeating: "g", count: 40), String(repeating: "a", count: 41), "magnet:?xt=urn:btih:" + hash, String(repeating: "а", count: 40), "../" + hash] {
            check(Cache.Identity(infoHash: malformed, fileID: 0, fileLength: 1) == nil, "Reject malformed identity")
        }
        check(Cache.Identity(infoHash: String(repeating: "f", count: 64), fileID: 0, fileLength: 1) != nil, "v2 hash allowed")
        check(Cache.Identity(infoHash: hash, fileID: -1, fileLength: 1) == nil, "Reject negative file ID")
        check(Cache.Identity(infoHash: hash, fileID: 0, fileLength: 0) == nil, "Reject empty file")
        check(Cache.Identity(infoHash: hash, fileID: 0, fileLength: 1, schemaVersion: 0) == nil, "Reject invalid schema")
        check(Cache.Identity(infoHash: hash, fileID: 0, fileLength: 1, videoStreamIndex: -1) == nil, "Reject invalid stream")
        guard let canonical = Darwin.realpath(CommandLine.arguments[1], nil) else { exit(1) }
        let owned = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        free(canonical)
        let support = owned.appendingPathComponent("Application Support", isDirectory: true)
        let pure = try Cache.directory(for: identity, applicationSupport: support)
        check(!FileManager.default.fileExists(atPath: pure.path), "Pure lookup does not create filesystem entries")
        check(pure.path.hasPrefix(support.path + "/Kinolet/Previews/"), "Directory stays under dedicated namespace")
        do {
            _ = try Cache.directory(for: identity, applicationSupport: URL(string: "https://example.invalid/")!)
            preconditionFailure("Network base accepted")
        } catch Cache.Failure.invalidBaseDirectory { checks += 1 }
        let prepared = try await Cache.prepareDirectory(for: identity, applicationSupport: support)
        check(prepared == pure, "Prepared path matches pure identity path")
        var leaf = stat()
        check(Darwin.lstat(prepared.path, &leaf) == 0 && leaf.st_mode & 0o777 == 0o700, "Leaf is private0700")
        let entries = try FileManager.default.contentsOfDirectory(atPath: prepared.path)
        check(entries.isEmpty, "Identity helper writes no credentials or metadata")
        let preparedAgain = try await Cache.prepareDirectory(for: identity, applicationSupport: support)
        check(preparedAgain == prepared, "Reopening stable cache reuses directory")
        let image = prepared.appendingPathComponent("existing-image.jpg")
        try Data([1, 2, 3]).write(to: image)
        _ = try await Cache.prepareDirectory(for: identity, applicationSupport: support)
        check(try Data(contentsOf: image) == Data([1, 2, 3]), "Preparing cache preserves existing preview data")
        let outside = owned.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let symlinkSupport = owned.appendingPathComponent("symlink-support", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlinkSupport, withDestinationURL: outside)
        do {
            _ = try await Cache.prepareDirectory(for: identity, applicationSupport: symlinkSupport)
            preconditionFailure("Followed symlink ancestor")
        } catch { checks += 1 }
        check(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("Kinolet").path), "Symlink target untouched")
        let leafLinkSupport = owned.appendingPathComponent("leaf-link", isDirectory: true)
        let leafParent = leafLinkSupport.appendingPathComponent("Kinolet/Previews", isDirectory: true)
        try FileManager.default.createDirectory(at: leafParent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: leafParent.appendingPathComponent(identity.directoryName), withDestinationURL: outside)
        do {
            _ = try await Cache.prepareDirectory(for: identity, applicationSupport: leafLinkSupport)
            preconditionFailure("Followed cache leaf symlink")
        } catch { checks += 1 }
        var outsideInfo = stat()
        check(Darwin.lstat(outside.path, &outsideInfo) == 0 && outsideInfo.st_mode & 0o777 == 0o755, "No chmod of symlink target")
        let weakSupport = owned.appendingPathComponent("unsafe-support", isDirectory: true)
        try FileManager.default.createDirectory(at: weakSupport, withIntermediateDirectories: true)
        _ = Darwin.chmod(weakSupport.path, 0o777)
        do {
            _ = try await Cache.prepareDirectory(for: identity, applicationSupport: weakSupport)
            preconditionFailure("Accepted writable application support root")
        } catch Cache.Failure.unsafeDirectory { checks += 1 }

        // A suspended writer simulates blocked disk work. Callers beyond the
        // single admitted operation must finish Busy without joining its queue.
        let blockedQueue = DispatchQueue(label: "owned-preview-cache-stalled-disk")
        blockedQueue.suspend()
        let limited = Cache.DirectoryPreparer(maximumPending: 1, queue: blockedQueue)
        let refusals = Rejections()
        let attempts = (0..<8).map { _ in
            Task.detached { () -> Int in
                do { _ = try await limited.prepare(directory: pure); return 1 }
                catch Cache.Failure.busy { await refusals.note(); return 0 }
                catch { return -1 }
            }
        }
        let deadline = Date().addingTimeInterval(5)
        while await refusals.count() < 7 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let rejectedBeforeResume = await refusals.count()
        blockedQueue.resume()
        var results: [Int] = []
        for attempt in attempts { results.append(await attempt.value) }
        check(rejectedBeforeResume == 7, "Stalled directory work does not accumulate unbounded tasks")
        check(results.filter { $0 == 1 }.count == 1 && results.filter { $0 == 0 }.count == 7,
              "Only the bounded admitted operation creates/reuses its directory")

        let cancelledIdentity = Cache.Identity(infoHash: hash, fileID: 42, fileLength: 1)!
        let cancelledDirectory = try Cache.directory(for: cancelledIdentity, applicationSupport: support)
        let cancelled = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Cache.prepareDirectory(for: cancelledIdentity, applicationSupport: support)
        }
        do { _ = try await cancelled.value; preconditionFailure("Cancelled caller was admitted") }
        catch is CancellationError { checks += 1 }
        check(!FileManager.default.fileExists(atPath: cancelledDirectory.path),
              "Cancellation before admission creates no stale-file directory")
        print("Torrent preview cache checks passed (\(checks) assertions).")
    }
}

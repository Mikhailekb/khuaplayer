import CryptoKit
import Darwin
import Foundation

/// The preview namespace is independent of a worker URL, port, lease or name.
/// Only the digest enters the filesystem; credentials and media names are absent.
enum SPTorrentPreviewCacheStore {
    struct Identity: Sendable, Equatable {
        let directoryName: String

        init?(infoHash: String, fileID: Int, fileLength: Int64,
              schemaVersion: Int = 1, videoStreamIndex: Int? = nil) {
            let bytes = Array(infoHash.utf8)
            guard (bytes.count == 40 || bytes.count == 64),
                  bytes.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  fileID >= 0, fileLength > 0, schemaVersion > 0,
                  videoStreamIndex == nil || videoStreamIndex! >= 0 else { return nil }
            let canonical = "kinolet-torrent-previews\n\(schemaVersion)\n\(infoHash.lowercased())\n\(fileID)\n\(fileLength)\n\(videoStreamIndex ?? -1)\n"
            directoryName = SHA256.hash(data: Data(canonical.utf8))
                .map { String(format: "%02x", $0) }.joined()
        }
    }

    enum Failure: Error, Equatable, Sendable {
        case invalidBaseDirectory, unsafeDirectory, unavailable(Int32), busy
    }

    static func directory(for identity: Identity, applicationSupport: URL? = nil) throws -> URL {
        let base = applicationSupport ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        guard base.isFileURL, base.host == nil || base.host == "localhost",
              base.query == nil, base.fragment == nil, base.path.hasPrefix("/"),
              !base.pathComponents.contains(".."), !base.pathComponents.contains(".") else {
            throw Failure.invalidBaseDirectory
        }
        return base.appendingPathComponent("Kinolet", isDirectory: true)
            .appendingPathComponent("Previews", isDirectory: true)
            .appendingPathComponent(identity.directoryName, isDirectory: true)
    }

    static func prepareDirectory(for identity: Identity, applicationSupport: URL? = nil) async throws -> URL {
        let result = try await DirectoryPreparer.shared.prepare(
            directory: directory(for: identity, applicationSupport: applicationSupport))
        try Task.checkCancellation()
        return result
    }

    /// Admission is bounded even when the disk is stalled. No filesystem work
    /// happens on the caller's actor or on the playback/decoder thread.
    final class DirectoryPreparer: @unchecked Sendable {
        static let shared = DirectoryPreparer()
        private let queue: DispatchQueue
        private let maximumPending: Int
        private let lock = NSLock()
        private var pending = 0

        init(maximumPending: Int = 16, queue: DispatchQueue? = nil) {
            self.maximumPending = max(1, min(16, maximumPending))
            self.queue = queue ?? DispatchQueue(label: "kinolet.preview-directory", qos: .utility)
        }

        func prepare(directory: URL) async throws -> URL {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard pending < maximumPending else {
                    lock.unlock()
                    continuation.resume(throwing: Failure.busy)
                    return
                }
                pending += 1
                lock.unlock()
                queue.async { [self] in
                    let result = Result { try Self.createPrivateDirectory(directory) }
                    lock.lock()
                    pending -= 1
                    lock.unlock()
                    continuation.resume(with: result)
                }
            }
        }

        private static func createPrivateDirectory(_ directory: URL) throws -> URL {
            guard directory.isFileURL, directory.path.hasPrefix("/") else {
                throw Failure.invalidBaseDirectory
            }
            let components = directory.pathComponents.filter { $0 != "/" }
            guard components.count >= 4, !components.contains("."), !components.contains(".."),
                  components.suffix(3).dropLast().elementsEqual(["Kinolet", "Previews"]),
                  components.last!.utf8.count == 64,
                  components.last!.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw Failure.invalidBaseDirectory
            }
            var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard fd >= 0 else { throw Failure.unavailable(errno) }
            defer { Darwin.close(fd) }
            for (index, component) in components.enumerated() {
                guard !component.contains("\0") else { throw Failure.invalidBaseDirectory }
                var next = Darwin.openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT {
                    guard Darwin.mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else {
                        throw Failure.unavailable(errno)
                    }
                    next = Darwin.openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw Failure.unavailable(errno) }
                Darwin.close(fd)
                fd = next
                // The application-support root and our own namespaces must be
                // owned and not writable by another user. Ancestors are read only.
                if index >= components.count - 4 {
                    var info = stat()
                    guard Darwin.fstat(fd, &info) == 0,
                          info.st_uid == Darwin.getuid(),
                          info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                          info.st_mode & 0o022 == 0 else { throw Failure.unsafeDirectory }
                }
            }
            guard Darwin.fchmod(fd, 0o700) == 0 else { throw Failure.unavailable(errno) }
            return directory
        }
    }
}

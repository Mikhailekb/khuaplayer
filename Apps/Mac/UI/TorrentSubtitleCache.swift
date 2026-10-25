import CryptoKit
import Darwin
import Foundation

@_silgen_name("flock")
private func spTorrentSubtitleFlock(_ fd: Int32, _ operation: Int32) -> Int32

/// A cancellation handle may cross the actor boundary only to abort the reader.
/// The reader itself remains owned by one background extraction operation.
final class SPTorrentSubtitleCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var abort: (@Sendable () -> Void)?

    var isCancelled: Bool { lock.withLock { cancelled } }

    func setAbort(_ action: (@Sendable () -> Void)?) {
        lock.lock()
        let invoke = cancelled && action != nil
        abort = cancelled ? nil : action
        lock.unlock()
        if invoke { action?() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let action = abort
        abort = nil
        lock.unlock()
        action?()
    }

    func check() throws {
        if isCancelled || Task.isCancelled { throw CancellationError() }
    }
}

protocol SPTorrentSubtitleExtracting: Sendable {
    func export(plan: SPTorrentSubtitleCache.Plan,
                shouldPause: @escaping @Sendable () -> Bool,
                cancellation: SPTorrentSubtitleCancellation) throws -> String
}

enum SPTorrentSubtitleCacheFailure: Error, Sendable, Equatable {
    case invalidPlan, unsupported, extraction, unsafeStorage, storage, invalidText
}

/// A selected embedded text track is extracted independently of the foreground
/// demuxer. Only a completed, bounded export can replace its streaming track.
@MainActor
final class SPTorrentSubtitleCache {
    struct Identity: Equatable, Hashable, Sendable {
        let hash: String
        let fileID: Int
        let length: Int64
        let trackID: Int

        init(hash: String, fileID: Int, length: Int64, trackID: Int) {
            self.hash = hash.lowercased()
            self.fileID = fileID
            self.length = length
            self.trackID = trackID
        }

        fileprivate var valid: Bool {
            (hash.utf8.count == 40 || hash.utf8.count == 64) && hash.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            } && fileID > 0 && length > 0 && trackID >= 0 && trackID <= Int(Int32.max)
        }
    }

    struct Plan: Equatable, Sendable {
        let identity: Identity
        /// An in-memory playback epoch; it never enters the persistent key.
        let sessionID: UUID
        let backgroundURL: URL
        let expectedMediaURL: URL
        let timelineOriginUs: Int64

        fileprivate var valid: Bool {
            guard identity.valid, timelineOriginUs != Int64.min,
                  backgroundURL.absoluteString.utf8.count <= 65_536,
                  expectedMediaURL.absoluteString.utf8.count <= 65_536,
                  let background = URLComponents(url: backgroundURL, resolvingAgainstBaseURL: false),
                  let expected = URLComponents(url: expectedMediaURL, resolvingAgainstBaseURL: false),
                  background.scheme?.lowercased() == "http", expected.scheme?.lowercased() == "http",
                  let host = background.host?.lowercased(),
                  ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host),
                  expected.host?.lowercased() == host, expected.port == background.port,
                  expected.path == background.path else { return false }
            // Only a worker URL for this exact file may be used; credentials
            // and consumer tokens remain solely in the in-memory plan.
            func single(_ name: String, in components: URLComponents) -> String? {
                let items = (components.queryItems ?? []).filter { $0.name == name }
                guard items.count == 1, let value = items[0].value, !value.isEmpty else { return nil }
                return value
            }
            func matches(_ components: URLComponents) -> Bool {
                single("link", in: components)?.lowercased() == identity.hash &&
                    single("index", in: components).flatMap(Int.init) == identity.fileID
            }
            guard matches(background), matches(expected),
                  !(expected.queryItems ?? []).contains(where: {
                      $0.name == "playback_background" || $0.name == "playback_parent"
                  }),
                  let primary = single("playback_consumer", in: expected),
                  let primaryID = UUID(uuidString: primary),
                  single("playback_background", in: background) == "1",
                  let parent = single("playback_parent", in: background), parent == primary,
                  let consumer = single("playback_consumer", in: background),
                  let consumerID = UUID(uuidString: consumer), consumerID != primaryID else { return false }
            return true
        }

        fileprivate var persistentKey: String {
            // Delimiters cannot occur in the validated hexadecimal hash or
            // decimal integers. No port, credential, URL or filename is stored.
            let key = "1\n\(identity.hash)\n\(identity.fileID)\n\(identity.length)\n\(identity.trackID)\n\(timelineOriginUs)\n"
            return SPTorrentSubtitleStore.digest(Data(key.utf8))
        }
    }

    enum State: Sendable, Equatable { case idle, loading, ready, failed }
    struct Snapshot: Sendable, Equatable {
        let identity: Identity?
        let state: State
        let cacheURL: URL?
        let failure: SPTorrentSubtitleCacheFailure?
        static let idle = Snapshot(identity: nil, state: .idle, cacheURL: nil, failure: nil)
    }

    private(set) var snapshot: Snapshot = .idle
    var isPreparing: Bool { snapshot.state == .loading }
    var onChange: (@MainActor (Snapshot) -> Void)?
    private let store: SPTorrentSubtitleStore
    private let extractor: any SPTorrentSubtitleExtracting
    private var plan: Plan?
    private var generation = UUID()
    private var cancellation: SPTorrentSubtitleCancellation?
    private var task: Task<Void, Never>?

    init(store: SPTorrentSubtitleStore = .shared,
         extractor: any SPTorrentSubtitleExtracting = SPTorrentNativeSubtitleExtractor()) {
        self.store = store
        self.extractor = extractor
    }

    deinit {
        cancellation?.cancel()
        task?.cancel()
    }

    /// A failed plan stays quiet until cancelled/replaced. The rolling cache
    /// remains the fallback; frequent player callbacks cannot repeat a full scan.
    func start(plan next: Plan,
               shouldPause: @escaping @Sendable () -> Bool,
               isCurrent: @escaping @MainActor () -> Bool,
               adopt: @escaping @MainActor (URL, Int) async -> Bool) {
        if plan == next, snapshot.state != .idle { return }
        invalidateWork()
        plan = next
        guard next.valid else {
            publish(.init(identity: next.identity, state: .failed, cacheURL: nil, failure: .invalidPlan))
            return
        }
        let token = UUID()
        generation = token
        let abort = SPTorrentSubtitleCancellation()
        cancellation = abort
        publish(.init(identity: next.identity, state: .loading, cacheURL: nil, failure: nil))
        guard generation == token, plan == next else { return }
        let store = self.store
        let extractor = self.extractor
        task = Task { @MainActor [weak self] in
            let worker = Task.detached(priority: .utility) { () throws -> URL in
                try abort.check()
                if let cached = try store.lookup(plan: next) { return cached }
                // A second window can miss while the first is still exporting.
                // Wait for its process-wide producer grant, then check disk
                // again before opening another reader for that same track.
                while shouldPause() {
                    try abort.check()
                    try await Task.sleep(for: .milliseconds(50))
                }
                try abort.check()
                if let cached = try store.lookup(plan: next) { return cached }
                let text = try extractor.export(plan: next, shouldPause: shouldPause, cancellation: abort)
                try abort.check()
                return try store.save(text: text, plan: next, cancellation: abort)
            }
            do {
                let url = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    abort.cancel()
                    worker.cancel()
                }
                guard let self, !Task.isCancelled, !abort.isCancelled,
                      self.generation == token, self.plan == next else { return }
                guard isCurrent() else { self.cancel(); return }
                let accepted = await adopt(url, next.identity.trackID)
                guard !Task.isCancelled, !abort.isCancelled,
                      self.generation == token, self.plan == next else { return }
                guard isCurrent() else { self.cancel(); return }
                self.task = nil
                self.cancellation = nil
                self.publish(.init(identity: next.identity, state: accepted ? .ready : .failed,
                                   cacheURL: url, failure: accepted ? nil : .extraction))
            } catch is CancellationError {
                // A replacement owns state now. Cancellation cannot clear it.
            } catch {
                guard let self, !Task.isCancelled, self.generation == token, self.plan == next else { return }
                self.task = nil
                self.cancellation = nil
                self.publish(.init(identity: next.identity, state: .failed, cacheURL: nil,
                                   failure: error as? SPTorrentSubtitleCacheFailure ?? .extraction))
            }
        }
    }

    func cancel() {
        invalidateWork()
        plan = nil
        if snapshot != .idle { publish(.idle) }
    }

    private func invalidateWork() {
        generation = UUID()
        cancellation?.cancel()
        cancellation = nil
        task?.cancel()
        task = nil
    }

    private func publish(_ value: Snapshot) {
        guard value != snapshot else { return }
        snapshot = value
        onChange?(value)
    }
}

private final class SPTorrentSubtitleReaderBox: @unchecked Sendable {
    let reader: SPCaptionSubtitleReader
    init(_ reader: SPCaptionSubtitleReader) { self.reader = reader }
    func abort() { reader.abort() }
}

struct SPTorrentNativeSubtitleExtractor: SPTorrentSubtitleExtracting {
    func export(plan: SPTorrentSubtitleCache.Plan,
                shouldPause: @escaping @Sendable () -> Bool,
                cancellation: SPTorrentSubtitleCancellation) throws -> String {
        try cancellation.check()
        let reader = SPCaptionSubtitleReader(path: plan.backgroundURL.absoluteString,
                                             subtitleStreamIndex: Int32(plan.identity.trackID))
        reader.timelineOriginUs = plan.timelineOriginUs
        reader.expectedSourceLength = plan.identity.length
        let owned = SPTorrentSubtitleReaderBox(reader)
        cancellation.setAbort { owned.abort() }
        defer { cancellation.setAbort(nil) }
        guard let text = reader.exportWholeTrack(shouldPause: shouldPause) else {
            try cancellation.check()
            if let error = reader.lastError {
                let code = (error as NSError).code
                if code == -Int(ENOTSUP) || code == -Int(ENOSYS) {
                    throw SPTorrentSubtitleCacheFailure.unsupported
                }
            }
            throw SPTorrentSubtitleCacheFailure.extraction
        }
        try cancellation.check()
        return text
    }
}

/// Persistent UTF-8 text and a completion receipt. Both files must match before
/// adoption; a crash between their atomic replacements leaves a cache miss.
/// There is no eviction by age or by the rolling video-cache policy.
final class SPTorrentSubtitleStore: @unchecked Sendable {
    static let maximumTextBytes = 8 * 1024 * 1024
    static let shared = SPTorrentSubtitleStore(directory:
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Kinolet/EmbeddedSubtitles", isDirectory: true))

    private struct Receipt: Codable {
        let schema: Int
        let key: String
        let bytes: Int
        let sha256: String
        let complete: Bool
    }

    private let directory: URL
    private let lock = NSLock()
    init(directory: URL) { self.directory = directory }

    fileprivate static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func lookup(plan: SPTorrentSubtitleCache.Plan) throws -> URL? {
        guard plan.valid else { throw SPTorrentSubtitleCacheFailure.invalidPlan }
        lock.lock()
        defer { lock.unlock() }
        guard let fd = try openDirectory(create: false) else { return nil }
        defer { close(fd) }
        return try lookupLocked(plan: plan, fd: fd)
    }

    func save(text: String, plan: SPTorrentSubtitleCache.Plan,
              cancellation: SPTorrentSubtitleCancellation = SPTorrentSubtitleCancellation()) throws -> URL {
        guard plan.valid else { throw SPTorrentSubtitleCacheFailure.invalidPlan }
        guard text.utf8.count <= Self.maximumTextBytes else { throw SPTorrentSubtitleCacheFailure.invalidText }
        let data = Data(text.utf8)
        guard Self.validText(data) else { throw SPTorrentSubtitleCacheFailure.invalidText }
        try cancellation.check()
        lock.lock()
        defer { lock.unlock() }
        guard let fd = try openDirectory(create: true) else { throw SPTorrentSubtitleCacheFailure.storage }
        defer { close(fd) }
        let key = plan.persistentKey
        let receipt = Receipt(schema: 1, key: key, bytes: data.count, sha256: Self.digest(data), complete: true)
        let receiptData = try JSONEncoder().encode(receipt)
        try writeAtomically(data, name: key + ".subtext", fd: fd, cancellation: cancellation)
        try writeAtomically(receiptData, name: key + ".json", fd: fd, cancellation: cancellation)
        guard let verified = try lookupLocked(plan: plan, fd: fd) else { throw SPTorrentSubtitleCacheFailure.storage }
        return verified
    }

    private static func validText(_ data: Data) -> Bool {
        guard !data.contains(0), String(data: data, encoding: .utf8) != nil else { return false }
        var lines = 0
        for byte in data where byte == 10 {
            lines += 1
            if lines > 1_000_000 { return false }
        }
        return true
    }

    private func lookupLocked(plan: SPTorrentSubtitleCache.Plan, fd: Int32) throws -> URL? {
        let key = plan.persistentKey
        guard let receiptData = try read(name: key + ".json", fd: fd, maximum: 4096),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: receiptData),
              receipt.schema == 1, receipt.key == key, receipt.complete,
              receipt.bytes >= 0, receipt.bytes <= Self.maximumTextBytes,
              receipt.sha256.utf8.count == 64,
              let text = try read(name: key + ".subtext", fd: fd, maximum: Self.maximumTextBytes),
              text.count == receipt.bytes, Self.digest(text) == receipt.sha256,
              Self.validText(text) else { return nil }
        return directory.appendingPathComponent(key + ".subtext", isDirectory: false)
    }

    private func openDirectory(create: Bool) throws -> Int32? {
        guard directory.isFileURL, directory.host == nil || directory.host == "localhost",
              directory.query == nil, directory.fragment == nil,
              directory.path.hasPrefix("/"), !directory.path.contains("\0") else {
            throw SPTorrentSubtitleCacheFailure.unsafeStorage
        }
        var path = directory.path
        if path == "/var" || path.hasPrefix("/var/") || path == "/tmp" || path.hasPrefix("/tmp/") {
            path = "/private" + path
        }
        let components = (path as NSString).pathComponents.filter { $0 != "/" }
        guard !components.isEmpty, components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw SPTorrentSubtitleCacheFailure.unsafeStorage
        }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw SPTorrentSubtitleCacheFailure.storage }
        for component in components {
            if create, mkdirat(fd, component, 0o700) != 0, errno != EEXIST {
                close(fd); throw SPTorrentSubtitleCacheFailure.storage
            }
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let failure = errno
            close(fd)
            guard next >= 0 else {
                if !create && failure == ENOENT { return nil }
                throw SPTorrentSubtitleCacheFailure.unsafeStorage
            }
            fd = next
        }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFDIR, fchmod(fd, 0o700) == 0 else {
            close(fd); throw SPTorrentSubtitleCacheFailure.unsafeStorage
        }
        while spTorrentSubtitleFlock(fd, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            close(fd); throw SPTorrentSubtitleCacheFailure.storage
        }
        return fd
    }

    private func read(name: String, fd: Int32, maximum: Int) throws -> Data? {
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if file < 0 {
            if errno == ENOENT { return nil }
            throw SPTorrentSubtitleCacheFailure.unsafeStorage
        }
        defer { close(file) }
        var metadata = stat()
        guard fstat(file, &metadata) == 0, metadata.st_uid == getuid(), metadata.st_nlink == 1,
              metadata.st_mode & S_IFMT == S_IFREG, fchmod(file, 0o600) == 0 else {
            throw SPTorrentSubtitleCacheFailure.unsafeStorage
        }
        guard metadata.st_size >= 0, metadata.st_size <= maximum else { return nil }
        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw SPTorrentSubtitleCacheFailure.storage }
            if count == 0 { return data }
            guard count <= maximum - data.count else { return nil }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private func writeAtomically(_ data: Data, name: String, fd: Int32,
                                 cancellation: SPTorrentSubtitleCancellation) throws {
        var metadata = stat()
        if fstatat(fd, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
            guard metadata.st_uid == getuid(), metadata.st_nlink == 1,
                  metadata.st_mode & S_IFMT == S_IFREG else { throw SPTorrentSubtitleCacheFailure.unsafeStorage }
        } else if errno != ENOENT { throw SPTorrentSubtitleCacheFailure.storage }
        let temporary = "." + UUID().uuidString + ".subtitle-tmp"
        let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw SPTorrentSubtitleCacheFailure.storage }
        defer { close(file); _ = unlinkat(fd, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try cancellation.check()
                let count = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), min(65536, bytes.count - offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SPTorrentSubtitleCacheFailure.storage }
                offset += count
            }
        }
        try cancellation.check()
        guard fchmod(file, 0o600) == 0, fsync(file) == 0 else { throw SPTorrentSubtitleCacheFailure.storage }
        guard renameat(fd, temporary, fd, name) == 0 else { throw SPTorrentSubtitleCacheFailure.storage }
        _ = fsync(fd)
    }
}

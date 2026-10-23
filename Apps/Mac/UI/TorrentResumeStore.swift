import Foundation
import Darwin

struct SPTorrentResumeReference: Codable, Equatable, Sendable {
    enum Source: Codable, Equatable, Sendable {
        case magnet(String)
        case metainfo
    }

    let hash: String
    let torrentName: String
    let filePath: String
    let length: Int64
    let fileID: Int?
    let source: Source

    init(hash: String, torrentName: String, filePath: String, length: Int64,
         fileID: Int? = nil, source: Source) throws {
        self.hash = hash
        self.torrentName = torrentName
        self.filePath = filePath
        self.length = length
        self.fileID = fileID
        self.source = source
        try validate()
    }

    private enum CodingKeys: String, CodingKey { case hash, torrentName, filePath, length, fileID, source }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(hash: values.decode(String.self, forKey: .hash),
                          torrentName: values.decode(String.self, forKey: .torrentName),
                          filePath: values.decode(String.self, forKey: .filePath),
                          length: values.decode(Int64.self, forKey: .length),
                          fileID: values.decodeIfPresent(Int.self, forKey: .fileID),
                          source: values.decode(Source.self, forKey: .source))
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid torrent resume reference.",
                                                    underlyingError: error))
        }
    }

    fileprivate func validate() throws {
        guard SPTorrentInput.normalizedHash(hash) == hash,
              !torrentName.isEmpty, torrentName.utf8.count <= 4_096,
              !torrentName.contains("\0"), length > 0,
              fileID.map({ $0 > 0 }) ?? true,
              !filePath.isEmpty, filePath.utf8.count <= 8_192,
              !filePath.contains("\0"), !filePath.contains("\\"),
              filePath.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw SPTorrentResumeStoreError.invalidReference }
        if case .magnet(let link) = source {
            guard link.utf8.count <= 65_536, SPTorrentInput.magnetHash(link) == hash,
                  !link.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                  let components = URLComponents(string: link),
                  components.host == nil, components.user == nil, components.password == nil,
                  components.path.isEmpty else { throw SPTorrentResumeStoreError.invalidReference }
            for item in components.queryItems ?? [] {
                guard let value = item.value, let nested = URLComponents(string: value),
                      ["http", "https"].contains(nested.scheme?.lowercased() ?? "") else { continue }
                let host = nested.host?.lowercased() ?? ""
                let local = host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
                let workerPath = ["stream", "play", "playlist", "playlistall", "echo", "torrents"]
                    .contains(nested.path.split(separator: "/").first.map(String.init) ?? "")
                guard !(local && workerPath) else { throw SPTorrentResumeStoreError.invalidReference }
            }
        }
    }
}

enum SPTorrentResumeResolvedSource: Sendable {
    case magnet(String)
    case torrentFile(URL)
}

enum SPTorrentResumeStoreError: LocalizedError {
    case invalidReference
    case missingSource
    case invalidMetainfo
    case unsafeStorage
    case storageUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidReference: return "This torrent history entry is invalid."
        case .missingSource: return "The saved torrent metadata is missing. Open the original torrent again."
        case .invalidMetainfo: return "The saved torrent metadata is invalid or does not match this torrent."
        case .unsafeStorage: return "The torrent history storage is not a private regular file or directory."
        case .storageUnavailable: return "The torrent history metadata could not be saved or read."
        }
    }
}

/// Callers may use their resume queue; the lock also protects independent callers.
final class SPTorrentResumeStore: @unchecked Sendable {
    static let shared: SPTorrentResumeStore = {
        let identifier = Bundle.main.bundleIdentifier ?? "com.khua.player"
        let safeIdentifier = !identifier.isEmpty && identifier != "." && identifier != ".." && identifier.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-"
        } ? identifier : "com.khua.player"
        let directory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(safeIdentifier, isDirectory: true)
            .appendingPathComponent("Torrent Resume", isDirectory: true)
        return SPTorrentResumeStore(directory: directory)
    }()

    private let directory: URL
    private let lock = NSLock()
    private static let maximumBytes = 32 * 1_024 * 1_024
    private static let capacity = 10

    init(directory: URL) { self.directory = directory }

    func reference(for descriptor: SPTorrentDescriptor, file: SPTorrentFile) throws -> SPTorrentResumeReference {
        lock.lock()
        defer { lock.unlock() }
        guard let hash = SPTorrentInput.normalizedHash(descriptor.hash),
              descriptor.files.contains(file) else { throw SPTorrentResumeStoreError.invalidReference }
        let source: SPTorrentResumeReference.Source
        if let data = descriptor.originalTorrentData {
            guard data.count <= Self.maximumBytes, (try? SPTorrentInput.infoHash(in: data)) == hash
            else { throw SPTorrentResumeStoreError.invalidMetainfo }
            source = .metainfo
        } else if let link = descriptor.originalLink {
            source = .magnet(link)
        } else {
            throw SPTorrentResumeStoreError.missingSource
        }
        let reference = try SPTorrentResumeReference(
            hash: hash, torrentName: descriptor.name.isEmpty ? file.displayName : descriptor.name,
            filePath: file.path, length: file.length, fileID: file.id > 0 ? file.id : nil, source: source)
        if case .metainfo = source, let data = descriptor.originalTorrentData {
            let fd = try openDirectory(create: true)
            defer { close(fd) }
            try write(data, hash: hash, directoryFD: fd)
        }
        return reference
    }

    func resolve(_ reference: SPTorrentResumeReference) throws -> SPTorrentResumeResolvedSource {
        lock.lock()
        defer { lock.unlock() }
        try reference.validate()
        switch reference.source {
        case .magnet(let link): return .magnet(link)
        case .metainfo:
            let fd = try openDirectory(create: false)
            defer { close(fd) }
            let data = try read(hash: reference.hash, directoryFD: fd)
            guard (try? SPTorrentInput.infoHash(in: data)) == reference.hash
            else { throw SPTorrentResumeStoreError.invalidMetainfo }
            return .torrentFile(directory.appendingPathComponent(reference.hash + ".torrent"))
        }
    }

    func prune(keeping references: [SPTorrentResumeReference]) {
        lock.lock()
        defer { lock.unlock() }
        guard let fd = try? openDirectory(create: false) else { return }
        defer { close(fd) }
        var keep = Set<String>()
        for reference in references where keep.count < Self.capacity {
            guard (try? reference.validate()) != nil, case .metainfo = reference.source else { continue }
            keep.insert(reference.hash + ".torrent")
        }
        guard let files = try? managedFiles(directoryFD: fd) else { return }
        for file in files where !keep.contains(file.name) {
            _ = unlinkat(fd, file.name, 0)
        }
    }

    private func openDirectory(create: Bool) throws -> Int32 {
        guard directory.isFileURL, !directory.path.contains("\0") else { throw SPTorrentResumeStoreError.unsafeStorage }
        // Foundation canonicalizes /private/var back to the system /var alias.
        // Use its fixed system destination, then reject every other symlink.
        var path = directory.path
        if path == "/var" || path.hasPrefix("/var/") || path == "/tmp" || path.hasPrefix("/tmp/") {
            path = "/private" + path
        }
        let components = (path as NSString).pathComponents.filter { $0 != "/" }
        guard !components.isEmpty, components.allSatisfy({ $0 != "." && $0 != ".." })
        else { throw SPTorrentResumeStoreError.unsafeStorage }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw SPTorrentResumeStoreError.storageUnavailable }
        for component in components {
            if create, mkdirat(fd, component, 0o700) != 0, errno != EEXIST {
                close(fd)
                throw SPTorrentResumeStoreError.storageUnavailable
            }
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let failure = errno
            close(fd)
            guard next >= 0 else {
                if failure == ENOENT { throw SPTorrentResumeStoreError.missingSource }
                throw SPTorrentResumeStoreError.unsafeStorage
            }
            fd = next
        }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFDIR, fchmod(fd, 0o700) == 0 else {
            close(fd)
            throw SPTorrentResumeStoreError.unsafeStorage
        }
        // The directory lock also serializes independently constructed stores.
        while flock(fd, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            close(fd)
            throw SPTorrentResumeStoreError.storageUnavailable
        }
        return fd
    }

    private func read(hash: String, directoryFD: Int32) throws -> Data {
        let fd = openat(directoryFD, hash + ".torrent", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { throw SPTorrentResumeStoreError.missingSource }
            throw SPTorrentResumeStoreError.unsafeStorage
        }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(), fchmod(fd, 0o600) == 0
        else { throw SPTorrentResumeStoreError.unsafeStorage }
        guard metadata.st_size > 0, metadata.st_size <= Self.maximumBytes
        else { throw SPTorrentResumeStoreError.invalidMetainfo }
        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw SPTorrentResumeStoreError.storageUnavailable
            }
            guard data.count <= Self.maximumBytes - count else { throw SPTorrentResumeStoreError.invalidMetainfo }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private func write(_ data: Data, hash: String, directoryFD: Int32) throws {
        let name = hash + ".torrent"
        var existing = stat()
        if fstatat(directoryFD, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG else { throw SPTorrentResumeStoreError.unsafeStorage }
        } else if errno != ENOENT {
            throw SPTorrentResumeStoreError.storageUnavailable
        }
        let temporary = "." + UUID().uuidString + ".torrent-tmp"
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SPTorrentResumeStoreError.storageUnavailable }
        defer { close(fd); _ = unlinkat(directoryFD, temporary, 0) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw SPTorrentResumeStoreError.storageUnavailable
                }
                guard count > 0 else { throw SPTorrentResumeStoreError.storageUnavailable }
                offset += count
            }
        }
        guard fchmod(fd, 0o600) == 0, fsync(fd) == 0 else { throw SPTorrentResumeStoreError.storageUnavailable }
        let others = try managedFiles(directoryFD: directoryFD).filter { $0.name != name }
            .sorted { $0.modified == $1.modified ? $0.name < $1.name : $0.modified < $1.modified }
        for file in others.prefix(max(0, others.count - Self.capacity + 1)) {
            guard unlinkat(directoryFD, file.name, 0) == 0 else { throw SPTorrentResumeStoreError.storageUnavailable }
        }
        guard renameat(directoryFD, temporary, directoryFD, name) == 0
        else { throw SPTorrentResumeStoreError.storageUnavailable }
        _ = fsync(directoryFD)
    }

    private func managedFiles(directoryFD: Int32) throws -> [(name: String, modified: Double)] {
        let duplicate = dup(directoryFD)
        guard duplicate >= 0 else { throw SPTorrentResumeStoreError.storageUnavailable }
        guard let stream = fdopendir(duplicate) else { close(duplicate); throw SPTorrentResumeStoreError.storageUnavailable }
        defer { closedir(stream) }
        var result: [(name: String, modified: Double)] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw SPTorrentResumeStoreError.storageUnavailable }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            guard name.hasSuffix(".torrent"), name.utf8.count == 48,
                  SPTorrentInput.normalizedHash(String(name.dropLast(8))) == String(name.dropLast(8)) else { continue }
            var metadata = stat()
            guard fstatat(directoryFD, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue }
                throw SPTorrentResumeStoreError.storageUnavailable
            }
            guard metadata.st_mode & S_IFMT == S_IFREG else { continue }
            let modified = Double(metadata.st_mtimespec.tv_sec) + Double(metadata.st_mtimespec.tv_nsec) / 1_000_000_000
            result.append((name, modified))
        }
        return result
    }
}

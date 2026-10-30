import Foundation
import CoreServices
import Darwin
import UniformTypeIdentifiers

struct SPPlaylistEntry: Equatable, Sendable {
    let url: URL
    let relativePath: String
    let displayName: String
    /// The size increased since the preceding successful catalogue. This is
    /// informational, never a promise that an unchanged file is complete.
    let isGrowing: Bool
}

/// One order for the visible tree and Previous/Next: folders first, then
/// natural names at each level, traversed depth first. Identity stays unchanged.
enum SPPlaylistOrder {
    static func nodeLess(_ leftName: String, _ rightName: String,
                         leftIsFolder: Bool, rightIsFolder: Bool,
                         leftKey: String, rightKey: String) -> Bool {
        if leftIsFolder != rightIsFolder { return leftIsFolder }
        let order = leftName.localizedStandardCompare(rightName)
        return order == .orderedSame ? leftKey < rightKey : order == .orderedAscending
    }

    static func pathLess(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: "/"), right = rhs.split(separator: "/")
        for i in 0..<min(left.count, right.count) {
            let leftFolder = i < left.count - 1, rightFolder = i < right.count - 1
            if left[i] == right[i] && leftFolder == rightFolder { continue }
            let a = String(left[i]), b = String(right[i])
            return nodeLess(leftFolder ? a : (a as NSString).deletingPathExtension,
                rightFolder ? b : (b as NSString).deletingPathExtension,
                leftIsFolder: leftFolder, rightIsFolder: rightFolder, leftKey: a, rightKey: b)
        }
        return left.count == right.count ? lhs < rhs : left.count < right.count
    }
}

private final class SPPlaylistCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

private struct SPPlaylistFile: Sendable {
    let url: URL
    let relativePath: String
    let size: Int64
}

private enum SPPlaylistScanResult: Sendable {
    case success([SPPlaylistEntry], [String: Int64])
    case failed(String)
    case cancelled
}

/// Owns one recursive event stream and one lost-event/network fallback timer.
/// Creation and destruction stay on a utility queue: neither stream setup nor
/// filesystem metadata work is performed on the main actor.
private final class SPPlaylistObserver: @unchecked Sendable {
    private final class Context: @unchecked Sendable {
        let onChange: @Sendable () -> Void
        init(_ onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    }

    private let queue = DispatchQueue(label: "dev.khuaplayer.playlist.observer", qos: .utility)
    private var stream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?

    func replace(root: URL?, onChange: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            stopOnQueue()
            guard let root, let onChange else { return }
            let contextObject = Context(onChange)
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(contextObject).toOpaque(),
                retain: { pointer in
                    guard let pointer else { return nil }
                    _ = Unmanaged<Context>.fromOpaque(pointer).retain()
                    return pointer
                },
                release: { pointer in
                    guard let pointer else { return }
                    Unmanaged<Context>.fromOpaque(pointer).release()
                },
                copyDescription: nil)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer |
                kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents)
            if let created = FSEventStreamCreate(
                kCFAllocatorDefault,
                { _, info, _, _, _, _ in
                    guard let info else { return }
                    Unmanaged<Context>.fromOpaque(info).takeUnretainedValue().onChange()
                },
                &context, [root.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags) {
                FSEventStreamSetDispatchQueue(created, queue)
                if FSEventStreamStart(created) { stream = created }
                else { FSEventStreamInvalidate(created); FSEventStreamRelease(created) }
            }
            let fallback = DispatchSource.makeTimerSource(queue: queue)
            fallback.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(1))
            fallback.setEventHandler(handler: onChange)
            timer = fallback
            fallback.resume()
            // Cover the race between the initial enumeration and installing
            // observation. This also works when this filesystem has no events.
            onChange()
        }
    }

    func stop() { replace(root: nil) }

    private func stopOnQueue() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }
}

/// A live catalogue only. It does not open media, decode thumbnails, infer
/// download completion, or alter playback when a file appears or disappears.
@MainActor
final class SPPlaylistController {
    private(set) var rootURL: URL?
    private(set) var recursive = false
    private(set) var entries: [SPPlaylistEntry] = []
    /// Changes only when a catalogue is published or cleared, never when a
    /// refresh merely starts. Consumers can avoid rebuilding navigation then.
    private(set) var entriesRevision: UInt64 = 0
    private(set) var isRefreshing = false
    private(set) var error: String?
    var onChange: (() -> Void)?

    private let mediaExtensions: Set<String>
    private let observer = SPPlaylistObserver()
    private var generation: UInt64 = 0
    private var flight: SPPlaylistCancellation?
    private var needsTrailingRefresh = false
    private var sizes: [String: Int64] = [:]
    private var debounceWork: DispatchWorkItem?
    private var debounceDeadline: TimeInterval = 0
    private var debounceLimit: TimeInterval = 0

    init(mediaExtensions: Set<String>) {
        self.mediaExtensions = Set(mediaExtensions.map { $0.lowercased() })
    }

    deinit {
        flight?.cancel()
        // The one pending debounce captures this owner weakly. Explicit stop
        // cancels it; deallocation leaves only a harmless short queue wake.
        observer.stop()
    }

    func setRoot(_ url: URL, recursive: Bool) {
        let normalized = url.standardizedFileURL
        if rootURL == normalized, self.recursive == recursive {
            refresh()
            return
        }
        generation &+= 1
        cancelPendingWork()
        rootURL = normalized
        self.recursive = recursive
        entries = []
        entriesRevision &+= 1
        sizes = [:]
        error = nil
        let expectedGeneration = generation
        observer.replace(root: normalized) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == expectedGeneration else { return }
                self.noteFilesystemChange()
            }
        }
        refresh()
    }

    func refresh() {
        guard let rootURL else { return }
        debounceWork?.cancel()
        debounceWork = nil
        if flight != nil {
            needsTrailingRefresh = true
            return
        }
        let expectedGeneration = generation
        let recursive = recursive
        let extensions = mediaExtensions
        let previousSizes = sizes
        let token = SPPlaylistCancellation()
        flight = token
        isRefreshing = true
        onChange?()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.scan(root: rootURL, recursive: recursive,
                                   extensions: extensions, previousSizes: previousSizes,
                                   cancellation: token)
            Task { @MainActor [weak self] in
                guard let self, self.generation == expectedGeneration,
                      self.flight === token else { return }
                self.finish(result)
            }
        }
    }

    /// Release the root and its catalogue when this playlist is no longer used.
    func stop() {
        guard rootURL != nil || flight != nil || !entries.isEmpty || error != nil else { return }
        generation &+= 1
        cancelPendingWork()
        observer.stop()
        rootURL = nil
        recursive = false
        entries = []
        entriesRevision &+= 1
        sizes = [:]
        error = nil
        onChange?()
    }

    /// Membership is lexical and component bounded; no filesystem lookup or
    /// symlink resolution is performed on the main actor.
    func contains(_ url: URL) -> Bool {
        guard let rootURL, Self.contains(url, in: rootURL) else { return false }
        return recursive || url.deletingLastPathComponent().standardizedFileURL.path == rootURL.path
    }

    nonisolated static func contains(_ url: URL, in root: URL) -> Bool {
        guard url.isFileURL, root.isFileURL else { return false }
        let child = url.standardizedFileURL.pathComponents
        let parent = root.standardizedFileURL.pathComponents
        return child.count > parent.count && child.starts(with: parent)
    }

    private func cancelPendingWork() {
        flight?.cancel()
        flight = nil
        isRefreshing = false
        needsTrailingRefresh = false
        debounceWork?.cancel()
        debounceWork = nil
        debounceDeadline = 0
        debounceLimit = 0
    }

    private func finish(_ result: SPPlaylistScanResult) {
        flight = nil
        isRefreshing = false
        switch result {
        case .success(let nextEntries, let nextSizes):
            entries = nextEntries
            entriesRevision &+= 1
            sizes = nextSizes
            error = nil
        case .failed(let message):
            // A disconnected share must not erase the last usable catalogue.
            error = message
        case .cancelled:
            break
        }
        let followup = needsTrailingRefresh
        needsTrailingRefresh = false
        if followup { scheduleRefresh() }
        onChange?()
    }

    private func noteFilesystemChange() {
        guard rootURL != nil else { return }
        if flight != nil { needsTrailingRefresh = true }
        else { scheduleRefresh() }
    }

    private func scheduleRefresh() {
        let now = ProcessInfo.processInfo.systemUptime
        if debounceWork == nil { debounceLimit = now + 2 }
        debounceDeadline = min(debounceLimit, now + 0.5)
        guard debounceWork == nil else { return }
        armDebounce(after: max(0, debounceDeadline - now))
    }

    private func armDebounce(after delay: TimeInterval) {
        let expectedGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            self.debounceWork = nil
            let remaining = self.debounceDeadline - ProcessInfo.processInfo.systemUptime
            if remaining > 0.001 { self.armDebounce(after: remaining) }
            else { self.refresh() }
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private struct DirectoryFrame {
        let directory: UnsafeMutablePointer<DIR>
        let url: URL
        let relativePath: String
    }

    /// Descriptor-relative recursion prevents following a directory symlink
    /// even if it replaces an entry after readdir. At most 128 descriptors are
    /// open; the worker keeps only media metadata and its depth-first stack.
    private nonisolated static func scan(root: URL, recursive: Bool,
                                         extensions: Set<String>,
                                         previousSizes: [String: Int64],
                                         cancellation: SPPlaylistCancellation) -> SPPlaylistScanResult {
        let policy = SPBackgroundDiskIOPolicyLease()
        defer { policy.restore() }
        func admitted() -> Bool {
            SPBackgroundStorageGate.waitUntilAllowed(shouldCancel: { cancellation.isCancelled })
        }
        guard admitted() else { return .cancelled }
#if SP_APP_STORE
        guard SPFolderGrants.ensureAccess(path: root.path) else {
            return .failed(posixError(EACCES, path: root.path))
        }
#endif
        let rootFD = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { return .failed(posixError(errno, path: root.path)) }
        guard let rootDirectory = fdopendir(rootFD) else {
            let code = errno
            close(rootFD)
            return .failed(posixError(code, path: root.path))
        }
        var stack = [DirectoryFrame(directory: rootDirectory, url: root, relativePath: "")]
        defer { for frame in stack { closedir(frame.directory) } }
        var files: [SPPlaylistFile] = []
        var packageTypes: [String: Bool] = [:]
        while let frame = stack.last {
            guard admitted() else { return .cancelled }
            errno = 0
            guard let entry = readdir(frame.directory) else {
                let code = errno
                if code != 0 { return .failed(posixError(code, path: frame.url.path)) }
                closedir(frame.directory)
                stack.removeLast()
                continue
            }
            if cancellation.isCancelled { return .cancelled }
            let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let length = min(Int(entry.pointee.d_namlen), capacity - 1)
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    FileManager.default.string(withFileSystemRepresentation: $0, length: length)
                }
            }
            guard !name.hasPrefix("."), !isPartialName(name) else { continue }
            let type = entry.pointee.d_type
            guard type != DT_LNK else { continue }
            let relative = frame.relativePath.isEmpty ? name : frame.relativePath + "/" + name
            let url = frame.url.appendingPathComponent(name, isDirectory: type == DT_DIR)
            let ext = (name as NSString).pathExtension.lowercased()
            if recursive, type == DT_DIR || type == DT_UNKNOWN {
                if isPackageExtension(ext, cache: &packageTypes) { continue }
                guard admitted() else { return .cancelled }
                let childFD = openat(dirfd(frame.directory), name,
                                     O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if childFD >= 0 {
                    var directoryMetadata = stat()
                    guard fstat(childFD, &directoryMetadata) == 0 else {
                        let code = errno
                        close(childFD)
                        return .failed(posixError(code, path: url.path))
                    }
                    if directoryMetadata.st_flags & UInt32(UF_HIDDEN) != 0 {
                        close(childFD)
                        continue
                    }
                    guard stack.count < 128 else {
                        close(childFD)
                        return .failed(posixError(ELOOP, path: url.path))
                    }
                    guard let child = fdopendir(childFD) else {
                        let code = errno
                        close(childFD)
                        return .failed(posixError(code, path: url.path))
                    }
                    stack.append(DirectoryFrame(directory: child, url: url, relativePath: relative))
                    continue
                }
                let code = errno
                if code != ENOTDIR, code != ENOENT, code != ELOOP {
                    return .failed(posixError(code, path: url.path))
                }
            }
            guard extensions.contains(ext), type == DT_REG || type == DT_UNKNOWN else { continue }
            guard admitted() else { return .cancelled }
            var metadata = stat()
            guard fstatat(dirfd(frame.directory), name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                let code = errno
                if code == ENOENT { continue }
                return .failed(posixError(code, path: url.path))
            }
            guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size > 0,
                  metadata.st_flags & UInt32(UF_HIDDEN) == 0 else { continue }
            files.append(SPPlaylistFile(url: url, relativePath: relative, size: Int64(metadata.st_size)))
        }
        guard !cancellation.isCancelled else { return .cancelled }
        var comparisons = 0
        do {
            try files.sort {
                comparisons &+= 1
                if comparisons & 255 == 0, cancellation.isCancelled { throw CancellationError() }
                return SPPlaylistOrder.pathLess($0.relativePath, $1.relativePath)
            }
        } catch { return .cancelled }
        var nextEntries: [SPPlaylistEntry] = []
        var nextSizes: [String: Int64] = [:]
        nextEntries.reserveCapacity(files.count)
        nextSizes.reserveCapacity(files.count)
        for file in files {
            if cancellation.isCancelled { return .cancelled }
            let path = file.url.path
            nextEntries.append(SPPlaylistEntry(
                url: file.url, relativePath: file.relativePath,
                displayName: file.url.lastPathComponent,
                isGrowing: previousSizes[path].map { file.size > $0 } ?? false))
            nextSizes[path] = file.size
        }
        return .success(nextEntries, nextSizes)
    }

    private nonisolated static func isPartialName(_ name: String) -> Bool {
        let lower = name.lowercased()
        let suffixes = [".part", ".partial", ".download", ".crdownload", ".tmp", ".temp", ".filepart", ".aria2", ".!qb", ".bc!"]
        let stem = (lower as NSString).deletingPathExtension
        return suffixes.contains { lower.hasSuffix($0) || stem.hasSuffix($0) }
    }

    private nonisolated static func isPackageExtension(_ ext: String, cache: inout [String: Bool]) -> Bool {
        guard !ext.isEmpty else { return false }
        if let known = cache[ext] { return known }
        // Some bundles (notably .app in command-line hosts) do not resolve as
        // UTType.package. Keep their conventional suffixes independent of LS.
        let bundleExtensions: Set<String> = [
            "app", "bundle", "framework", "plugin", "appex", "kext", "saver",
            "qlgenerator", "mdimporter", "photoslibrary", "photolibrary", "aplibrary",
            "musiclibrary", "imovielibrary", "band", "logicx", "xcodeproj", "xcworkspace",
            "playground", "rtfd", "pages", "numbers", "key", "wdgt"
        ]
        let type = UTType(filenameExtension: ext)
        let isPackage = bundleExtensions.contains(ext) || type?.conforms(to: .package) == true ||
            type?.conforms(to: .bundle) == true
        cache[ext] = isPackage
        return isPackage
    }

    private nonisolated static func posixError(_ code: Int32, path: String) -> String {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path]).localizedDescription
    }
}

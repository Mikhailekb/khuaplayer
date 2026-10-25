import Darwin
import CoreFoundation
import Foundation

// Darwin exposes the struct with the same spelling as this C function to Swift.
@_silgen_name("flock")
private func spPlaybackDiagnosticsFlock(_ fd: Int32, _ operation: Int32) -> Int32

/// Private, bounded playback diagnostics. The schema deliberately accepts only
/// numbers: media names, locations, torrent identities and arbitrary text cannot
/// enter a record. Encoding and all filesystem work run on the writer queue.
@MainActor
final class SPPlaybackDiagnostics {
    enum Event: Int64, Sendable {
        case snapshot = 0, state = 1, control = 2, seek = 3, sourceWait = 4, close = 5, sourceRead = 6
    }

    enum Control: Int64, Sendable {
        case toggle = 1, play = 2, pause = 3, seek = 4
        case setRate = 5, setVolume = 6, toggleMute = 7
        case stepFrame = 8, setAudioTrack = 9, setSubtitleTrack = 10
        case autoPauseScroll = 20, autoResumeScroll = 21
        case autoPauseBurst = 22, autoResumeBurst = 23
        case cacheRestorePause = 30, cacheRestoreResume = 31, cacheRestoreKeepPaused = 32
    }

    enum Field: String, Sendable {
        case state, control, positionUs, durationUs, openGeneration, seekGeneration
        case readByte, historyLowerByte, requestedHistoryLowerByte, playbackHistoryByte
        case playbackByte, appliedPlaybackByte, forwardUpperByte
        case appliedOpenGeneration, appliedSeekGeneration, appliedFileID
        case waitFlags, waitReason, prefetchState, prefetchReceivedBytes, prefetchBudgetBytes
        case prefetchLowerByte, prefetchUpperByte, residentBytes, capacityBytes, interactionFlags
        case prefetchFileID, prefetchMatchesContext
        case selectedFileID, fileOffsetByte, seekTargetUs, commandValueMilli, rangesKnown
        case selectedAudioTrackIndex, selectedSubtitleTrackIndex
        case rangeReader, rangeStart, rangeRequestCount, rangeWaitMs, rangePhase, rangeResult, rangeAttempt
    }

    struct ByteRange: Sendable {
        let lower: Int64
        /// Exclusive byte boundary, matching the source cache API.
        let upper: Int64
    }

    private let window = Int64.random(in: 1...Int64.max)
    private let writer: SPPlaybackDiagnosticWriter

    init() {
        writer = .shared
    }

    /// Isolated writer injection for owned temporary-directory tests.
    init(directory: URL, maximumFileBytes: Int = 2 * 1024 * 1024,
         maximumPendingRecords: Int = 32, writerQueue: DispatchQueue? = nil,
         notificationName: Notification.Name? = nil) {
        writer = SPPlaybackDiagnosticWriter(directory: directory,
            maximumFileBytes: maximumFileBytes,
            maximumPendingRecords: maximumPendingRecords, queue: writerQueue,
            notificationName: notificationName)
    }

    /// Allows isolated tests to exercise multiple windows on one writer without
    /// installing an observer on the production notification or log directory.
    init(sharingWriterWith other: SPPlaybackDiagnostics) {
        writer = other.writer
    }

    func record(_ event: Event, values: [Field: Int64], completeRanges: [ByteRange] = [],
                completeRangeCount: Int? = nil) {
        // Copy only the bounded prefix before crossing queues. Even a malformed
        // source snapshot cannot retain an unbounded interval array in the writer.
        let ranges = completeRanges.prefix(64).filter { $0.lower >= 0 && $0.upper > $0.lower }
        writer.enqueue(SPPlaybackDiagnosticRecord(window: window, event: event.rawValue,
            wallMs: Int64(Date().timeIntervalSince1970 * 1000),
            uptimeMs: Int64(ProcessInfo.processInfo.systemUptime * 1000),
            values: values, ranges: ranges,
            rangeCount: max(completeRanges.count, completeRangeCount ?? completeRanges.count)))
    }

    /// Nonblocking drain used by tests; production playback never waits for I/O.
    func flush() async {
        await writer.flush()
    }
}

private struct SPPlaybackDiagnosticRecord: Sendable {
    let window: Int64
    let event: Int64
    let wallMs: Int64
    let uptimeMs: Int64
    let values: [SPPlaybackDiagnostics.Field: Int64]
    let ranges: [SPPlaybackDiagnostics.ByteRange]
    let rangeCount: Int
}

/// Queue ownership protects the file descriptors and sequence. The lock protects
/// admission only, bounding outstanding work even if the disk is slow or blocked.
private final class SPPlaybackDiagnosticWriter: @unchecked Sendable {
    static let shared = SPPlaybackDiagnosticWriter(directory:
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Kinolet/PlaybackDiagnostics", isDirectory: true),
        notificationName: Notification.Name("KinoletHTTPRangeDiagnostic"))

    private let directory: URL
    private let maximumFileBytes: Int
    private let maximumPendingRecords: Int
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending = 0
    private var dropped: Int64 = 0
    private let boot = Int64.random(in: 1...Int64.max)
    // Accessed only on queue.
    private var directoryFD: Int32 = -1
    private var disabled = false
    private var sequence: Int64 = 0
    private var notificationObserver: NSObjectProtocol?

    init(directory: URL, maximumFileBytes: Int = 2 * 1024 * 1024,
         maximumPendingRecords: Int = 32, queue: DispatchQueue? = nil,
         notificationName: Notification.Name? = nil) {
        self.directory = directory
        self.maximumFileBytes = max(512, min(maximumFileBytes, 2 * 1024 * 1024))
        self.maximumPendingRecords = max(1, min(maximumPendingRecords, 32))
        self.queue = queue ?? DispatchQueue(label: "kinolet.playback-diagnostics", qos: .utility)
        if let notificationName {
            // queue:nil preserves the producer thread. Validation and bounded
            // admission need no MainActor hop, filesystem or JSON encoding.
            notificationObserver = NotificationCenter.default.addObserver(
                forName: notificationName, object: nil, queue: nil) { [weak self] notification in
                    self?.enqueueSourceRead(notification)
                }
        }
    }

    deinit {
        if let notificationObserver { NotificationCenter.default.removeObserver(notificationObserver) }
        let fd = directoryFD
        if fd >= 0 { queue.async { Darwin.close(fd) } }
    }

    private func enqueueSourceRead(_ notification: Notification) {
        let fields: [(String, SPPlaybackDiagnostics.Field)] = [
            ("reader", .rangeReader), ("start", .rangeStart), ("count", .rangeRequestCount),
            ("waitMs", .rangeWaitMs), ("phase", .rangePhase), ("result", .rangeResult),
            ("attempt", .rangeAttempt)
        ]
        guard notification.object == nil, let input = notification.userInfo,
              input.count == fields.count else { return }
        var values: [SPPlaybackDiagnostics.Field: Int64] = [:]
        for (key, field) in fields {
            guard let value = input[key] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(),
                  ["c", "s", "i", "l", "q"].contains(String(cString: value.objCType)) else { return }
            values[field] = value.int64Value
        }
        guard values[.rangeReader]! > 0, values[.rangeStart]! >= 0,
              (1...262_144).contains(values[.rangeRequestCount]!), values[.rangeWaitMs]! >= 0,
              (1...3).contains(values[.rangeAttempt]!), (1...3).contains(values[.rangePhase]!) else { return }
        enqueue(SPPlaybackDiagnosticRecord(window: 0, event: SPPlaybackDiagnostics.Event.sourceRead.rawValue,
            wallMs: Int64(Date().timeIntervalSince1970 * 1000),
            uptimeMs: Int64(ProcessInfo.processInfo.systemUptime * 1000),
            values: values, ranges: [], rangeCount: 0))
    }

    func enqueue(_ record: SPPlaybackDiagnosticRecord) {
        lock.lock()
        guard pending < maximumPendingRecords else {
            dropped = dropped == Int64.max ? dropped : dropped + 1
            lock.unlock()
            return
        }
        pending += 1
        lock.unlock()
        queue.async { [self] in
            write(record)
            lock.lock()
            pending -= 1
            lock.unlock()
        }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    private func write(_ record: SPPlaybackDiagnosticRecord) {
        guard !disabled else { return }
        lock.lock()
        let droppedCount = dropped
        dropped = 0
        lock.unlock()
        sequence += 1
        var object: [String: Any] = [
            "schema": 1, "boot": boot, "window": record.window,
            "event": record.event, "wallMs": record.wallMs, "uptimeMs": record.uptimeMs,
            "sequence": sequence, "dropped": droppedCount,
            "rangeCount": record.rangeCount,
            "rangesOmitted": max(0, record.rangeCount - record.ranges.count),
            "ranges": record.ranges.map { [$0.lower, $0.upper] }
        ]
        for (field, value) in record.values { object[field.rawValue] = value }
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              data.count < 64 * 1024, data.count < maximumFileBytes else { return }
        data.append(0x0a)

        if directoryFD < 0 {
            directoryFD = openPrivateDirectory()
            guard directoryFD >= 0 else { disabled = true; return }
        }
        // A separate lock also serializes rotations across two app processes.
        let lockFD = Darwin.openat(directoryFD, ".lock", O_WRONLY | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { disabled = true; return }
        defer { Darwin.close(lockFD) }
        guard validateRegular(lockFD), spPlaybackDiagnosticsFlock(lockFD, LOCK_EX | LOCK_NB) == 0 else { return }
        defer { _ = spPlaybackDiagnosticsFlock(lockFD, LOCK_UN) }

        guard let oldSize = validatedSize("session.jsonl"),
              let previousSize = validatedSize("previous.jsonl") else { disabled = true; return }
        if previousSize > maximumFileBytes {
            guard Darwin.unlinkat(directoryFD, "previous.jsonl", 0) == 0 else { return }
        }
        if oldSize > maximumFileBytes - data.count {
            if previousSize >= 0 && previousSize <= maximumFileBytes {
                guard Darwin.unlinkat(directoryFD, "previous.jsonl", 0) == 0 else { return }
            }
            // Never retain an oversized preexisting file as the backup.
            if oldSize > maximumFileBytes {
                guard Darwin.unlinkat(directoryFD, "session.jsonl", 0) == 0 else { return }
            } else {
                guard Darwin.renameat(directoryFD, "session.jsonl", directoryFD, "previous.jsonl") == 0 else { return }
            }
        }
        let fileFD = Darwin.openat(directoryFD, "session.jsonl", O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fileFD >= 0 else { disabled = true; return }
        defer { Darwin.close(fileFD) }
        guard validateRegular(fileFD) else { disabled = true; return }
        var info = stat()
        guard Darwin.fstat(fileFD, &info) == 0, info.st_size >= 0,
              info.st_size <= Int64(maximumFileBytes - data.count) else { return }
        let initialSize = info.st_size
        let completed = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            var count = 0
            while count < bytes.count {
                let written = Darwin.write(fileFD, base.advanced(by: count), bytes.count - count)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { return false }
                count += written
            }
            return true
        }
        if !completed { _ = Darwin.ftruncate(fileFD, initialSize) }
    }

    /// Traverse with openat/O_NOFOLLOW, including ancestors. Only new path
    /// components and the dedicated leaf have their modes set; no user folders
    /// are chmodded, and symlink targets are never opened or removed.
    private func openPrivateDirectory() -> Int32 {
        guard directory.isFileURL, directory.path.hasPrefix("/") else { return -1 }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return -1 }
        let components = directory.pathComponents.filter { $0 != "/" }
        guard !components.isEmpty else { Darwin.close(fd); return -1 }
        for component in components {
            guard component != ".", component != "..", !component.contains("\0") else {
                Darwin.close(fd); return -1
            }
            var next = Darwin.openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 && errno == ENOENT {
                guard Darwin.mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else {
                    Darwin.close(fd); return -1
                }
                next = Darwin.openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            Darwin.close(fd)
            guard next >= 0 else { return -1 }
            fd = next
        }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0, info.st_uid == Darwin.getuid(),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), Darwin.fchmod(fd, 0o700) == 0 else {
            Darwin.close(fd); return -1
        }
        return fd
    }

    private func validateRegular(_ fd: Int32) -> Bool {
        var info = stat()
        return Darwin.fstat(fd, &info) == 0 && info.st_uid == Darwin.getuid()
            && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && info.st_nlink == 1 && Darwin.fchmod(fd, 0o600) == 0
    }

    /// -1 means absent; nil means unsafe/unreadable and disables this writer.
    private func validatedSize(_ name: String) -> Int? {
        let fd = Darwin.openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            return errno == ENOENT ? -1 : nil
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard validateRegular(fd), Darwin.fstat(fd, &info) == 0,
              info.st_size >= 0, info.st_size <= Int64(Int.max) else { return nil }
        return Int(info.st_size)
    }
}

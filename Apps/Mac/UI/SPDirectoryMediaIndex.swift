import Foundation
import Darwin

/// A GCD work item runs on a reusable pool thread. Apply Darwin's disk throttle
/// only for the lexical work item and restore the inherited policy afterward.
/// (The dedicated C++ prefetch threads can set it once without this lease.)
struct SPBackgroundDiskIOPolicyLease {
    private let previous = getiopolicy_np(IOPOL_TYPE_DISK,
                                          IOPOL_SCOPE_THREAD)
    private let changed: Bool

    init() {
        changed = setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD,
                                 IOPOL_THROTTLE) == 0
    }

    func restore() {
        if changed, previous >= 0 {
            _ = setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, previous)
        }
    }
}

/// Pure deadline state behind the process-wide foreground-storage gate.
/// Extending, never shortening, the deadline makes a burst of hover/seek input
/// coalesce into one quiet tail without creating one timer per event.
struct SPForegroundStorageQuietState {
    private(set) var quietUntil: TimeInterval = 0

    mutating func noteActivity(now: TimeInterval, quietPeriod: TimeInterval) {
        quietUntil = max(quietUntil, now + max(0, quietPeriod))
    }

    func isActive(now: TimeInterval) -> Bool {
        now < quietUntil
    }
}

/// Process-wide ordering boundary between direct user storage work and optional
/// metadata enumeration. It intentionally pauses every volume: foreground
/// input is rare, while guessing the physical device behind APFS/network mount
/// indirections on the main actor would itself perform filesystem I/O.
enum SPBackgroundStorageGate {
    private static let condition = NSCondition()
    nonisolated(unsafe) private static var state = SPForegroundStorageQuietState()

    static func noteForegroundActivity(
        quietPeriod: TimeInterval = SPDirectoryScanSchedulingPolicy.foregroundQuietPeriod
    ) {
        condition.lock()
        state.noteActivity(now: ProcessInfo.processInfo.systemUptime,
                           quietPeriod: quietPeriod)
        // Do not broadcast on every hover sample (60-120Hz). Existing waiters
        // wake at their earlier deadline or 50ms cancellation sample, observe
        // the extended deadline, and continue waiting without a wake storm.
        condition.unlock()
    }

    static var isForegroundActivityActive: Bool {
        condition.lock()
        let active = state.isActive(now: ProcessInfo.processInfo.systemUptime)
        condition.unlock()
        return active
    }

    /// Background directory workers wait in-place rather than returning a
    /// partial/nil snapshot. This preserves every shared waiter and guarantees
    /// that work resumes after the final 800ms quiet tail. Cancellation is
    /// sampled at most 50ms apart while waiting.
    static func waitUntilAllowed(shouldCancel: () -> Bool) -> Bool {
        while true {
            if shouldCancel() { return false }
            condition.lock()
            let now = ProcessInfo.processInfo.systemUptime
            let remaining = state.quietUntil - now
            if remaining <= 0 {
                condition.unlock()
                return !shouldCancel()
            }
            _ = condition.wait(until: Date(
                timeIntervalSinceNow: min(remaining, 0.05)))
            condition.unlock()
        }
    }
}

/// Cooperative cancellation shared by one physical directory-listing flight.
/// `readdir` itself may block in the kernel for one remote entry, but checking
/// between entries bounds all remaining work and, unlike `contentsOfDirectory`,
/// avoids materializing the complete directory before cancellation is visible.
private final class SPDirectoryListingCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        let result = cancelled
        lock.unlock()
        return result
    }
}

/// Per-caller receipt. Cancelling this object removes only this window's
/// waiter; the shared physical listing is cancelled only after its last waiter
/// disappears. Calls are main-actor confined, matching the index API.
@MainActor
final class SPDirectoryMediaRequest {
    private var cancelAction: (@MainActor () -> Void)?

    fileprivate init(cancelAction: @escaping @MainActor () -> Void) {
        self.cancelAction = cancelAction
    }

    func cancel() {
        let action = cancelAction
        cancelAction = nil
        action?()
    }

    fileprivate func finish() {
        cancelAction = nil
    }
}

/// Pure scheduling constants for the PlayerVC first-frame/interaction gate.
/// State/position/visibility edges still run the gate immediately; this
/// backoff is only the lost-edge safety net for malformed sessions.
enum SPDirectoryScanSchedulingPolicy {
    static let foregroundQuietPeriod: TimeInterval = 0.8

    static func firstFramePollDelay(attempt: Int) -> TimeInterval? {
        guard attempt >= 0, attempt < 6 else { return nil }
        return min(2.0, 0.1 * Double(1 << attempt))
    }
}

/// The real mounted-volume identity (`statfs` f_fsid) behind a directory
/// listing, used as its serialization-lane key. `statfs` may itself block on a
/// dead remote mount, so it must run on the flight's own background worker —
/// never on the main actor and never on another volume's lane. Path-syntax
/// guessing (/Volumes/X, /net/X only) previously collapsed nonstandard
/// mountpoints (`mount_smbfs ~/nas`) into the shared root lane, where one dead
/// share's in-kernel readdir head-of-line blocked every local listing — the
/// exact failure the lanes exist to prevent; it also split symlinked paths to
/// one disk into competing lanes.
enum SPDirectoryListingLaneKey {
    static func key(for directory: URL) -> String {
        var fs: statfs = .init()
        guard statfs(directory.standardizedFileURL.path, &fs) == 0 else {
            // Unresolvable path: give it an isolated lane so its failing
            // opendir cannot delay any healthy volume's listings.
            return "path:" + directory.standardizedFileURL.path
        }
        return "fsid:\(fs.f_fsid.val.0):\(fs.f_fsid.val.1)"
    }
}

/// A process-wide, bounded snapshot of one media directory.
///
/// Directory enumeration is physical I/O even when dispatched off the main
/// queue. On a mechanical disk or SMB share, repeating it for every episode—or
/// once per window—can steal seeks from the foreground demuxer. The index keeps
/// the filesystem work single-flight and lets a player window retain its last
/// snapshot for instant Previous/Next navigation.
struct SPDirectoryMediaSnapshot: Sendable {
    let directory: URL
    /// Already sorted/filtered on the listing queue. Keeping only playback and
    /// subtitle entries avoids retaining a giant photo/document directory in
    /// every live window, and makes cached Previous/Next publication O(1).
    let mediaFiles: [URL]
    let subtitleFileNames: [String]
    let capturedAt: TimeInterval
    private let mediaIndexByPath: [String: Int]

    func contains(_ url: URL) -> Bool {
        mediaIndexByPath[url.standardizedFileURL.path] != nil
    }

    func mediaIndex(of url: URL) -> Int? {
        mediaIndexByPath[url.standardizedFileURL.path]
    }

    fileprivate init(directory: URL,
                     mediaFiles: [URL],
                     subtitleFileNames: [String],
                     capturedAt: TimeInterval) {
        self.directory = directory
        self.mediaFiles = mediaFiles
        self.subtitleFileNames = subtitleFileNames
        self.capturedAt = capturedAt
        var index: [String: Int] = [:]
        index.reserveCapacity(mediaFiles.count)
        for (offset, file) in mediaFiles.enumerated() {
            index[file.standardizedFileURL.path] = offset
        }
        self.mediaIndexByPath = index
    }
}

/// Main-thread catalogue with utility-QoS loaders.
///
/// The cache is deliberately small: a snapshot can contain a large directory,
/// and every live PlayerViewController already retains the one it is using.
/// Failed listings are never cached, so a transiently unavailable network share
/// gets another chance on the next request.
@MainActor
final class SPDirectoryMediaIndex {
    typealias Completion = @MainActor (SPDirectoryMediaSnapshot?) -> Void

    /// The media projection is part of cache/in-flight identity. Today every
    /// player window uses the same canonical set, so they coalesce. Encoding it
    /// here prevents a future caller with a narrower set from attaching to an
    /// incompatible in-flight result and silently receiving the first caller's
    /// projection. Different projections remain serialized on their storage
    /// lane.
    private struct RequestKey: Hashable {
        let directoryPath: String
        let mediaExtensions: Set<String>
    }

    private struct Waiter {
        let receipt: SPDirectoryMediaRequest
        let completion: Completion
    }

    private struct Flight {
        let id: UInt64
        let cancellation: SPDirectoryListingCancellation
    }

    static let shared = SPDirectoryMediaIndex()
    static let freshnessInterval: TimeInterval = 5 * 60
    private static let cacheLimit = 4
    private var snapshots: [RequestKey: SPDirectoryMediaSnapshot] = [:]
    private var waiters: [RequestKey: [UInt64: Waiter]] = [:]
    private var flights: [RequestKey: Flight] = [:]
    private var nextWaiterID: UInt64 = 0
    private var nextFlightID: UInt64 = 0
    // Serialize listings that hit the same physical device, so background
    // indexing cannot turn into HDD seek thrash. Independent volumes/servers
    // use independent lanes: a disconnected SMB share must not head-of-line
    // block local playback or another mounted disk. Keyed by real volume
    // identity (statfs f_fsid, resolved on the flight's own worker), so the
    // queue count tracks mounts encountered by the process rather than the
    // number of browsed folders. Lock-protected statics: lane resolution
    // deliberately happens off the main actor.
    private nonisolated static let listingLanesLock = NSLock()
    nonisolated(unsafe) private static var listingLanes: [String: DispatchQueue] = [:]
    nonisolated(unsafe) private static var nextListingLaneID = 0

    nonisolated(unsafe) private static var resolvedLaneByDirectory: [String: DispatchQueue] = [:]
    nonisolated(unsafe) private static var laneResolveWaiters:
        [String: [@Sendable (DispatchQueue) -> Void]] = [:]

    private init() {}

    func cachedSnapshot(for directory: URL,
                        mediaExtensions: Set<String>) -> SPDirectoryMediaSnapshot? {
        snapshots[RequestKey(directoryPath: directory.standardizedFileURL.path,
                             mediaExtensions: mediaExtensions)]
    }

    func freshSnapshot(for directory: URL,
                       mediaExtensions: Set<String>,
                       now: TimeInterval = ProcessInfo.processInfo.systemUptime)
        -> SPDirectoryMediaSnapshot? {
        let key = RequestKey(directoryPath: directory.standardizedFileURL.path,
                             mediaExtensions: mediaExtensions)
        guard let snapshot = snapshots[key],
              now - snapshot.capturedAt <= Self.freshnessInterval else { return nil }
        return snapshot
    }

    /// Request one listing. Concurrent requests for the same standardized
    /// directory and media projection share one physical shallow streaming
    /// enumeration; other projections remain serialized rather than returning
    /// the wrong cached/filter result.
    @discardableResult
    func requestSnapshot(for directory: URL,
                         mediaExtensions: Set<String>,
                         forceRefresh: Bool = false,
                         completion: @escaping Completion) -> SPDirectoryMediaRequest? {
        let standardized = directory.standardizedFileURL
        let key = RequestKey(directoryPath: standardized.path,
                             mediaExtensions: mediaExtensions)
        if !forceRefresh,
           let cached = freshSnapshot(for: standardized,
                                      mediaExtensions: mediaExtensions) {
            completion(cached)
            return nil
        }

        nextWaiterID &+= 1
        let waiterID = nextWaiterID
        let receipt = SPDirectoryMediaRequest { [weak self] in
            self?.cancelWaiter(key: key, waiterID: waiterID)
        }
        waiters[key, default: [:]][waiterID] = Waiter(
            receipt: receipt, completion: completion)

        if flights[key] != nil {
            return receipt
        }

        nextFlightID &+= 1
        let flightID = nextFlightID
        let cancellation = SPDirectoryListingCancellation()
        flights[key] = Flight(id: flightID, cancellation: cancellation)

        // Volume-identity resolution (statfs) may block on a dead mount; it
        // must occupy only its own single-flight resolver worker — never the
        // main actor, another volume's lane, or one thread per request. The
        // flight then joins its volume's serial lane. A cancelled flight exits
        // at streamSnapshot's first cancellation check, so lane-arrival order
        // needs no guarantee.
        Self.withListingLane(for: standardized) { lane in
            lane.async {
                let snapshot = Self.streamSnapshot(
                    directory: standardized,
                    mediaExtensions: mediaExtensions,
                    cancellation: cancellation)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        Self.shared.finishRequest(key: key, flightID: flightID,
                                                  snapshot: snapshot)
                    }
                }
            }
        }
        return receipt
    }

    /// Shallow POSIX listing: no recursion, no stat/resource-value lookup and no
    /// full unfiltered `[URL]` allocation. A cancelled/error-truncated result is
    /// returned as nil so partial directory state can never enter the cache.
    private nonisolated static func streamSnapshot(
        directory: URL,
        mediaExtensions: Set<String>,
        cancellation: SPDirectoryListingCancellation
    ) -> SPDirectoryMediaSnapshot? {
        // CPU QoS does not order disk traffic. Put this complete worker in
        // Darwin's throttled disk tier, matching timeline/index prefetch.
        let ioPolicy = SPBackgroundDiskIOPolicyLease()
        defer { ioPolicy.restore() }
        guard SPBackgroundStorageGate.waitUntilAllowed(
            shouldCancel: { cancellation.isCancelled }) else { return nil }
#if SP_APP_STORE

        guard SPFolderGrants.ensureAccess(path: directory.path) else {
            if spDebugEnabled { NSLog("[FileAccess] 授权失效，放弃列目录: %@", directory.path) }
            return nil
        }
#endif
        guard let dir = opendir(directory.path) else {
            let code = errno
            SPFileAccess.noteDirectoryListing(directory, error: code)
            if spDebugEnabled {
                NSLog("[FileAccess] 列目录失败 errno=%d: %@", code, directory.path)
            }
            return nil
        }
        defer { closedir(dir) }

        SPFileAccess.noteDirectoryListing(directory, error: nil)

        var mediaFiles: [URL] = []
        var subtitleFileNames: [String] = []
        mediaFiles.reserveCapacity(256)
        while true {
            // A foreground event can arrive after this worker opened the
            // directory. Pause before every subsequent kernel read: at worst
            // one already-entered readdir completes, then all shared flights
            // yield without dropping their waiters or partial state.
            guard SPBackgroundStorageGate.waitUntilAllowed(
                shouldCancel: { cancellation.isCancelled }) else { return nil }
            // Only errno written by this exact readdir call is authoritative;
            // Foundation/String work below is allowed to touch thread errno.
            errno = 0
            guard let entry = readdir(dir) else {
                if errno != 0 {
                    if spDebugEnabled {
                        NSLog("[FileAccess] 读目录中断 errno=%d: %@", errno, directory.path)
                    }
                    return nil
                }
                break
            }
            if cancellation.isCancelled { return nil }

            let nameCapacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let nameLength = min(Int(entry.pointee.d_namlen), nameCapacity - 1)
            let name = withUnsafePointer(to: entry.pointee.d_name) { tuplePointer in
                tuplePointer.withMemoryRebound(to: CChar.self, capacity: nameCapacity) {
                    FileManager.default.string(
                        withFileSystemRepresentation: $0,
                        length: nameLength)
                }
            }
            if name == "." || name == ".." { continue }
            let ext = (name as NSString).pathExtension.lowercased()
            if mediaExtensions.contains(ext) {
                mediaFiles.append(directory.appendingPathComponent(name))
            }
            if SPSubtitleAutoload.subtitleExtensions.contains(ext) {
                subtitleFileNames.append(name)
            }
        }
        guard !cancellation.isCancelled else { return nil }

        mediaFiles.sort {
            $0.lastPathComponent.localizedStandardCompare(
                $1.lastPathComponent) == .orderedAscending
        }
        return SPDirectoryMediaSnapshot(
            directory: directory,
            mediaFiles: mediaFiles,
            subtitleFileNames: subtitleFileNames,
            capturedAt: ProcessInfo.processInfo.systemUptime)
    }

    /// Caller must hold `listingLanesLock`.
    private nonisolated static func listingLaneLocked(forKey laneKey: String)
        -> DispatchQueue {
        if let existing = listingLanes[laneKey] { return existing }
        let queue = DispatchQueue(
            label: "dev.khuaplayer.directory-index.lane.\(nextListingLaneID)",
            qos: .utility)
        nextListingLaneID += 1
        listingLanes[laneKey] = queue
        return queue
    }

    /// Hand `work` the directory's serial lane. Resolved directories are
    /// served from cache without touching the filesystem; at most one statfs
    /// resolver runs per directory at a time, with later requests queueing for
    /// its result instead of stacking additional blocked threads on a dead
    /// mount. Only fsid-resolved lanes enter the cache — the path-fallback
    /// lane of an unreachable mount must be re-resolved once it comes back.
    private nonisolated static func withListingLane(
        for directory: URL,
        run work: @escaping @Sendable (DispatchQueue) -> Void
    ) {
        let path = directory.standardizedFileURL.path
        listingLanesLock.lock()
        if let cached = resolvedLaneByDirectory[path] {
            listingLanesLock.unlock()
            work(cached)
            return
        }
        if laneResolveWaiters[path] != nil {
            laneResolveWaiters[path]!.append(work)
            listingLanesLock.unlock()
            return
        }
        laneResolveWaiters[path] = [work]
        listingLanesLock.unlock()
        DispatchQueue.global(qos: .utility).async {
            let laneKey = SPDirectoryListingLaneKey.key(for: directory)
            listingLanesLock.lock()
            let lane = listingLaneLocked(forKey: laneKey)
            if laneKey.hasPrefix("fsid:") {
                resolvedLaneByDirectory[path] = lane
            }
            let waiters = laneResolveWaiters.removeValue(forKey: path) ?? []
            listingLanesLock.unlock()
            for waiter in waiters { waiter(lane) }
        }
    }

    private func cancelWaiter(key: RequestKey, waiterID: UInt64) {
        guard var keyWaiters = waiters[key],
              let removed = keyWaiters.removeValue(forKey: waiterID) else { return }
        removed.receipt.finish()
        if keyWaiters.isEmpty {
            waiters.removeValue(forKey: key)
            // Remove the flight identity immediately: a new requester gets a
            // fresh flight queued behind this cancelling one rather than joining
            // an operation whose partial result must be discarded.
            flights.removeValue(forKey: key)?.cancellation.cancel()
        } else {
            waiters[key] = keyWaiters
        }
    }

    private func finishRequest(key: RequestKey, flightID: UInt64,
                               snapshot: SPDirectoryMediaSnapshot?) {
        // A last-waiter cancellation may already have retired this flight and
        // launched a replacement with the same key. Its late result is stale.
        guard flights[key]?.id == flightID else { return }
        flights.removeValue(forKey: key)
        let callbacks = waiters.removeValue(forKey: key)?.values ?? [:].values
        if let snapshot {
            snapshots[key] = snapshot
            if snapshots.count > Self.cacheLimit,
               let oldest = snapshots.min(by: {
                   $0.value.capturedAt < $1.value.capturedAt
               })?.key {
                snapshots.removeValue(forKey: oldest)
            }
        }
        for waiter in callbacks {
            waiter.receipt.finish()
            waiter.completion(snapshot)
        }
    }
}

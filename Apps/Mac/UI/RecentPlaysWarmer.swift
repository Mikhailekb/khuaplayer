import AppKit
import Darwin

enum WelcomeHeartbeatState { case active, paused, gone }

#if SP_APP_STORE
// Recent paths alone do not grant sandbox access. Match OpenPanelWarmer's no-op
// implementation rather than attempting reads without security-scoped access.
enum RecentPlaysWarmer {
    static func warmForWelcome(entries: [(path: String, resumeFraction: Double)]) {}
    static func warmEntryIntent(path: String) {}
    static func beginAutoWarmCycle() {}
    static func warmEntryAutoIntent(path: String) {}
    @MainActor static func wakeRecentVolumesAtLaunch() {}
    static func noteForegroundOpen(path: String) {}
    static func noteAppTerminating() {}
    @MainActor static func registerWelcomeHeartbeat(
        owner: AnyObject, state: @escaping @MainActor () -> WelcomeHeartbeatState) {}
}
#else

/// Disable cloud-placeholder materialization for this thread so speculative
/// reads fail rather than trigger downloads. Restore the previous policy after
/// warming so regular opens are unaffected. Callers must skip warming if the
/// policy could not be applied.
private struct SPDatalessMaterializationOffLease {
    private let previous = getiopolicy_np(
        IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
    let isEngaged: Bool

    init() {
        // Change the policy only if it can be restored, since the dispatch
        // worker thread may later run unrelated tasks.
        isEngaged = previous >= 0 && setiopolicy_np(
            IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
            IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0
    }

    func restore() {
        if isEngaged, previous >= 0 {
            _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
                               IOPOL_SCOPE_THREAD, previous)
        }
    }
}

// Best-effort storage warming for the welcome window's recent-file list.
//
// Two bounded stages can reduce connection, spin-up, and metadata-read latency:
//  - Welcome presentation: deduplicate visible entries by their real volume
//    identity and read 4 KB from one representative file near an estimated resume
//    offset. This is a wake attempt, not precise resume-position warming; VBR
//    layout and server caching determine whether it reaches the physical disk.
//  - Row hover: read the first 1 MB and last 256 KB into the page cache to cover
//    common container headers and indexes. Read the head first so early yielding
//    prioritizes the data needed to open the file.
//
// Safety and scheduling invariants:
//  - Fail silently and never modify recent-file records on I/O or access errors.
//  - Use path-based open/statfs without requesting mounts or access dialogs.
//    Skip warming unless cloud-placeholder downloads have been disabled.
//  - Recheck foregroundIOActive between potentially blocking calls; yielding to
//    playback must not consume a cooldown without performing the intended work.
//  - Use independent asynchronous workers per path without joining blocked I/O.
//  - Serialize reads per volume and retain only its newest hover candidate.
//    Claim candidates atomically and retry the handoff whenever a worker exits.
//  - Apply a volume cooldown without periodic keep-alive reads.
enum RecentPlaysWarmer {
    private static let lock = NSLock()
    // The lock protects all mutable state below.
    nonisolated(unsafe) private static var ledger = RecentWarmVolumeLedger()
    nonisolated(unsafe) private static var entryLanes:
        [String: OpenPanelWarmLanePolicy] = [:]
    private static let volumeCooldown: TimeInterval = 30
    private static let entryCooldown: TimeInterval = 20
    // True once a real row hover registered an intent in the current welcome
    // warm cycle. The speculative top-entry read consults it so an automatic
    // default never steals the per-volume read slot from the row the user is
    // actually pointing at (intent sequences treat the newest caller as the
    // user's latest wish; an auto call must not impersonate one).
    nonisolated(unsafe) private static var realHoverSeen = false
    private static let headBudget = 1 << 20
    private static let tailBudget = 256 << 10
    private static let chunkSize = 128 << 10

    private static func volumeKey(_ fs: statfs) -> String {
        "fsid:\(fs.f_fsid.val.0):\(fs.f_fsid.val.1)"
    }

    /// Decide the next handoff under the lock, then dispatch outside it.
    private static func attemptRelaunch(key: String) {
        lock.lock()
        let decision = ledger.relaunchDecision(
            key: key, lanes: &entryLanes,
            now: ProcessInfo.processInfo.systemUptime, cooldown: entryCooldown)
        lock.unlock()
        if case let .launch(path, _) = decision {
            dispatchEntryWorker(path: path)
        }
    }

    // MARK: - Volume wake on welcome presentation

    /// Resolve each visible path's volume on an independent worker, then claim
    /// at most one 4 KB wake read per volume within the cooldown.
    static func warmForWelcome(entries: [(path: String, resumeFraction: Double)]) {
        for entry in entries {
            let path = entry.path
            let fraction = entry.resumeFraction

            guard SPFileAccess.mayWarm(path: path) else { continue }
            lock.lock()
            let claimed = ledger.claimPath(path)
            lock.unlock()
            guard claimed else { continue }
            DispatchQueue.global(qos: .utility).async {
                defer {
                    lock.lock()
                    ledger.finishPath(path)
                    lock.unlock()
                }
                let ioPolicy = SPBackgroundDiskIOPolicyLease()
                defer { ioPolicy.restore() }
                let matPolicy = SPDatalessMaterializationOffLease()
                defer { matPolicy.restore() }
                guard matPolicy.isEngaged else { return }
                guard !OpenPanelWarmer.foregroundIOActive else { return }
                var fs = statfs()
                guard statfs(path, &fs) == 0 else { return }
                let key = volumeKey(fs)
                lock.lock()
                let wake = ledger.claimVolumeWake(
                    key: key, now: ProcessInfo.processInfo.systemUptime,
                    cooldown: volumeCooldown)
                // Share the per-volume slot with hover reads. If one is already
                // active, keep the wake cooldown without adding another read.
                // Sequence zero allows any hover intent to supersede this read.
                let slot = wake ? ledger.claimVolumeRead(key: key, seq: 0) : false
                lock.unlock()
                guard wake else { return }
                guard slot else { return }
                var revokeWake = false
                defer {
                    lock.lock()
                    if revokeWake { ledger.revokeVolumeWake(key: key) }
                    ledger.releaseVolumeRead(key: key)
                    lock.unlock()
                    attemptRelaunch(key: key) // A hover candidate may be waiting.
                }
                // Recheck after potentially blocking statfs. Revoke an unused
                // claim when yielding so a subsequent request can retry.
                guard !OpenPanelWarmer.foregroundIOActive else {
                    revokeWake = true
                    return
                }
                let t0 = ProcessInfo.processInfo.systemUptime
                let fd = open(path, O_RDONLY)
                guard fd >= 0 else {
                    revokeWake = true
                    return
                }
                defer { close(fd) }
                // Playback may have started while open was blocked. Yield
                // before issuing another fstat or pread.
                guard !OpenPanelWarmer.foregroundIOActive else {
                    revokeWake = true
                    return
                }
                var st = stat()
                guard fstat(fd, &st) == 0,
                      (st.st_mode & S_IFMT) == S_IFREG, st.st_size > 0 else {
                    return
                }
                guard !OpenPanelWarmer.foregroundIOActive else {
                    revokeWake = true
                    return
                }
                // Approximate the resume offset for a wake attempt, not a seek.
                var offset: off_t = 0
                if fraction > 0 {
                    offset = min(max(0, st.st_size - 4096),
                                 off_t(fraction * Double(st.st_size)))
                }
                var buf = [UInt8](repeating: 0, count: 4096)
                let n = pread(fd, &buf, buf.count, offset)
                if spDebugEnabled {
                    NSLog("[UI] Recent-file volume wake: %@ · %d bytes @%.0f%% · %.0fms",
                          (path as NSString).lastPathComponent, max(0, n),
                          fraction * 100,
                          (ProcessInfo.processInfo.systemUptime - t0) * 1000)
                }
            }
        }
    }

    // MARK: - File read-ahead on row hover

    /// Bound hover work with per-path lanes and cooldowns. Always record repeat
    /// hover intent, even for an active path, so it can supersede another file's
    /// read without dispatching a duplicate worker.
    /// Reset the real-hover marker for a new welcome warm cycle. Called when
    /// the welcome list (re)appears, before the speculative top-entry read is
    /// scheduled; hovers from a previous cycle must not suppress it.
    static func beginAutoWarmCycle() {
        lock.lock()
        realHoverSeen = false
        lock.unlock()
    }

    /// Speculative read-ahead for the top (most likely) entry. Yields the
    /// cycle entirely once a real hover has shown the user's actual target:
    /// issuing a regular intent here would carry a newer sequence and evict
    /// that in-flight read, with no re-enter event to ever restore it.
    static func warmEntryAutoIntent(path: String) {
        lock.lock()
        let hovered = realHoverSeen
        lock.unlock()
        guard !hovered else { return }
        warmEntryIntent(path: path, isAutoIntent: true)
    }

    static func warmEntryIntent(path: String, isAutoIntent: Bool = false) {

        guard SPFileAccess.mayWarm(path: path) else { return }
        lock.lock()
        if !isAutoIntent { realHoverSeen = true }
        // Workers query this latest sequence when claiming or registering, so
        // repeat hover events during volume resolution retain their priority.
        let seq = ledger.noteIntent(forPath: path)
        var lane = entryLanes[path] ?? OpenPanelWarmLanePolicy()
        let wasInFlight = lane.isInFlight
        let claimed = lane.claim(now: ProcessInfo.processInfo.systemUptime,
                                 cooldown: entryCooldown)
        entryLanes[path] = lane
        if !claimed, wasInFlight,
           let key = ledger.volumeKey(forPath: path),
           ledger.isVolumeReadInFlight(key: key) {
            // Refresh only active paths with a busy volume. A cooling-down path
            // must not interrupt a read when it cannot claim the next slot.
            ledger.notePendingEntry(key: key, path: path, seq: seq)
        }
        if entryLanes.count > 32 {
            // Prune idle lanes outside their cooldown and shrink the associated
            // volume cache so obsolete recent paths do not accumulate.
            let now = ProcessInfo.processInfo.systemUptime
            entryLanes = entryLanes.filter { _, l in
                l.isInFlight || (l.lastCompletedWorkAt.map {
                    now - $0 < entryCooldown } ?? false)
            }
            ledger.pruneVolumeKeys(keepingPaths: Set(entryLanes.keys))
        }
        lock.unlock()
        guard claimed else { return }
        dispatchEntryWorker(path: path)
    }

    /// Shared worker for direct hover requests and pending handoffs. Read the
    /// path's latest sequence when claiming a slot instead of capturing it at
    /// dispatch, preserving hover events received during volume resolution.
    private static func dispatchEntryWorker(path: String) {
        DispatchQueue.global(qos: .utility).async {
            var performedWork = true
            var resolvedVolumeKey: String?
            defer { // Finish the lane before the final handoff decision.
                lock.lock()
                var lane = entryLanes[path] ?? OpenPanelWarmLanePolicy()
                lane.finish(now: ProcessInfo.processInfo.systemUptime,
                            performedWork: performedWork)
                entryLanes[path] = lane
                lock.unlock()
                if let key = resolvedVolumeKey { attemptRelaunch(key: key) }
            }
            let ioPolicy = SPBackgroundDiskIOPolicyLease()
            defer { ioPolicy.restore() }
            let matPolicy = SPDatalessMaterializationOffLease()
            defer { matPolicy.restore() }
            guard matPolicy.isEngaged else { return }
            guard !OpenPanelWarmer.foregroundIOActive else {
                performedWork = false
                return
            }
            // Resolve on this worker to isolate blocked paths, then cache the
            // identity so the main-thread entry point can refresh active intent.
            var fs = statfs()
            guard statfs(path, &fs) == 0 else { return }
            let key = volumeKey(fs)
            resolvedVolumeKey = key
            lock.lock()
            ledger.noteVolumeKey(key, forPath: path)
            let seqNow = ledger.intentSeq(forPath: path) // Use the latest intent.
            let slot = ledger.claimVolumeRead(key: key, seq: seqNow)
            if !slot {
                ledger.notePendingEntry(key: key, path: path, seq: seqNow)
            }
            lock.unlock()
            guard slot else {
                // The candidate remains pending. Both this worker and the slot
                // owner retry handoff on exit, covering either completion order.
                performedWork = false
                return
            }
            defer { // Free the slot before the outer defer attempts a handoff.
                lock.lock()
                ledger.releaseVolumeRead(key: key)
                lock.unlock()
            }
            /// Yield between reads to foreground I/O or a newer volume candidate.
            func shouldYield() -> Bool {
                if OpenPanelWarmer.foregroundIOActive { return true }
                lock.lock()
                let newer = ledger.hasNewerCandidate(key: key, than: path)
                lock.unlock()
                return newer
            }
            // Recheck after potentially blocking statfs and before open.
            if shouldYield() {
                performedWork = false
                return
            }
            let t0 = ProcessInfo.processInfo.systemUptime
            let fd = open(path, O_RDONLY)
            guard fd >= 0 else { return }
            defer { close(fd) }
            // Recheck after open in case playback started while it was blocked.
            if shouldYield() {
                performedWork = false
                return
            }
            var st = stat()
            guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
                  st.st_size > 0 else { return }
            let size = st.st_size

            if let resume = beginSpeculativeOpen(path: path) {
                let box = SpecWarmYield(path: path, volumeKey: key)
                let r = path.withCString { cPath in
                    withExtendedLifetime(box) {
                        SPSpeculativeOpenWarm(cPath, resume, specWarmAheadSec, specWarmYieldFn,
                                              Unmanaged.passUnretained(box).toOpaque())
                    }
                }
                endSpeculativeOpen(path: path)
                if r != -3 {
                    performedWork = !box.didYield
                    return
                }
            }
            var buf = [UInt8](repeating: 0, count: chunkSize)
            var warmedBytes = 0
            // Read the head first for common container headers and track data.
            var offset: off_t = 0
            let headEnd = min(off_t(headBudget), size)
            while offset < headEnd {
                if shouldYield() {
                    performedWork = false
                    return
                }
                let n = pread(fd, &buf, min(chunkSize, Int(headEnd - offset)),
                              offset)
                guard n > 0 else { break }
                offset += off_t(n)
                warmedBytes += n
            }
            // Read a nonoverlapping tail for container indexes and duration data.
            var tailStart = max(headEnd, size - off_t(tailBudget))
            while tailStart < size {
                if shouldYield() {
                    performedWork = false
                    return
                }
                let n = pread(fd, &buf, min(chunkSize, Int(size - tailStart)),
                              tailStart)
                guard n > 0 else { break }
                tailStart += off_t(n)
                warmedBytes += n
            }
            if spDebugEnabled {
                NSLog("[UI] Recent-file read-ahead: %@ · %dKB · %.0fms",
                      (path as NSString).lastPathComponent, warmedBytes >> 10,
                      (ProcessInfo.processInfo.systemUptime - t0) * 1000)
            }
        }
    }

    // MARK: - Speculative open (MKV/MP4)

    private static let specWarmAheadSec = 3.0

    private static let specWarmInFlightKey = "sp.warm.inFlight"
    private static let specWarmBlockedKey = "sp.warm.blocked"

    nonisolated(unsafe) private static var specWarmLedgerChecked = false
    nonisolated(unsafe) private static var specWarmActive: [String] = []
    nonisolated(unsafe) private static var foregroundOpenPath: String?

    static func noteForegroundOpen(path: String) {
        lock.lock()
        foregroundOpenPath = path
        lock.unlock()
    }

    static func noteAppTerminating() {
        lock.lock()
        specWarmActive.removeAll()
        lock.unlock()
        UserDefaults.standard.removeObject(forKey: specWarmInFlightKey)
    }

    private final class SpecWarmYield {
        let path: String
        let volumeKey: String
        var didYield = false
        init(path: String, volumeKey: String) { self.path = path; self.volumeKey = volumeKey }
    }

    private static let specWarmYieldFn: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { ctx in
        guard let ctx else { return 1 }
        let box = Unmanaged<SpecWarmYield>.fromOpaque(ctx).takeUnretainedValue()
        lock.lock()
        let newer = ledger.hasNewerCandidate(key: box.volumeKey, than: box.path)
        let openingThis = foregroundOpenPath == box.path
        lock.unlock()
        let yield = newer || (OpenPanelWarmer.foregroundIOActive && !openingThis)
        if yield { box.didYield = true }
        return yield ? 1 : 0
    }

    private static func beginSpeculativeOpen(path: String) -> Double? {
        let defaults = UserDefaults.standard
        lock.lock()
        defer { lock.unlock() }
        if !specWarmLedgerChecked {
            specWarmLedgerChecked = true
            let leftovers = defaults.stringArray(forKey: specWarmInFlightKey) ?? []
            if !leftovers.isEmpty {
                var blocked = defaults.stringArray(forKey: specWarmBlockedKey) ?? []
                blocked.append(contentsOf: leftovers.filter { !blocked.contains($0) })
                defaults.set(Array(blocked.suffix(20)), forKey: specWarmBlockedKey)
                defaults.removeObject(forKey: specWarmInFlightKey)
            }
        }
        if (defaults.stringArray(forKey: specWarmBlockedKey) ?? []).contains(path) { return nil }
        specWarmActive.append(path)
        defaults.set(specWarmActive, forKey: specWarmInFlightKey)
        return SPResumePolicy.startPosition(
            path: path, pending: nil,
            storedPosition: defaults.object(forKey: "sp.pos." + path) as? Double,
            recents: RecentPlays.load()) ?? 0
    }

    private static func endSpeculativeOpen(path: String) {
        lock.lock()
        if let i = specWarmActive.firstIndex(of: path) { specWarmActive.remove(at: i) }
        let remaining = specWarmActive
        lock.unlock()
        if remaining.isEmpty {
            UserDefaults.standard.removeObject(forKey: specWarmInFlightKey)
        } else {
            UserDefaults.standard.set(remaining, forKey: specWarmInFlightKey)
        }
    }

    // MARK: - Welcome-page volume heartbeat

    private static let heartbeatInterval: TimeInterval = 2.5

    nonisolated(unsafe) private static var heartbeatInFlight = Set<String>()
    nonisolated(unsafe) private static var heartbeatDevByPath: [String: Int64] = [:]
    nonisolated(unsafe) private static var heartbeatNonRemote = Set<String>()

    @MainActor private static var heartbeatOwners:
        [(owner: () -> AnyObject?, state: () -> WelcomeHeartbeatState)] = []
    @MainActor private static var heartbeatTimer: Timer?

    @MainActor private static var userAway = false
    @MainActor private static var presenceObservers: [NSObjectProtocol] = []

    @MainActor private static func observePresenceIfNeeded() {
        guard presenceObservers.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()
        let away: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated { userAway = true }
        }
        let back: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated {
                userAway = false
                if !heartbeatOwners.isEmpty { heartbeatTick() }
            }
        }
        presenceObservers = [
            ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: away),
            ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: back),
            dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: away),
            dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main, using: back),
        ]
    }

    @MainActor static func wakeRecentVolumesAtLaunch() {
        let count = WelcomeView.visibleEntryCount
        DispatchQueue.global(qos: .utility).async {
            beatRecentVolumes(RecentPlays.load().prefix(count).map(\.path))
        }
    }

    @MainActor static func registerWelcomeHeartbeat(
        owner: AnyObject, state: @escaping @MainActor () -> WelcomeHeartbeatState) {
        observePresenceIfNeeded()
        heartbeatOwners.removeAll { $0.owner() == nil || $0.owner() === owner }
        heartbeatOwners.append((owner: { [weak owner] in owner }, state: state))
        heartbeatTick()
        if heartbeatTimer == nil {
            let timer = Timer(timeInterval: heartbeatInterval, repeats: true) { _ in
                MainActor.assumeIsolated { heartbeatTick() }
            }
            timer.tolerance = 0.3
            RunLoop.main.add(timer, forMode: .common)
            heartbeatTimer = timer
        }
    }

    @MainActor private static func heartbeatTick() {
        var active = false
        heartbeatOwners.removeAll { entry in
            guard entry.owner() != nil else { return true }
            switch entry.state() {
            case .gone: return true
            case .paused: return false
            case .active: active = true; return false
            }
        }
        if heartbeatOwners.isEmpty {
            heartbeatTimer?.invalidate()
            heartbeatTimer = nil
            return
        }
        guard active, !userAway, !OpenPanelWarmer.foregroundIOActive else { return }
        let paths = RecentPlays.load().prefix(WelcomeView.visibleEntryCount).map(\.path)
        DispatchQueue.global(qos: .utility).async { beatRecentVolumes(paths) }
    }

    private static func beatRecentVolumes(_ paths: [String]) {
        var chosenDevs = Set<Int64>()
        var targets: [String] = []
        lock.lock()
        for path in paths where !heartbeatNonRemote.contains(path) {

            if let key = ledger.volumeKey(forPath: path), ledger.isVolumeReadInFlight(key: key) { continue }
            if let dev = heartbeatDevByPath[path] {
                guard chosenDevs.insert(dev).inserted else { continue }
            }
            guard !heartbeatInFlight.contains(path) else { continue }
            targets.append(path)
        }
        lock.unlock()
        for path in targets {

            guard SPFileAccess.mayWarm(path: path) else { continue }
            lock.lock()
            let claimed = heartbeatInFlight.insert(path).inserted
            lock.unlock()
            guard claimed else { continue }
            DispatchQueue.global(qos: .utility).async {
                var dev: Int64 = 0
                let r = path.withCString { SPVolumeHeartbeatBeat($0, Int32(heartbeatInterval * 1000), &dev) }
                lock.lock()
                heartbeatInFlight.remove(path)
                if r == -1 {
                    heartbeatNonRemote.insert(path)
                } else if dev != 0 {
                    heartbeatDevByPath[path] = dev
                }
                if heartbeatDevByPath.count > 64 { heartbeatDevByPath.removeAll() }
                if heartbeatNonRemote.count > 64 { heartbeatNonRemote.removeAll() }
                lock.unlock()
            }
        }
    }
}
#endif

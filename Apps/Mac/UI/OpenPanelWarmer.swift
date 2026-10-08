import AppKit
import Darwin

#if SP_APP_STORE
enum OpenPanelWarmer {
    enum Trigger { case idle, menuIntent }
    static func warm(trigger: Trigger = .idle) {}
    static func noteStreamingChanged(_ engaged: Bool) {}
}
#else

enum OpenPanelWarmer {
    enum Trigger {
        case idle
        case menuIntent
    }

    private static let lock = NSLock()
    // The lock guards all state below. Directory and volume work use separate
    // ledgers because idle warming must not consume the menu-only sweep budget.
    nonisolated(unsafe) private static var directoryLane = OpenPanelWarmLanePolicy()
    nonisolated(unsafe) private static var sweepLane = OpenPanelWarmLanePolicy()
    private static let cooldown: TimeInterval = 30

    nonisolated(unsafe) private static var streamCount = 0
    static func noteStreamingChanged(_ engaged: Bool) {
        lock.lock()
        streamCount += engaged ? 1 : -1
        if streamCount < 0 { streamCount = 0 }
        lock.unlock()
    }
    private static var playbackActiveNow: Bool {
        lock.lock()
        let n = streamCount
        lock.unlock()
        // Paused playback intentionally contributes no streamCount, but a
        // paused seek/hover is still foreground storage work. The shared quiet
        // gate covers that interaction (and work in another player window).
        return n > 0 || SPBackgroundStorageGate.isForegroundActivityActive
    }

    /// Share playback and foreground-I/O gating with recent-entry warming so
    /// all speculative work yields as soon as a real open begins.
    static var foregroundIOActive: Bool { playbackActiveNow }

    static func warm(trigger: Trigger = .idle) {
        // Do not consume a cooldown for a request that performed zero work.
        guard !playbackActiveNow else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let launchDirectory = directoryLane.claim(now: now, cooldown: cooldown)
        let launchSweep = trigger == .menuIntent
            ? sweepLane.claim(now: now, cooldown: cooldown) : false
        lock.unlock()

        if launchDirectory { launchDirectoryWarm() }
        if launchSweep { launchVolumeSweep() }
    }

    private static func finishDirectoryWarm(performedWork: Bool) {
        lock.lock()
        directoryLane.finish(now: ProcessInfo.processInfo.systemUptime,
                             performedWork: performedWork)
        lock.unlock()
    }

    private static func finishVolumeSweep(performedWork: Bool) {
        lock.lock()
        sweepLane.finish(now: ProcessInfo.processInfo.systemUptime,
                         performedWork: performedWork)
        lock.unlock()
    }

    private static func launchDirectoryWarm() {
        DispatchQueue.global(qos: .utility).async {
            let ioPolicy = SPBackgroundDiskIOPolicyLease()
            defer { ioPolicy.restore() }

            guard !playbackActiveNow else {
                finishDirectoryWarm(performedWork: false)
                return
            }
            var performedWork = true
            defer { finishDirectoryWarm(performedWork: performedWork) }
            guard let bookmark = UserDefaults.standard
                .data(forKey: "NSOSPLastRootDirectory") else { return }
            var stale = false

            guard let url = try? URL(resolvingBookmarkData: bookmark,
                                     options: [.withoutUI, .withoutMounting],
                                     relativeTo: nil,
                                     bookmarkDataIsStale: &stale) else { return }

            guard !playbackActiveNow else {
                performedWork = false
                return
            }

            guard SPFileAccess.mayWarm(path: url.path) else { return }
            let t0 = ProcessInfo.processInfo.systemUptime
            var count = 0
            var wokeDisk = false

            if let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey,
                                             .contentModificationDateKey,
                                             .localizedNameKey],
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles],
                errorHandler: nil) {
                for case let item as URL in enumerator {
                    // The enumerator has already returned at most this one
                    // entry. Check every item (not every 64) so a paused seek
                    // cannot leave dozens of remote metadata calls in front of
                    // the user's request.
                    if playbackActiveNow {
                        performedWork = false
                        break
                    }
                    count += 1

                    if !wokeDisk,
                       (try? item.resourceValues(forKeys: [.isDirectoryKey]))?
                           .isDirectory == false {
                        if playbackActiveNow {
                            performedWork = false
                            break
                        }
                        if let fh = try? FileHandle(forReadingFrom: item) {
                            _ = try? fh.read(upToCount: 4096)
                            try? fh.close()
                        }
                        wokeDisk = true
                    }
                    if count >= 512 { break }
                }
            }
            // Covers activity arriving during the last blocking metadata/data
            // call, when the loop has no subsequent iteration to observe it.
            if playbackActiveNow { performedWork = false }
            if spDebugEnabled {
                NSLog("[UI] 打开面板预热: %@ · %d 项 · %.0fms",
                      url.lastPathComponent, count,
                      (ProcessInfo.processInfo.systemUptime - t0) * 1000)
            }
        }
    }

    private final class SweepReceipt: @unchecked Sendable {
        private let receiptLock = NSLock()
        private var value = false
        private var interrupted = false
        func markPerformed() {
            receiptLock.lock()
            value = true
            receiptLock.unlock()
        }
        func markInterrupted() {
            receiptLock.lock()
            interrupted = true
            receiptLock.unlock()
        }
        var shouldConsumeCooldown: Bool {
            receiptLock.lock()
            let result = value && !interrupted
            receiptLock.unlock()
            return result
        }
    }

    private static func launchVolumeSweep() {
        DispatchQueue.global(qos: .utility).async {
            guard !playbackActiveNow else {
                finishVolumeSweep(performedWork: false)
                return
            }

            guard let vols = FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: [.volumeIsInternalKey,
                                                  .volumeIsRootFileSystemKey],
                options: [.skipHiddenVolumes]) else {
                finishVolumeSweep(performedWork: true)
                return
            }
            var candidates: [URL] = []
            for vol in vols {
                guard !playbackActiveNow else {
                    finishVolumeSweep(performedWork: false)
                    return
                }
                let vals = try? vol.resourceValues(
                    forKeys: [.volumeIsInternalKey, .volumeIsRootFileSystemKey])
                if vals?.volumeIsRootFileSystem == true { continue }
                if vals?.volumeIsInternal == true { continue }

                guard SPFileAccess.mayWarm(path: vol.path) else { continue }
                candidates.append(vol)
            }
            guard !candidates.isEmpty else {
                finishVolumeSweep(performedWork: true)
                return
            }

            let group = DispatchGroup()
            let receipt = SweepReceipt()
            for vol in candidates {
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    defer { group.leave() }
                    let ioPolicy = SPBackgroundDiskIOPolicyLease()
                    defer { ioPolicy.restore() }
                    guard !playbackActiveNow else {
                        receipt.markInterrupted()
                        return
                    }
                    receipt.markPerformed()

                    vol.withUnsafeFileSystemRepresentation { path in
                        guard let path, let directory = opendir(path) else { return }
                        defer { closedir(directory) }
                        guard !playbackActiveNow else {
                            receipt.markInterrupted()
                            return
                        }
                        _ = readdir(directory)
                        if playbackActiveNow { receipt.markInterrupted() }
                    }
                }
            }
            group.notify(queue: .global(qos: .utility)) {
                finishVolumeSweep(performedWork: receipt.shouldConsumeCooldown)
            }
        }
    }
}
#endif

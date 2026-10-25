import Foundation

private struct SPTorrentPrefetchCapacityStop {}

// The runner inserts the actual window policy and foreground seek methods here. These
// controlled dependencies expose asynchronous ordering without a media player,
// user defaults, a real clipboard, or an external torrent swarm.
private struct Descriptor { let leaseID = UUID() }
private struct MediaFile { let id = 7; let length: Int64 = 1_048_576 }
private struct Context { let descriptor = Descriptor(); let file = MediaFile() }
private struct MediaWindow {
    var openGeneration: Int64 = 1
    var seekGeneration: Int64 = 1
    var historyStartOffset: Int64 = 100
    var playbackOffset: Int64 = 200
    static let unknown = Self(openGeneration: -1, seekGeneration: -1,
                              historyStartOffset: -1, playbackOffset: -1)
}
private struct SPTorrentPlaybackWindow {
    let historyLowerBound: Int64
    let playbackOffset: Int64
    let forwardUpperBound: Int64
    var prefetchCapacityStop: SPTorrentPrefetchCapacityStop?
}
@MainActor private final class TestCore {
    enum State { case opening, ready, playing, paused, idle, ended, failed }
    var state = State.paused
    var seekSettled = true
    var sourcePlaybackWindow = MediaWindow()
    var seekTargets: [Double] = []
    func seek(to target: Double, precise: Bool, forward: Bool) {
        SPTorrentServer.shared.seekOrder.append("core")
        seekTargets.append(target)
        seekSettled = false
        sourcePlaybackWindow = .unknown
    }
}
@MainActor private final class TestPauseBuffer {
    var cancellations = 0
    func cancel() { cancellations += 1 }
}
@MainActor private final class SPTorrentServer {
    static let shared = SPTorrentServer()
    struct Pending {
        let revision: Int
        let reply: SPTorrentPlaybackWindow
        let continuation: CheckedContinuation<SPTorrentPlaybackWindow, any Error>
    }
    var pending: [Pending] = []
    var revision = 0
    var invalidations = 0
    var removals = 0
    var requests = 0
    var remoteWindow: SPTorrentPlaybackWindow?
    var seekOrder: [String] = []
    var remoteSeeking = false
    func beginPlaybackSeek(_ descriptor: Descriptor, file: MediaFile) {
        revision += 1
        remoteSeeking = true
        seekOrder.append("handover")
    }
    func updatePlaybackWindow(_ descriptor: Descriptor, file: MediaFile,
                              historyLowerBound: Int64, playbackOffset: Int64,
                              forwardUpperBound: Int64) async throws -> SPTorrentPlaybackWindow {
        revision += 1; requests += 1
        let revision = revision
        let reply = SPTorrentPlaybackWindow(historyLowerBound: historyLowerBound,
            playbackOffset: playbackOffset, forwardUpperBound: forwardUpperBound)
        remoteWindow = reply // Worker commits before its delayed HTTP reply.
        remoteSeeking = false
        return try await withCheckedThrowingContinuation {
            pending.append(Pending(revision: revision, reply: reply, continuation: $0))
        }
    }
    func invalidatePlaybackWindow(_ descriptor: Descriptor) { revision += 1; invalidations += 1 }
    func endPlaybackWindow(_ descriptor: Descriptor) { revision += 1; removals += 1; remoteWindow = nil }
    func complete() {
        let request = pending.removeFirst()
        if request.revision == revision { request.continuation.resume(returning: request.reply) }
        else { request.continuation.resume(throwing: CancellationError()) }
    }
}
@MainActor private final class Controller {
    enum Diagnostic { case seek }
    func recordPlaybackDiagnostic(_ event: Diagnostic, control: Diagnostic,
                                  seekTarget: Double, commandValue: Double) {}
    struct AppliedTorrentPlaybackWindow {
        let leaseID: UUID
        let fileID: Int
        let openGeneration: Int64
        let seekGeneration: Int64
        let historyLowerBound: Int64
        let requestedHistoryLowerBound: Int64
        let playbackOffset: Int64
        let forwardUpperBound: Int64
        var prefetchCapacityStop: SPTorrentPrefetchCapacityStop?
    }
    var torrentContext: Context? = Context()
    var hasMediaSession = true
    var torrentCacheRestartToken: UUID?
    var core: TestCore? = TestCore()
    var torrentPlaybackWindowEpoch = UUID()
    var torrentPlaybackWindowTask: Task<Void, Never>?
    var torrentAppliedPlaybackWindow: AppliedTorrentPlaybackWindow?
    var torrentPauseBuffer = TestPauseBuffer()
    var authorizedFills = 0
    func updateTorrentPauseBuffer() { authorizedFills += 1 }
    func start() { startTorrentPlaybackWindowPolicyIfNeeded() }
    func seek(_ target: Double) { issueForegroundSeek(to: target) }
    private func yieldDirectoryScanToForegroundIO() {}
    private func cancelTorrentPauseBuffer() { torrentPauseBuffer.cancel() }
    // INSERT_PRODUCTION_SEEK_METHOD
    func cancel(terminal: Bool = false) { cancelTorrentPlaybackWindowPolicy(releaseRetainedWindow: terminal) }
    // INSERT_PRODUCTION_WINDOW_METHODS
}

@main @MainActor private struct TorrentWindowLifecycleChecks {
    static var assertions = 0
    static func check(_ value: Bool, _ message: String) {
        guard value else { print("FAIL: \(message)"); exit(1) }
        assertions += 1; print("PASS \(assertions): \(message)")
    }
    static func wait(_ predicate: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
    static func main() async {
        let server = SPTorrentServer.shared
        let vc = Controller()
        vc.start()
        check(await wait { server.pending.count == 1 }, "A valid paused source sends its first media window")
        server.complete()
        check(await wait { vc.torrentAppliedPlaybackWindow != nil }, "A current acknowledgement authorizes bounded fill")
        let originalFills = vc.authorizedFills
        vc.core!.sourcePlaybackWindow = .unknown
        check(await wait { vc.torrentAppliedPlaybackWindow == nil }, "A transient unknown mapping revokes local fill authorization")
        check(server.remoteWindow?.playbackOffset == 200 && server.removals == 0,
              "Transient unknown Core data retains the worker's prior cache window")
        check(vc.authorizedFills == originalFills, "An unknown mapping cannot authorize another background fill")
        vc.core!.sourcePlaybackWindow = MediaWindow(seekGeneration: 2,
            historyStartOffset: 120, playbackOffset: 220)
        check(await wait { server.pending.count == 1 }, "A completed tiny seek requests the replacement media window")
        server.complete()
        check(await wait { vc.torrentAppliedPlaybackWindow?.seekGeneration == 2 },
              "The new valid seek window atomically replaces its predecessor")
        check(server.removals == 0, "Seek handover has no destructive removal gap")

        vc.core!.sourcePlaybackWindow.playbackOffset = 230
        check(await wait { server.pending.count == 1 }, "A changed accepted playhead starts a policy update")
        server.invalidatePlaybackWindow(vc.torrentContext!.descriptor)
        server.complete() // A stale revision, while the controller task is live.
        check(await wait { server.pending.count == 1 },
              "A stale acknowledgement CancellationError does not terminate the live monitor")
        server.complete()
        check(await wait { vc.torrentAppliedPlaybackWindow?.playbackOffset == 230 },
              "The same live monitor eventually applies the current window")

        vc.core!.sourcePlaybackWindow.playbackOffset = 240
        check(await wait { server.pending.count == 1 }, "A reply can remain pending during explicit cancellation")
        vc.cancel()
        server.complete()
        try? await Task.sleep(for: .milliseconds(300))
        check(vc.torrentAppliedPlaybackWindow == nil && vc.torrentPlaybackWindowTask == nil,
              "An actually cancelled task cannot revive an old acknowledgement")
        check(server.pending.isEmpty && server.removals == 0,
              "Cancelled old epochs neither restart themselves nor destroy the retained cache")
        vc.start()
        check(await wait { server.pending.count == 1 }, "The current source can explicitly restart its monitor")
        server.complete()
        check(await wait { vc.torrentAppliedPlaybackWindow?.playbackOffset == 240 },
              "A fresh controller epoch accepts only its new acknowledgement")

        vc.core!.sourcePlaybackWindow.playbackOffset = 250
        check(await wait { server.pending.count == 1 }, "The old source can have an in-flight reply before replacement")
        let originalContext = vc.torrentContext
        vc.torrentContext = Context() // Same file shape, a different source lease.
        server.complete()
        check(await wait { vc.torrentPlaybackWindowTask == nil }, "A lease change ends the obsolete monitor")
        check(vc.torrentAppliedPlaybackWindow?.playbackOffset != 250,
              "A different lease cannot inherit the old source's late acknowledgement")
        vc.torrentContext = originalContext
        let retainedBeforeSeek = server.remoteWindow?.playbackOffset
        server.seekOrder.removeAll()
        vc.seek(500)
        check(server.seekOrder == ["handover", "core"] && vc.core!.seekTargets == [500],
              "Foreground seeking reserves handover before dispatching the immediate Core seek")
        check(server.remoteSeeking && server.remoteWindow?.playbackOffset == retainedBeforeSeek,
              "A seek softens the old reservation while preserving its resident cache")
        try? await Task.sleep(for: .milliseconds(300))
        check(server.pending.isEmpty && !vc.core!.seekSettled,
              "An unsettled far seek never invents a time-to-byte playback anchor")
        vc.seek(600)
        check(vc.core!.seekTargets == [500, 600] && server.remoteSeeking,
              "A rapid second seek immediately supersedes the first intent")
        vc.core!.seekSettled = true
        vc.core!.sourcePlaybackWindow = MediaWindow(seekGeneration: 3,
            historyStartOffset: 600_000, playbackOffset: 650_000)
        check(await wait { server.pending.count == 1 }, "The new packet mapping replaces seek handover after landing")
        server.complete()
        check(await wait { vc.torrentAppliedPlaybackWindow?.playbackOffset == 650_000 && !server.remoteSeeking },
              "Only the landed exact byte window authorizes new background filling")
        vc.cancel(terminal: true)
        check(server.removals == 1 && server.remoteWindow == nil,
              "A terminal source boundary explicitly releases retained ownership")
        print("Torrent playback-window lifecycle checks passed (\(assertions) assertions).")
    }
}

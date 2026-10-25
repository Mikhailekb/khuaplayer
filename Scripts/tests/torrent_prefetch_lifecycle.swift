import Foundation

private struct SPTorrentPrefetchCapacityStop: Equatable {
    let requestID: UUID
    let fileID: Int
    let rangeStart: Int64
    let rangeEnd: Int64
    let nextOffset: Int64
    let revision: Int64
}

private struct Context {
    struct Descriptor { let hash = "owned-fixture"; let leaseID = UUID() }
    struct MediaFile { let id = 7; let length: Int64 = 1_048_576 }
    let descriptor = Descriptor()
    let file = MediaFile()
    let streamURL = URL(string: "http://127.0.0.1/owned-fixture")!
}
@MainActor private final class Core {
    enum State { case opening, ready, playing, paused, idle, ended, failed }
    struct Window { var openGeneration: Int64 = 1; var seekGeneration: Int64 = 1 }
    var state = State.playing
    var seekSettled = true
    var sourceReadOffset: Int64 = 256
    var sourcePlaybackWindow = Window()
}
@MainActor private final class SPTorrentPauseBuffer {
    struct Identity { let hash: String; let fileID: Int; let sessionGeneration: UUID }
    enum State { case idle, filling, filled, waitingForCapacity, stopped, failed }
    struct Snapshot { var state = State.idle }
    var snapshot = Snapshot()
    var starts = 0
    var cancellations = 0
    var lastCapacityStop: SPTorrentPrefetchCapacityStop?
    var lastOffset: Int64?
    func start(identity: Identity, streamURL: URL, offset: Int64, fileLength: Int64, forwardEndOffset: Int64,
               capacityStop: SPTorrentPrefetchCapacityStop? = nil) {
        lastCapacityStop = capacityStop
        lastOffset = offset
        starts += 1; snapshot.state = .filling
    }
    func cancel() { cancellations += 1; snapshot.state = .idle }
    func stop() { snapshot.state = .stopped }
}
@MainActor private final class Controller {
    struct AppliedWindow {
        let leaseID: UUID
        let fileID: Int
        var openGeneration: Int64 = 1
        var seekGeneration: Int64 = 1
        var historyLowerBound: Int64 = 0
        let forwardUpperBound: Int64 = 65536
        var prefetchCapacityStop: SPTorrentPrefetchCapacityStop?
    }
    var torrentContext: Context? = Context()
    var core: Core? = Core()
    var hasMediaSession = true
    var torrentCacheRestartToken: UUID?
    var torrentResolving = false
    var torrentAppliedPlaybackWindow: AppliedWindow?
    var torrentPauseBuffer = SPTorrentPauseBuffer()
    var torrentPauseBufferManuallyStopped = false
    var torrentPauseBufferMonitor: Task<Void, Never>?
    var torrentPauseBufferMonitorGeneration = UUID()
    init() {
        torrentAppliedPlaybackWindow = AppliedWindow(leaseID: torrentContext!.descriptor.leaseID,
                                                     fileID: torrentContext!.file.id)
    }
    func refreshPlaylistView() {}
    func updateTorrentBackgroundJobs() {}
    func startTorrentPlaybackWindowPolicyIfNeeded() {}
    func cancelTorrentPlaybackWindowPolicy(releaseRetainedWindow: Bool = false) {}
    func stateChanged(_ state: Core.State) {
        core!.state = state
        // INSERT_PRODUCTION_STATE_BOUNDARY
    }
    func update() { updateTorrentPauseBuffer() }
    func close() { cancelTorrentPauseBuffer(resetManualStop: true) }
    // INSERT_PRODUCTION_PREFETCH_METHODS
}

@main @MainActor private struct TorrentPrefetchLifecycleChecks {
    static var assertions = 0
    static func check(_ value: Bool, _ message: String) {
        guard value else { print("FAIL: \(message)"); exit(1) }
        assertions += 1; print("PASS \(assertions): \(message)")
    }
    static func main() async {
        let vc = Controller()
        vc.update()
        check(vc.torrentPauseBuffer.snapshot.state == .filling,
              "A playing source with a current worker ACK starts bounded forward prefetch")
        let cancels = vc.torrentPauseBuffer.cancellations
        vc.stateChanged(.paused); vc.update()
        check(vc.torrentPauseBuffer.cancellations == cancels,
              "Pausing preserves the existing valid prefetch reader")
        vc.stateChanged(.playing); vc.update()
        check(vc.torrentPauseBuffer.cancellations == cancels,
              "Resuming playback preserves the same valid prefetch reader")
        check(vc.torrentPauseBufferMonitor != nil,
              "Both playing and paused sessions retain a frontier monitor")

        vc.torrentAppliedPlaybackWindow!.historyLowerBound = 4096
        vc.core!.sourceReadOffset = 256
        vc.update()
        check(vc.torrentPauseBuffer.lastOffset == 4096,
              "A stale metadata read cursor cannot start prefetch below the worker's accepted lower bound")
        vc.stateChanged(.paused)
        vc.core!.sourceReadOffset = 0
        vc.update()
        check(vc.torrentPauseBuffer.lastOffset == 4096,
              "A paused source also skips the rejected old byte region after a metadata rewind")
        vc.core!.sourceReadOffset = 8192
        vc.update()
        check(vc.torrentPauseBuffer.lastOffset == 8192,
              "An actual read frontier inside the accepted window remains unchanged")
        vc.torrentAppliedPlaybackWindow!.historyLowerBound = 0
        vc.core!.sourceReadOffset = 256

        let proof = SPTorrentPrefetchCapacityStop(requestID: UUID(), fileID: 7,
            rangeStart: 256, rangeEnd: 65536, nextOffset: 32768, revision: 1)
        vc.torrentAppliedPlaybackWindow!.prefetchCapacityStop = proof
        vc.update()
        check(vc.torrentPauseBuffer.lastCapacityStop == proof,
              "The current worker ACK passes its capacity-stop proof to the bounded reader")
        vc.torrentPauseBuffer.snapshot.state = .waitingForCapacity
        vc.toggleTorrentPauseBuffer()
        let stoppedWhileWaiting = vc.torrentPauseBuffer.starts
        check(vc.torrentPauseBufferManuallyStopped && vc.torrentPauseBuffer.snapshot.state == .stopped,
              "Stop while waiting for cache space disables future automatic refill")
        vc.stateChanged(.playing); vc.update()
        vc.stateChanged(.paused); vc.update()
        check(vc.torrentPauseBuffer.starts == stoppedWhileWaiting,
              "Play, pause and polling cannot restart a manually stopped capacity wait")
        vc.toggleTorrentPauseBuffer()
        check(!vc.torrentPauseBufferManuallyStopped && vc.torrentPauseBuffer.starts > stoppedWhileWaiting,
              "Explicit Resume re-enables filling after a stopped capacity wait")

        vc.stateChanged(.playing)
        vc.torrentPauseBuffer.snapshot.state = .failed
        let startsBeforeRetry = vc.torrentPauseBuffer.starts
        vc.toggleTorrentPauseBuffer()
        check(vc.torrentPauseBuffer.starts > startsBeforeRetry && vc.torrentPauseBuffer.snapshot.state == .filling,
              "The existing control can explicitly retry a failed fill while playback continues")
        vc.toggleTorrentPauseBuffer()
        let starts = vc.torrentPauseBuffer.starts
        check(vc.torrentPauseBufferManuallyStopped && vc.torrentPauseBuffer.snapshot.state == .stopped,
              "The existing control explicitly stops forward filling while playing")
        vc.stateChanged(.playing); vc.update()
        vc.stateChanged(.paused); vc.update()
        check(vc.torrentPauseBuffer.starts == starts && vc.torrentPauseBufferManuallyStopped,
              "Manual Stop remains effective across play and pause transitions")
        vc.toggleTorrentPauseBuffer()
        check(!vc.torrentPauseBufferManuallyStopped && vc.torrentPauseBuffer.starts > starts,
              "Explicit Resume re-enables bounded forward filling")

        vc.torrentPauseBuffer.snapshot.state = .filled
        let fullStarts = vc.torrentPauseBuffer.starts
        vc.toggleTorrentPauseBuffer()
        check(vc.torrentPauseBufferManuallyStopped && vc.torrentPauseBuffer.snapshot.state == .idle,
              "Stop remains available when the current rolling window is already full")
        vc.stateChanged(.playing); vc.update()
        vc.stateChanged(.paused); vc.update()
        check(vc.torrentPauseBuffer.starts == fullStarts && vc.torrentPauseBufferManuallyStopped,
              "Stopping a full window also prevents future automatic fills across playback transitions")
        vc.toggleTorrentPauseBuffer()
        check(!vc.torrentPauseBufferManuallyStopped && vc.torrentPauseBuffer.starts > fullStarts,
              "Resume after stopping a full window restores forward filling")

        vc.core!.sourcePlaybackWindow.seekGeneration = 2
        vc.core!.seekSettled = false; vc.update()
        check(vc.torrentPauseBuffer.snapshot.state == .idle,
              "An unsettled seek cancels prefetch from the previous playback epoch")
        let beforeAck = vc.torrentPauseBuffer.starts
        vc.core!.seekSettled = true; vc.update()
        check(vc.torrentPauseBuffer.starts == beforeAck,
              "A stale ACK cannot authorize prefetch in the new seek generation")
        vc.torrentAppliedPlaybackWindow!.seekGeneration = 2
        vc.update()
        check(vc.torrentPauseBuffer.starts > beforeAck,
              "Only the matching new worker ACK authorizes the post-seek fill")

        vc.stateChanged(.opening)
        check(vc.torrentPauseBuffer.snapshot.state == .idle && vc.torrentPauseBufferMonitor == nil,
              "Opening a replacement source stops the old reader and monitor")
        vc.close()
        check(!vc.torrentPauseBufferManuallyStopped, "Source close resets the per-source manual Stop preference")
        print("Torrent prefetch lifecycle checks passed (\(assertions) assertions).")
    }
}

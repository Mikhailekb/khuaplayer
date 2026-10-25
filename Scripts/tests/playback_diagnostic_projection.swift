import Foundation

@MainActor private final class SPPlaybackDiagnostics {
    // INSERT_SCHEMA
    struct Record {
        let event: Event
        let values: [Field: Int64]
        let ranges: [ByteRange]
        let total: Int
    }
    var records: [Record] = []
    func record(_ event: Event, values: [Field: Int64], completeRanges: [ByteRange] = [], completeRangeCount: Int? = nil) {
        records.append(Record(event: event, values: values, ranges: completeRanges,
                              total: completeRangeCount ?? completeRanges.count))
    }
}

private enum SPPlayerState: Int { case idle, opening, ready, playing, paused, ended, failed }
private enum WaitReason: Int { case none, bytes, index, pipeline }
private struct SourceWindow {
    var openGeneration: Int64 = 10, seekGeneration: Int64 = 20
    var historyStartOffset: Int64 = 200, playbackOffset: Int64 = 300
}
@MainActor private final class SPPlayerCore {
    var state = SPPlayerState.paused
    var position = 12.25, duration = 100.5
    var sourcePlaybackWindow = SourceWindow()
    var sourceReadOffset: Int64 = 400
    var sourceWaiting = false, sourceStalled = false, sourcePlaybackWaiting = false
    var sourceGrowing = false, seekSettled = false, sourceWaitingForIndex = false, contentSearching = false
    var sourcePlaybackWaitReason = WaitReason.none
    var currentFilePath: String { fatalError("Diagnostics must not read media paths") }
}
private struct Context {
    struct File { var id: Int = 7 }
    struct Descriptor {
        var leaseID: UUID
        var hash: String { fatalError("Diagnostics must not read torrent hashes") }
    }
    var file = File()
    var descriptor: Descriptor
}
private struct AppliedWindow {
    var openGeneration: Int64 = 10, seekGeneration: Int64 = 20
    var historyLowerBound: Int64 = 150, requestedHistoryLowerBound: Int64 = 200
    var playbackOffset: Int64 = 300, forwardUpperBound: Int64 = 5000
    var fileID = 7
}
private struct CacheSnapshot {
    var ranges: [Range<Int64>]
    var residentBytes: Int64 = 600
    var fileOffset: Int64 = 9000
}
@MainActor private final class PauseBuffer {
    enum State { case idle, filling, filled, waitingForCapacity, stopped, failed }
    struct Identity { var fileID: Int; var sessionGeneration: UUID }
    struct Snapshot {
        var state = State.idle
        var receivedBytes: Int64 = 101, budgetBytes: Int64 = 200
        var rangeStart: Int64? = 300, rangeEnd: Int64? = 500
        var identity: Identity?
    }
    var snapshot = Snapshot()
}
@MainActor private final class Controller {
    var core: SPPlayerCore? = SPPlayerCore()
    let playbackDiagnostics = SPPlaybackDiagnostics()
    var playbackDiagnosticTimer: Timer?
    var lastPlaybackDiagnosticSnapshotAt: TimeInterval = 0
    var torrentContext: Context?
    var torrentAppliedPlaybackWindow: AppliedWindow?
    var torrentLastCacheSnapshot: CacheSnapshot?
    struct Status { var bufferCapacityBytes: Int64 = 1024 }
    var torrentLastStatus: Status?
    var bufferConstructions = 0
    lazy var torrentPauseBuffer: PauseBuffer = { bufferConstructions += 1; return PauseBuffer() }()
    var scrollSeekTarget: Double?
    var scrollSeekWasPlaying = false, burstWasPlaying = false, burstStepCount = 0, isScrubbing = false
    struct Turbo { var blocksPlaybackControls = false }
    var turbo = Turbo()
    var torrentCacheRestartToken: UUID?
    var torrentPauseBufferManuallyStopped = false
    var last: SPPlaybackDiagnostics.Record { playbackDiagnostics.records.last! }
    func sample(_ event: SPPlaybackDiagnostics.Event = .snapshot, control: SPPlaybackDiagnostics.Control? = nil,
                target: Double? = nil, value: Double? = nil) {
        recordPlaybackDiagnostic(event, control: control, seekTarget: target, commandValue: value)
    }
    func timedSample() { recordPlaybackDiagnosticSnapshotIfNeeded() }
    func timer(_ state: SPPlayerState) { updatePlaybackDiagnosticTimer(for: state) }
    // INSERT_METHODS
}

@main @MainActor private struct PlaybackDiagnosticProjectionChecks {
    static var count = 0
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { print("FAIL: \(message)"); exit(1) }
        count += 1
    }
    static func main() {
        let empty = Controller(); empty.core = nil; empty.sample()
        check(empty.playbackDiagnostics.records.isEmpty, "A missing core produces no invented snapshot")
        let local = Controller(); local.sample()
        check(local.bufferConstructions == 0, "Local playback never initializes the torrent pause buffer for diagnostics")
        check(local.last.values[.positionUs] == 12_250_000 && local.last.values[.durationUs] == 100_500_000,
              "Finite time values retain microsecond precision")
        check(local.last.values[.rangesKnown] == 0 && local.last.values[.residentBytes] == -1 &&
              local.last.values[.prefetchState] == -1 && local.last.values[.selectedFileID] == -1,
              "Unknown/local torrent fields use numerical absence sentinels")
        check(local.last.ranges.isEmpty && local.last.total == 0 && local.last.values[.control] == nil,
              "Snapshots do not manufacture ranges or explicit actions")
        local.core!.position = .nan; local.core!.duration = .infinity
        local.sample(.seek, control: .seek, target: -.infinity, value: .nan)
        check([.positionUs, .durationUs, .seekTargetUs, .commandValueMilli].allSatisfy { local.last.values[$0] == -1 },
              "Nonfinite times and command values cannot crash integer conversion")
        local.core!.position = Double(Int64.max)
        local.core!.duration = Double(Int64.min)
        local.sample(.control, control: .setRate, value: Double(Int64.max) / 1000)
        check(local.last.values[.positionUs] == -1 && local.last.values[.durationUs] == -1 && local.last.values[.commandValueMilli] == -1,
              "Scaled overflow and the rounded Int64 upper boundary are rejected")
        local.sample(.seek, control: .seek, target: 15.875, value: -0.25)
        check(local.last.event == .seek && local.last.values[.control] == 4 &&
              local.last.values[.seekTargetUs] == 15_875_000 && local.last.values[.commandValueMilli] == -250,
              "Explicit actions preserve their fixed enum and signed numeric argument")
        local.core!.sourceWaiting = true; local.core!.sourceStalled = true
        local.core!.sourcePlaybackWaiting = true; local.core!.sourceGrowing = true
        local.core!.seekSettled = true; local.core!.sourceWaitingForIndex = true; local.core!.contentSearching = true
        local.core!.sourcePlaybackWaitReason = .pipeline
        local.scrollSeekTarget = 1; local.scrollSeekWasPlaying = true; local.burstWasPlaying = true
        local.burstStepCount = 2; local.isScrubbing = true; local.turbo.blocksPlaybackControls = true
        local.torrentCacheRestartToken = UUID(); local.torrentPauseBufferManuallyStopped = true
        local.sample(.sourceWait)
        check(local.last.values[.waitFlags] == 127 && local.last.values[.waitReason] == 3,
              "Seven source flags and the pipeline wait reason remain distinguishable")
        check(local.last.values[.interactionFlags] == 255, "All transient interaction ownership bits are independent")

        let torrent = Controller(), lease = UUID()
        torrent.torrentContext = Context(descriptor: .init(leaseID: lease))
        torrent.torrentAppliedPlaybackWindow = AppliedWindow()
        torrent.torrentLastStatus = .init()
        torrent.torrentPauseBuffer.snapshot.identity = .init(fileID: 7, sessionGeneration: lease)
        let states: [PauseBuffer.State] = [.idle, .filling, .filled, .waitingForCapacity, .stopped, .failed]
        for (index, state) in states.enumerated() {
            torrent.torrentPauseBuffer.snapshot.state = state; torrent.sample()
            check(torrent.last.values[.prefetchState] == Int64(index), "Prefetch enum case \(index) has a stable numeric code")
        }
        check(torrent.last.values[.prefetchFileID] == 7 && torrent.last.values[.prefetchMatchesContext] == 1,
              "A matching prefetch snapshot is explicitly tied to the selected file and lease")
        torrent.torrentPauseBuffer.snapshot.identity = .init(fileID: 8, sessionGeneration: lease)
        torrent.sample()
        check(torrent.last.values[.prefetchFileID] == 8 && torrent.last.values[.prefetchMatchesContext] == 0,
              "An old episode's prefetch bytes cannot masquerade as a matching snapshot")
        torrent.torrentPauseBuffer.snapshot.identity = .init(fileID: 7, sessionGeneration: UUID())
        torrent.sample()
        check(torrent.last.values[.prefetchMatchesContext] == 0, "A same-file prefetch from an old lease is visibly stale")
        torrent.torrentLastCacheSnapshot = CacheSnapshot(ranges: (0..<80).map { Int64($0 * 100)..<Int64($0 * 100 + 25) })
        torrent.sample()
        check(torrent.last.ranges.count == 64 && torrent.last.total == 80,
              "The controller copies only 64 ranges while preserving the actual full count")
        check(torrent.last.ranges[1].lower == 100 && torrent.last.ranges[1].upper == 125,
              "The projection preserves cache holes and exclusive byte bounds")
        check(torrent.last.values[.rangesKnown] == 1 && torrent.last.values[.fileOffsetByte] == 9000 &&
              torrent.last.values[.residentBytes] == 600 && torrent.last.values[.capacityBytes] == 1024,
              "Resident bytes, file offset and capacity stay separate numerical quantities")
        check(torrent.last.values[.historyLowerByte] == 150 && torrent.last.values[.requestedHistoryLowerByte] == 200 &&
              torrent.last.values[.playbackHistoryByte] == 200 && torrent.last.values[.appliedPlaybackByte] == 300,
              "Native source history and acknowledged worker retention remain distinguishable")
        check(torrent.last.values[.openGeneration] == torrent.last.values[.appliedOpenGeneration] &&
              torrent.last.values[.seekGeneration] == torrent.last.values[.appliedSeekGeneration],
              "A current worker acknowledgement exposes matching source generations")
        torrent.core!.sourcePlaybackWindow.openGeneration = 11
        torrent.core!.sourcePlaybackWindow.seekGeneration = 21
        torrent.torrentContext!.file.id = 8
        torrent.sample()
        check(torrent.last.values[.appliedOpenGeneration] == 10 && torrent.last.values[.appliedSeekGeneration] == 20 &&
              torrent.last.values[.openGeneration] == 11 && torrent.last.values[.seekGeneration] == 21 &&
              torrent.last.values[.selectedFileID] == 8 && torrent.last.values[.appliedFileID] == 7,
              "A stale worker ACK retains its own file and generations instead of borrowing the new source identity")
        torrent.torrentLastCacheSnapshot = CacheSnapshot(ranges: [])
        torrent.sample()
        check(torrent.last.values[.rangesKnown] == 1 && torrent.last.ranges.isEmpty,
              "Known empty coverage differs from an unavailable cache snapshot")

        let cadence = Controller()
        cadence.lastPlaybackDiagnosticSnapshotAt = ProcessInfo.processInfo.systemUptime - 3
        cadence.timedSample(); cadence.timedSample()
        check(cadence.playbackDiagnostics.records.count == 1, "Timer and poll callers share one two-second snapshot throttle")
        cadence.lastPlaybackDiagnosticSnapshotAt = ProcessInfo.processInfo.systemUptime + 3
        cadence.timedSample()
        check(cadence.playbackDiagnostics.records.count == 1, "A future throttle clock does not generate a burst")
        cadence.timer(.playing)
        let timer = cadence.playbackDiagnosticTimer
        cadence.timer(.paused)
        check(timer?.isValid == true && cadence.playbackDiagnosticTimer === timer,
              "Pausing preserves one active snapshot timer instead of adding another")
        cadence.timer(.idle)
        check(cadence.playbackDiagnosticTimer == nil && timer?.isValid == false, "Idle invalidates the session timer")
        cadence.timer(.playing); let failedTimer = cadence.playbackDiagnosticTimer
        cadence.timer(.failed)
        check(cadence.playbackDiagnosticTimer == nil && failedTimer?.isValid == false, "Failure invalidates the session timer")
        var transient: Controller? = Controller()
        transient!.timer(.playing)
        let orphanTimer = transient!.playbackDiagnosticTimer!
        weak var weakOwner: Controller?
        weakOwner = transient
        transient = nil
        check(weakOwner == nil, "A scheduled snapshot timer cannot retain its player controller")
        orphanTimer.fire()
        check(!orphanTimer.isValid, "A timer whose weak owner disappeared invalidates itself")
        print("PASS: \(count) actual controller diagnostic projection checks")
    }
}

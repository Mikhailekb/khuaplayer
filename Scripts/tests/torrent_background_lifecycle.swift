import Foundation

private enum SPPlayerState { case idle, opening, ready, playing, paused, ended, failed }
private struct SPTorrentPlaybackContext: Sendable {
    struct Descriptor: Sendable { var leaseID = UUID(); var hash = "owned-test" }
    struct File: Sendable { var id = 3; var length: Int64 = 100_000 }
    var descriptor = Descriptor()
    var file = File()
    var streamURL = URL(string: "http://owned.invalid/video")!
}
@MainActor private final class SPPlayerCore {
    struct SourceWindow { var openGeneration: Int64 = 1 }
    var state = SPPlayerState.playing
    var currentFilePath = "http://owned.invalid/video"
    var sourcePlaybackWindow = SourceWindow()
    var sourcePlaybackWaiting = false, seekSettled = true
    var currentSubtitleTrackIndex = 2
    var timelineOriginUs: Int64 = 400
    var torrentPreviewPreparationPending = true
    var previewPaused = true
    var previewChanges: [Bool] = []
    var configuredURLs: [URL?] = []
    var adoptionCalls = 0
    var adoptionReturn = true
    var adoptionCompletions: [@MainActor (Bool) -> Void] = []
    func setTorrentPreviewPreparationPaused(_ paused: Bool) { previewPaused = paused; previewChanges.append(paused) }
    func configureTorrentPreviewSourceURL(_ source: URL?, cacheDirectoryURL: URL?, forMediaURL: URL) -> Bool {
        guard forMediaURL.absoluteString == currentFilePath else { return false }
        configuredURLs.append(source)
        return source != nil && cacheDirectoryURL != nil
    }
    func adoptCachedEmbeddedSubtitleFile(_ path: String, streamIndex: Int,
                                        completion: @escaping @MainActor (Bool) -> Void) -> Bool {
        adoptionCalls += 1
        adoptionCompletions.append(completion)
        return adoptionReturn
    }
    func completeAdoption(_ accepted: Bool) { adoptionCompletions.removeFirst()(accepted) }
}
@MainActor private final class SPTorrentServer {
    static let shared = SPTorrentServer()
    struct Lane { let file: Int; let consumer: UUID; let lease: UUID }
    var opened: [Lane] = [], ended: [Lane] = []
    func backgroundStreamURL(_ descriptor: SPTorrentPlaybackContext.Descriptor,
                             file: SPTorrentPlaybackContext.File, consumer: UUID) throws -> URL {
        opened.append(.init(file: file.id, consumer: consumer, lease: descriptor.leaseID))
        return URL(string: "http://owned.invalid/background/\(consumer)")!
    }
    func endBackgroundStream(_ descriptor: SPTorrentPlaybackContext.Descriptor, consumer: UUID) {
        ended.append(.init(file: -1, consumer: consumer, lease: descriptor.leaseID))
    }
}
@MainActor private enum SPTorrentPreviewCacheStore {
    struct Identity: Sendable {
        let file: Int
        init?(infoHash: String, fileID: Int, fileLength: Int64) {
            guard !infoHash.isEmpty, fileID >= 0, fileLength > 0 else { return nil }
            file = fileID
        }
    }
    struct Request {
        let identity: Identity
        let continuation: CheckedContinuation<URL, any Error>
    }
    static var requests: [Request] = []
    static func prepareDirectory(for identity: Identity) async throws -> URL {
        try await withCheckedThrowingContinuation { requests.append(.init(identity: identity, continuation: $0)) }
    }
    static func completeFirst() {
        requests.removeFirst().continuation.resume(returning: URL(fileURLWithPath: "/owned-test-preview-cache"))
    }
    static func completeAll() { while !requests.isEmpty { completeFirst() } }
}
private enum CaptionProbeRegistry {
    static let gate = SPTorrentBackgroundGate(initiallyPaused: false)
    static func idle() -> Bool { !gate.shouldPause() }
}
@MainActor private final class SPTorrentSubtitleCache {
    struct Plan {
        struct Identity { let hash: String; let fileID: Int; let length: Int64; let trackID: Int }
        let identity: Identity
        let sessionID: UUID
        let backgroundURL: URL
        let expectedMediaURL: URL
        let timelineOriginUs: Int64
    }
    enum State { case idle, loading, ready, failed }
    struct Snapshot { var state = State.idle }
    struct Start {
        let plan: Plan
        let shouldPause: @Sendable () -> Bool
        let isCurrent: @MainActor () -> Bool
        let adopt: @MainActor (URL, Int) async -> Bool
    }
    var snapshot = Snapshot()
    var isPreparing: Bool { snapshot.state == .loading }
    var onChange: (@MainActor (Snapshot) -> Void)?
    var starts: [Start] = []
    var cancels = 0
    func start(plan: Plan, shouldPause: @escaping @Sendable () -> Bool,
               isCurrent: @escaping @MainActor () -> Bool,
               adopt: @escaping @MainActor (URL, Int) async -> Bool) {
        starts.append(.init(plan: plan, shouldPause: shouldPause, isCurrent: isCurrent, adopt: adopt))
        snapshot.state = .loading; onChange?(snapshot)
    }
    func cancel() { cancels += 1; snapshot.state = .idle; onChange?(snapshot) }
    func publish(_ state: State) { snapshot.state = state; onChange?(snapshot) }
}
@MainActor private final class Controller {
    var core: SPPlayerCore? = SPPlayerCore()
    var torrentContext: SPTorrentPlaybackContext? = SPTorrentPlaybackContext()
    var hasMediaSession = true
    var torrentCacheRestartToken: UUID?
    var torrentResolving = false
    var acknowledged = false
    var torrentPauseWindowReady: Bool { acknowledged && core?.seekSettled == true }
    var torrentPauseBufferManuallyStopped = false
    var activeExternalSubtitleURL: URL?
    var captionsDisplayActive = false
    private let torrentBackgroundOwner = UUID()
    private let torrentSubtitleGate = SPTorrentBackgroundGate()
    private var torrentBackgroundSession: TorrentBackgroundSession?
    private var torrentPreviewSetupTask: Task<Void, Never>?
    private var torrentSubtitleCache: SPTorrentSubtitleCache?
    private var torrentBackgroundMutationInProgress = false
    private var torrentSubtitleBackgroundSuppressed = false
    private var torrentExternalSubtitleSelectionPending = false
    private var torrentExternalSubtitleSelectionEpoch = UUID()
    private var heldOldSessions: [TorrentBackgroundSession] = []
    // INSERT_SESSION
    var epoch: UUID? { torrentBackgroundSession?.epoch }
    var cache: SPTorrentSubtitleCache? { torrentSubtitleCache }
    var subtitleConsumer: UUID? { torrentBackgroundSession?.subtitleConsumer }
    var previewConsumer: UUID? { torrentBackgroundSession?.previewConsumer }
    var previewConfigured: Bool { torrentBackgroundSession?.previewConfigured == true }
    var subtitlePaused: Bool { torrentSubtitleGate.shouldPause() }
    var isCurrent: Bool { torrentBackgroundSession.map(torrentBackgroundSessionIsCurrent) ?? false }
    func update() { updateTorrentBackgroundJobs() }
    func refresh() { refreshTorrentBackgroundAdmission() }
    func seek() { pauseTorrentBackgroundJobsForSeek() }
    func close() { cancelTorrentBackgroundJobs(); hasMediaSession = false }
    func suppress(_ value: Bool) { torrentSubtitleBackgroundSuppressed = value; update() }
    func externalPending(_ value: Bool) { torrentExternalSubtitleSelectionPending = value; update() }
    func oldAdmission() -> @MainActor (Bool, Bool) -> Void {
        let session = torrentBackgroundSession
        if let session { heldOldSessions.append(session) }
        return // INSERT_ADMISSION_CALLBACK
    }
    // INSERT_METHODS
}

@main @MainActor private struct TorrentBackgroundLifecycleChecks {
    static var count = 0
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { print("FAIL: \(message)"); exit(1) }
        count += 1
    }
    static func spin(until condition: @MainActor () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        check(false, "An owned asynchronous fixture reached its expected suspension/completion")
    }
    static func drainDirectories() async {
        for _ in 0..<5 { await Task.yield(); SPTorrentPreviewCacheStore.completeAll() }
    }
    static func main() async {
        let controller = Controller(), server = SPTorrentServer.shared
        controller.update()
        check(controller.epoch == nil && server.opened.isEmpty, "No background consumer starts before the primary playback-window ACK")
        controller.acknowledged = true; controller.update()
        let firstEpoch = controller.epoch!, firstConsumer = controller.subtitleConsumer!, firstStart = controller.cache!.starts[0]
        check(controller.cache!.starts.count == 1 && firstStart.plan.identity.trackID == 2 && firstStart.plan.timelineOriginUs == 400,
              "The first acknowledged open starts one subtitle job with the selected track and source timeline")
        check(!firstStart.shouldPause() && firstStart.isCurrent(), "Subtitle preparation receives admission for the current open")
        controller.core!.state = .paused; controller.update()
        controller.core!.state = .playing; controller.update()
        check(controller.epoch == firstEpoch && controller.subtitleConsumer == firstConsumer && controller.cache!.starts.count == 1,
              "Pausing and playing preserve the same whole-file background job")
        controller.core!.sourcePlaybackWaiting = true; controller.refresh()
        check(controller.subtitlePaused && firstStart.shouldPause(), "Foreground byte waiting yields subtitle background admission")
        controller.core!.sourcePlaybackWaiting = false; controller.core!.seekSettled = false; controller.seek(); controller.update()
        check(controller.subtitlePaused && controller.epoch == firstEpoch && firstStart.isCurrent(), "A seek pauses producers without discarding whole-file subtitle work")
        controller.core!.sourcePlaybackWindow.openGeneration = -1
        check(controller.isCurrent, "A temporarily unavailable packet window during seek still belongs to the same open epoch")
        controller.core!.sourcePlaybackWindow.openGeneration = 1; controller.core!.seekSettled = true; controller.update()
        check(!controller.subtitlePaused && controller.cache!.starts.count == 1, "The same job resumes after the new playback window is ready")
        controller.torrentPauseBufferManuallyStopped = true; controller.refresh()
        check(controller.subtitlePaused, "An explicit buffering stop also yields optional background producers")
        controller.torrentPauseBufferManuallyStopped = false; controller.refresh()
        CaptionProbeRegistry.gate.setPaused(true)
        check(firstStart.shouldPause(), "The native caption probe's busy flag also pauses full subtitle extraction")
        CaptionProbeRegistry.gate.setPaused(false)
        controller.core!.currentSubtitleTrackIndex = 4; controller.update()
        let secondStart = controller.cache!.starts[1]
        check(controller.subtitleConsumer != firstConsumer && secondStart.plan.sessionID == firstEpoch && secondStart.plan.identity.trackID == 4,
              "A selected-track change gets a new consumer while retaining the open's session epoch")
        check(server.ended.filter { $0.consumer == firstConsumer }.count == 1 && !firstStart.isCurrent(),
              "The old subtitle lane is ended once and its captured track becomes stale")
        controller.externalPending(true)
        check(controller.subtitleConsumer == nil && controller.subtitlePaused && !secondStart.isCurrent(),
              "An external selection in flight cancels embedded extraction and denies stale adoption")
        controller.externalPending(false)
        check(controller.cache!.starts.count == 3 && controller.subtitleConsumer != nil,
              "Clearing the pending selection can start the current embedded track again")
        controller.close()
        check(controller.epoch == nil && controller.subtitlePaused && controller.core!.previewPaused,
              "Closing releases the session, producers and gates")
        await drainDirectories()

        let identities = Controller(); identities.acknowledged = true; identities.update()
        let oldIdentityStart = identities.cache!.starts.last!
        identities.torrentContext!.file.id += 1
        check(!identities.isCurrent && !oldIdentityStart.isCurrent(), "The same lease with another episode rejects old background work")
        identities.torrentContext!.file.id -= 1
        identities.core!.currentFilePath = "http://owned.invalid/replaced"
        check(!identities.isCurrent, "A different Core media URL rejects an old session even if the lease matches")
        identities.core!.currentFilePath = identities.torrentContext!.streamURL.absoluteString
        identities.core!.sourcePlaybackWindow.openGeneration += 1
        check(!identities.isCurrent, "A new native open generation rejects the prior session")
        identities.core!.sourcePlaybackWindow.openGeneration = 1
        let oldCore = identities.core!
        identities.core = SPPlayerCore()
        check(!identities.isCurrent, "Replacing the Core object cannot inherit the old open's work")
        identities.core = oldCore; identities.close(); await drainDirectories()

        let late = Controller(); late.acknowledged = true; late.update()
        await spin { !SPTorrentPreviewCacheStore.requests.isEmpty }
        let lateOldEpoch = late.epoch!
        let oldAdmission = late.oldAdmission()
        late.close()
        late.hasMediaSession = true; late.core!.sourcePlaybackWindow.openGeneration = 2; late.update()
        check(late.epoch != lateOldEpoch, "Reopening the same file creates a new per-open epoch")
        let beforeLate = late.core!.configuredURLs.compactMap { $0 }.count
        SPTorrentPreviewCacheStore.completeFirst()
        for _ in 0..<5 { await Task.yield() }
        check(late.core!.configuredURLs.compactMap { $0 }.count == beforeLate, "A late old preview-directory reply cannot configure the replacement source")
        oldAdmission(false, false)
        check(!late.subtitlePaused, "An old controller admission callback cannot clear a new source's grant")
        late.close(); await drainDirectories()

        let ready = Controller(); ready.acknowledged = true; ready.update()
        await spin { !SPTorrentPreviewCacheStore.requests.isEmpty }
        SPTorrentPreviewCacheStore.completeFirst()
        await spin { ready.previewConfigured }
        check(ready.core!.previewPaused && !ready.subtitlePaused, "Full subtitle preparation keeps a configured preview producer paused")
        let readyConsumer = ready.subtitleConsumer!, readyStart = ready.cache!.starts.last!
        ready.cache!.publish(.ready)
        check(ready.subtitlePaused && !ready.core!.previewPaused && server.ended.filter { $0.consumer == readyConsumer }.count == 1,
              "A ready subtitle cache retires its full-file lane and admits preview preparation")
        let previewResumes = ready.core!.previewChanges.filter { !$0 }.count
        ready.refresh(); ready.update()
        check(ready.core!.previewChanges.filter { !$0 }.count == previewResumes,
              "Repeated ready-cache refreshes do not duplicate preview resume grants")
        let accepted = Task { @MainActor in await readyStart.adopt(URL(fileURLWithPath: "/owned-ready.ass"), 2) }
        await spin { !ready.core!.adoptionCompletions.isEmpty }
        ready.core!.completeAdoption(true)
        check(await accepted.value && ready.core!.adoptionCalls == 1, "The asynchronous native adoption callback completes the cache continuation once")
        ready.core!.adoptionReturn = false
        let rejected = Task { @MainActor in await readyStart.adopt(URL(fileURLWithPath: "/owned-ready.ass"), 2) }
        await spin { !ready.core!.adoptionCompletions.isEmpty }
        ready.core!.completeAdoption(false)
        check(await rejected.value == false && ready.core!.adoptionCalls == 2, "An immediately rejected native request still waits for its asynchronous false completion")
        let staleAdopt = readyStart.adopt
        ready.close(); await drainDirectories()
        check(await staleAdopt(URL(fileURLWithPath: "/owned-stale.ass"), 2) == false,
              "A captured completed-cache adoption closure rejects a closed source")
        check(server.ended.filter { $0.consumer == readyConsumer }.count == 1, "Closing a retired ready lane cannot end it twice")
        print("PASS: \(count) actual torrent background lifecycle checks")
    }
}

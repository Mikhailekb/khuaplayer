import Darwin
import Foundation

// The bridge symbol is replaced only in this standalone pure-Swift check.
// Injection tests below never perform HTTP or use the default application path.
final class SPCaptionSubtitleReader {
    var timelineOriginUs: Int64 = 0
    var expectedSourceLength: Int64 = 0
    var lastError: (any Error)?
    private let state = LockedState()
    private let path: String
    private let stream: Int32
    init(path: String, subtitleStreamIndex: Int32) { self.path = path; stream = subtitleStreamIndex }
    func abort() { state.setCancelled() }
    func exportWholeTrack(shouldPause: (() -> Bool)?) -> String? {
        NativeProbe.shared.record(path: path, stream: stream, origin: timelineOriginUs, length: expectedSourceLength)
        while shouldPause?() == true {
            if state.cancelled { return nil }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return state.cancelled ? nil : "1\n00:00:00,000 --> 00:00:01,000\nNative fixture\n\n"
    }
}

private final class NativeProbe: @unchecked Sendable {
    static let shared = NativeProbe()
    private let lock = NSLock()
    private var countValue = 0
    private var values: (String, Int32, Int64, Int64)?
    var count: Int { lock.withLock { countValue } }
    var last: (String, Int32, Int64, Int64)? { lock.withLock { values } }
    func record(path: String, stream: Int32, origin: Int64, length: Int64) {
        lock.withLock { countValue += 1; values = (path, stream, origin, length) }
    }
}

private final class LockedState: @unchecked Sendable {
    private let lock = NSLock()
    private var callsValue = 0
    private var cancelledValue = false
    private var releasedValue = false
    var calls: Int { lock.withLock { callsValue } }
    var cancelled: Bool { lock.withLock { cancelledValue } }
    var released: Bool { lock.withLock { releasedValue } }
    func called() { lock.withLock { callsValue += 1 } }
    func setCancelled() { lock.withLock { cancelledValue = true } }
    func release() { lock.withLock { releasedValue = true } }
}

private struct Extractor: SPTorrentSubtitleExtracting {
    let state: LockedState
    let result: String
    var hold = false
    var failure = false
    func export(plan: SPTorrentSubtitleCache.Plan, shouldPause: @escaping @Sendable () -> Bool,
                cancellation: SPTorrentSubtitleCancellation) throws -> String {
        precondition(!Thread.isMainThread, "Extraction must run off the main thread")
        state.called()
        cancellation.setAbort { state.setCancelled() }
        defer { cancellation.setAbort(nil) }
        while hold && !state.released {
            try cancellation.check()
            Thread.sleep(forTimeInterval: 0.005)
        }
        try cancellation.check()
        if failure { throw SPTorrentSubtitleCacheFailure.extraction }
        return result
    }
}

@MainActor private final class AdoptionState {
    var current = true
    var continuation: CheckedContinuation<Bool, Never>?
}

@main @MainActor
private struct TorrentSubtitleCacheChecks {
    static var checks = 0
    static let files = FileManager.default
    static let text = "1\n00:00:01,250 --> 00:00:02,500\nHello <i>world</i>\n\n"
    static let hash = String(repeating: "a", count: 40)

    static func check(_ condition: Bool, _ message: String) {
        guard condition else { print("FAIL: \(message)"); exit(1) }
        checks += 1
    }
    static func failure(_ message: String, _ body: () throws -> Void) {
        do { try body(); check(false, message) } catch { check(true, message) }
    }
    static func until(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        check(false, "Timed out waiting for owned async fixture")
    }
    static func plan(track: Int = 2, length: Int64 = 12345, file: Int = 5,
                     origin: Int64 = 0, session: UUID = UUID(), port: Int = 12345,
                     torrent: String = hash) -> SPTorrentSubtitleCache.Plan {
        let identity = SPTorrentSubtitleCache.Identity(hash: torrent, fileID: file, length: length, trackID: track)
        let path = "http://worker:fake-secret@127.0.0.1:\(port)/stream/owned.mp4?link=\(torrent)&index=\(file)"
        return .init(identity: identity, sessionID: session,
                     backgroundURL: URL(string: path + "&playback_background=1&playback_parent=\(session.uuidString)&playback_consumer=\(UUID().uuidString)")!,
                     expectedMediaURL: URL(string: path + "&playback_consumer=\(session.uuidString)")!,
                     timelineOriginUs: origin)
    }
    static func mode(_ url: URL) throws -> Int {
        try (files.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue & 0o777
    }
    static func changed(_ plan: SPTorrentSubtitleCache.Plan,
                        background: ((inout [URLQueryItem]) -> Void)? = nil,
                        expected: ((inout [URLQueryItem]) -> Void)? = nil) -> SPTorrentSubtitleCache.Plan {
        var bg = URLComponents(url: plan.backgroundURL, resolvingAgainstBaseURL: false)!
        var primary = URLComponents(url: plan.expectedMediaURL, resolvingAgainstBaseURL: false)!
        var bgItems = bg.queryItems ?? [], expectedItems = primary.queryItems ?? []
        background?(&bgItems); expected?(&expectedItems)
        bg.queryItems = bgItems; primary.queryItems = expectedItems
        return .init(identity: plan.identity, sessionID: plan.sessionID,
                     backgroundURL: bg.url!, expectedMediaURL: primary.url!, timelineOriginUs: plan.timelineOriginUs)
    }

    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath()
        let directory = root.appendingPathComponent("persistent/captions", isDirectory: true)
        let store = SPTorrentSubtitleStore(directory: directory)
        let first = plan()
        check(!files.fileExists(atPath: directory.path), "Store construction performs no writes")
        try check(store.lookup(plan: first) == nil && !files.fileExists(atPath: directory.path),
                  "Cache miss does not create storage")
        let cached = try store.save(text: text, plan: first)
        try check(String(contentsOf: cached, encoding: .utf8) == text, "Completed UTF8 export persists exactly")
        check(cached.lastPathComponent.hasSuffix(".subtext") && cached.lastPathComponent.utf8.count == 72,
              "Filename contains only a SHA256 key and fixed extension")
        try check(mode(directory) == 0o700 && mode(cached) == 0o600,
                  "Caption directory and text are private")
        let receipts = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        check(receipts.count == 1, "A complete receipt accompanies the text")
        let receipt = receipts[0]
        let receiptText = try String(contentsOf: receipt, encoding: .utf8)
        check(!receiptText.contains(hash) && !receiptText.contains("http") && !receiptText.contains("fake-secret") &&
              !receiptText.contains("owned.mp4") && !receiptText.contains("playback_consumer"),
              "Receipt excludes original hash, URLs, source filename and credentials")
        try check(mode(receipt) == 0o600, "Completion receipt is private")
        let restarted = SPTorrentSubtitleStore(directory: directory)
        try check(restarted.lookup(plan: first) == cached, "Persisted caption survives store restart")
        try check(restarted.lookup(plan: plan(port: 54321)) == cached,
                  "Worker port, credential/session changes do not alter persistent identity")
        for changed in [plan(track: 3), plan(length: 12346), plan(file: 6), plan(origin: -1),
                        plan(torrent: String(repeating: "b", count: 40))] {
            try check(restarted.lookup(plan: changed) == nil, "Every media/track/timing identity component isolates the cache")
        }
        let empty = plan(track: 9)
        let emptyURL = try store.save(text: "", plan: empty)
        try check(Data(contentsOf: emptyURL).isEmpty && store.lookup(plan: empty) == emptyURL,
                  "Validated complete zero-cue tracks persist without invented events")
        try Data("corrupt".utf8).write(to: cached)
        try check(store.lookup(plan: first) == nil, "Changed text cannot pass the SHA256 receipt")
        _ = try store.save(text: text, plan: first)
        try Data("broken-json".utf8).write(to: receipt)
        try check(store.lookup(plan: first) == nil, "Incomplete/corrupt receipt is a cache miss")
        _ = try store.save(text: text, plan: first)
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as! [String: Any]
        object["complete"] = false
        try JSONSerialization.data(withJSONObject: object).write(to: receipt)
        try check(store.lookup(plan: first) == nil, "Only validated complete exports can be adopted")
        _ = try store.save(text: text, plan: first)
        try files.removeItem(at: cached)
        try check(store.lookup(plan: first) == nil, "Receipt without payload cannot be adopted")
        _ = try store.save(text: text, plan: first)
        let external = root.appendingPathComponent("external-user-file")
        try Data("preserve".utf8).write(to: external)
        try files.removeItem(at: cached)
        try files.createSymbolicLink(at: cached, withDestinationURL: external)
        failure("Payload symlink is rejected") { _ = try store.lookup(plan: first) }
        failure("Payload symlink cannot be overwritten") { _ = try store.save(text: text, plan: first) }
        try check(String(contentsOf: external, encoding: .utf8) == "preserve", "Symlink target is untouched")
        try files.removeItem(at: cached)
        _ = try store.save(text: text, plan: first)
        try files.removeItem(at: cached)
        try files.linkItem(at: external, to: cached)
        failure("Hard-linked payload cannot be read as an owned cache") { _ = try store.lookup(plan: first) }
        failure("Hard-linked payload cannot be overwritten") { _ = try store.save(text: text, plan: first) }
        try check(String(contentsOf: external, encoding: .utf8) == "preserve", "Hard-link target is untouched")
        try files.removeItem(at: cached)
        _ = try store.save(text: text, plan: first)
        try files.removeItem(at: receipt)
        try files.createSymbolicLink(at: receipt, withDestinationURL: external)
        failure("Receipt symlink cannot be read") { _ = try store.lookup(plan: first) }
        failure("Receipt symlink cannot be overwritten") { _ = try store.save(text: text, plan: first) }
        try files.removeItem(at: receipt)
        _ = try store.save(text: text, plan: first)
        let oversized = Darwin.open(cached.path, O_WRONLY)
        check(oversized >= 0 && ftruncate(oversized, off_t(SPTorrentSubtitleStore.maximumTextBytes + 1)) == 0,
              "Owned sparse oversized cache fixture is created")
        Darwin.close(oversized)
        try check(store.lookup(plan: first) == nil, "Oversized on-disk text is rejected before allocation")
        _ = try store.save(text: text, plan: first)
        let target = root.appendingPathComponent("symlink-target", isDirectory: true)
        try files.createDirectory(at: target, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try files.createSymbolicLink(at: alias, withDestinationURL: target)
        let unsafe = SPTorrentSubtitleStore(directory: alias.appendingPathComponent("captions"))
        failure("Directory symlink cannot redirect writes") { _ = try unsafe.save(text: text, plan: first) }
        try check(files.contentsOfDirectory(atPath: target.path).isEmpty, "Directory symlink target is untouched")
        failure("Oversized text is rejected") {
            _ = try store.save(text: String(repeating: "x", count: SPTorrentSubtitleStore.maximumTextBytes + 1), plan: first)
        }
        failure("Embedded NUL cannot hide a truncated subtitle") { _ = try store.save(text: "a\0b", plan: first) }
        failure("Excessive lines are bounded") { _ = try store.save(text: String(repeating: "\n", count: 1_000_001), plan: first) }
        let cancellation = SPTorrentSubtitleCancellation(); cancellation.cancel()
        failure("Cancelled complete export cannot publish files") {
            _ = try store.save(text: text, plan: plan(track: 99), cancellation: cancellation)
        }
        try check(store.lookup(plan: plan(track: 99)) == nil, "Cancelled export leaves no cache hit")

        let asyncStore = SPTorrentSubtitleStore(directory: root.appendingPathComponent("async"))
        let nativeState = LockedState()
        let controller = SPTorrentSubtitleCache(store: asyncStore, extractor: Extractor(state: nativeState, result: text))
        var adopted: [(URL, Int)] = []
        let adopt: @MainActor (URL, Int) async -> Bool = { url, index in adopted.append((url, index)); return true }
        controller.start(plan: first, shouldPause: { false }, isCurrent: { true }, adopt: adopt)
        check(controller.isPreparing, "Preparing state publishes before background work")
        for _ in 0..<10 { controller.start(plan: first, shouldPause: { false }, isCurrent: { true }, adopt: adopt) }
        await until { controller.snapshot.state == .ready }
        check(nativeState.calls == 1 && adopted.count == 1 && adopted[0].1 == 2,
              "Repeated same-plan callbacks extract and adopt exactly once")
        check(!controller.isPreparing, "Ready captions release the background preparation slot")
        let rotated = plan(port: 54321)
        controller.start(plan: rotated, shouldPause: { false }, isCurrent: { true }, adopt: adopt)
        await until { controller.snapshot.state == .ready }
        check(nativeState.calls == 1 && adopted.count == 2, "New playback session re-adopts disk cache without network extraction")
        let hitState = LockedState()
        let pausedHit = SPTorrentSubtitleCache(store: asyncStore,
            extractor: Extractor(state: hitState, result: text))
        pausedHit.start(plan: plan(), shouldPause: { true }, isCurrent: { true }, adopt: adopt)
        await until { pausedHit.snapshot.state == .ready }
        check(hitState.calls == 0, "An existing disk cache is usable before any network producer grant")

        let firstFlightState = LockedState(), queuedState = LockedState(), queuedGrant = LockedState()
        let firstFlight = SPTorrentSubtitleCache(store: asyncStore,
            extractor: Extractor(state: firstFlightState, result: text, hold: true))
        let queued = SPTorrentSubtitleCache(store: asyncStore,
            extractor: Extractor(state: queuedState, result: text))
        firstFlight.onChange = { value in if value.state == .ready { queuedGrant.release() } }
        let firstFlightPlan = plan(track: 40), queuedPlan = plan(track: 40, port: 54321)
        firstFlight.start(plan: firstFlightPlan, shouldPause: { false }, isCurrent: { true }, adopt: adopt)
        await until { firstFlightState.calls == 1 }
        queued.start(plan: queuedPlan, shouldPause: { !queuedGrant.released }, isCurrent: { true }, adopt: adopt)
        try? await Task.sleep(for: .milliseconds(100))
        check(queuedState.calls == 0 && queued.isPreparing,
              "A queued cache miss waits before opening its native reader")
        firstFlightState.release()
        await until { firstFlight.snapshot.state == .ready && queued.snapshot.state == .ready }
        check(firstFlightState.calls == 1 && queuedState.calls == 0,
              "A newly granted second window rechecks disk and does not extract the same whole track again")
        let waitingState = LockedState()
        let waiting = SPTorrentSubtitleCache(store: asyncStore,
            extractor: Extractor(state: waitingState, result: text))
        let waitingPlan = plan(track: 41)
        waiting.start(plan: waitingPlan, shouldPause: { true }, isCurrent: { true }, adopt: adopt)
        try? await Task.sleep(for: .milliseconds(70))
        waiting.cancel()
        try? await Task.sleep(for: .milliseconds(70))
        check(waitingState.calls == 0 && waiting.snapshot.state == .idle,
              "Cancelling during grant wait never starts a native reader")
        try check(asyncStore.lookup(plan: waitingPlan) == nil, "Grant-wait cancellation creates no incomplete cache")
        let staleState = LockedState()
        let stale = SPTorrentSubtitleCache(store: asyncStore,
            extractor: Extractor(state: staleState, result: text, hold: true))
        let uncached = plan(track: 20)
        var staleAdopted = false
        stale.start(plan: uncached, shouldPause: { false }, isCurrent: { true }) { _, _ in staleAdopted = true; return true }
        await until { staleState.calls == 1 }
        stale.cancel()
        await until { staleState.cancelled }
        staleState.release()
        try? await Task.sleep(for: .milliseconds(30))
        check(!staleAdopted && stale.snapshot.state == .idle, "Cancellation aborts the reader and never adopts old results")
        try check(asyncStore.lookup(plan: uncached) == nil, "Cancelled partial extraction is never persisted")
        let switchedState = LockedState()
        let switched = SPTorrentSubtitleCache(store: asyncStore,
            extractor: Extractor(state: switchedState, result: text, hold: true))
        let oldPlan = plan(track: 21), newPlan = plan(track: 22)
        var indices: [Int] = []
        switched.start(plan: oldPlan, shouldPause: { false }, isCurrent: { true }) { _, index in indices.append(index); return true }
        await until { switchedState.calls == 1 }
        switched.start(plan: newPlan, shouldPause: { false }, isCurrent: { true }) { _, index in indices.append(index); return true }
        switchedState.release()
        await until { switched.snapshot.state == .ready }
        check(indices == [22], "Track replacement cannot commit the previous track")
        let noCurrent = SPTorrentSubtitleCache(store: asyncStore,
            extractor: Extractor(state: LockedState(), result: text))
        var forbidden = false
        noCurrent.start(plan: plan(track: 23), shouldPause: { false }, isCurrent: { false }) { _, _ in forbidden = true; return true }
        await until { noCurrent.snapshot.state == .idle }
        check(!forbidden && !noCurrent.isPreparing,
              "A stale source never adopts and releases the preparation slot")
        noCurrent.cancel()
        let pendingAdoption = SPTorrentSubtitleCache(store: asyncStore,
            extractor: Extractor(state: LockedState(), result: text))
        let adoption = AdoptionState()
        pendingAdoption.start(plan: plan(track: 30), shouldPause: { false }, isCurrent: { adoption.current }) { _, _ in
            await withCheckedContinuation { adoption.continuation = $0 }
        }
        await until { adoption.continuation != nil }
        adoption.current = false
        adoption.continuation?.resume(returning: true)
        await until { pendingAdoption.snapshot.state == .idle }
        check(!pendingAdoption.isPreparing, "Source change during native adoption cannot publish Ready")
        let reentrantState = LockedState()
        let reentrant = SPTorrentSubtitleCache(store: asyncStore,
            extractor: Extractor(state: reentrantState, result: text))
        reentrant.onChange = { [weak reentrant] value in if value.state == .loading { reentrant?.cancel() } }
        reentrant.start(plan: plan(track: 31), shouldPause: { false }, isCurrent: { true }, adopt: adopt)
        try? await Task.sleep(for: .milliseconds(20))
        check(reentrant.snapshot.state == .idle && reentrantState.calls == 0,
              "Reentrant cancellation from Loading prevents even starting the reader")
        let rejected = SPTorrentSubtitleCache(store: asyncStore,
            extractor: Extractor(state: LockedState(), result: text))
        rejected.start(plan: plan(track: 24), shouldPause: { false }, isCurrent: { true }) { _, _ in false }
        await until { rejected.snapshot.state == .failed }
        check(rejected.snapshot.cacheURL != nil, "Rejected native adoption leaves a valid cache for a later session")
        let failedState = LockedState()
        let failed = SPTorrentSubtitleCache(store: asyncStore,
            extractor: Extractor(state: failedState, result: text, failure: true))
        // Use the same concrete plan to prove polling does not repeat failures.
        let stableFailure = plan(track: 26)
        failed.start(plan: stableFailure, shouldPause: { false }, isCurrent: { true }, adopt: adopt)
        await until { failed.snapshot.state == .failed }
        let failedCalls = failedState.calls
        for _ in 0..<20 { failed.start(plan: stableFailure, shouldPause: { false }, isCurrent: { true }, adopt: adopt) }
        try? await Task.sleep(for: .milliseconds(20))
        check(failedState.calls == failedCalls, "A failed extraction is sticky until context changes, avoiding unbounded scans")
        failed.cancel()
        var invalid = first
        invalid = .init(identity: .init(hash: "bad", fileID: 5, length: 12345, trackID: 2),
                        sessionID: UUID(), backgroundURL: first.backgroundURL,
                        expectedMediaURL: first.expectedMediaURL, timelineOriginUs: 0)
        let invalidState = LockedState()
        let invalidController = SPTorrentSubtitleCache(store: asyncStore,
            extractor: Extractor(state: invalidState, result: text))
        invalidController.start(plan: invalid, shouldPause: { false }, isCurrent: { true }, adopt: adopt)
        check(invalidController.snapshot.failure == .invalidPlan && invalidState.calls == 0,
              "Invalid file identities fail before background work")
        invalidController.start(plan: plan(track: Int.max), shouldPause: { false }, isCurrent: { true }, adopt: adopt)
        check(invalidController.snapshot.failure == .invalidPlan && invalidState.calls == 0,
              "Track indices cannot overflow the native Int32 bridge")
        let mismatch = SPTorrentSubtitleCache.Plan(identity: first.identity, sessionID: UUID(),
            backgroundURL: URL(string: "http://worker:fake-secret@127.0.0.1:12345/stream/owned.mp4?link=\(hash)&index=6")!,
            expectedMediaURL: first.expectedMediaURL, timelineOriginUs: 0)
        invalidController.start(plan: mismatch, shouldPause: { false }, isCurrent: { true }, adopt: adopt)
        check(invalidController.snapshot.failure == .invalidPlan, "Worker URL must identify the same selected file")
        let externalURL = SPTorrentSubtitleCache.Plan(identity: first.identity, sessionID: UUID(),
            backgroundURL: URL(string: "http://example.invalid/stream/owned.mp4?link=\(hash)&index=5")!,
            expectedMediaURL: first.expectedMediaURL, timelineOriginUs: 0)
        invalidController.start(plan: externalURL, shouldPause: { false }, isCurrent: { true }, adopt: adopt)
        check(invalidController.snapshot.failure == .invalidPlan, "Only loopback worker reads are admitted")
        let primaryConsumer = URLComponents(url: first.expectedMediaURL, resolvingAgainstBaseURL: false)!
            .queryItems!.first(where: { $0.name == "playback_consumer" })!.value!
        let invalidRoles: [(String, SPTorrentSubtitleCache.Plan)] = [
            ("Missing background role is rejected", changed(first, background: { $0.removeAll { $0.name == "playback_background" } })),
            ("Wrong background role is rejected", changed(first, background: {
                $0.removeAll { $0.name == "playback_background" }; $0.append(.init(name: "playback_background", value: "0"))
            })),
            ("Missing parent is rejected", changed(first, background: { $0.removeAll { $0.name == "playback_parent" } })),
            ("A different primary parent is rejected", changed(first, background: {
                $0.removeAll { $0.name == "playback_parent" }; $0.append(.init(name: "playback_parent", value: UUID().uuidString))
            })),
            ("Primary and background consumers must differ", changed(first, background: {
                $0.removeAll { $0.name == "playback_consumer" }; $0.append(.init(name: "playback_consumer", value: primaryConsumer))
            })),
            ("Missing background consumer is rejected", changed(first, background: { $0.removeAll { $0.name == "playback_consumer" } })),
            ("Invalid background UUID is rejected", changed(first, background: {
                $0.removeAll { $0.name == "playback_consumer" }; $0.append(.init(name: "playback_consumer", value: "not-a-uuid"))
            })),
            ("A role on the primary URL is rejected", changed(first, expected: { $0.append(.init(name: "playback_background", value: "1")) })),
            ("A parent on the primary URL is rejected", changed(first, expected: { $0.append(.init(name: "playback_parent", value: nil)) })),
            ("A duplicated primary consumer is rejected", changed(first, expected: { $0.append(.init(name: "playback_consumer", value: nil)) }))
        ]
        for (message, invalidRole) in invalidRoles {
            invalidController.start(plan: invalidRole, shouldPause: { false }, isCurrent: { true }, adopt: adopt)
            check(invalidController.snapshot.failure == .invalidPlan && invalidState.calls == 0, message)
        }
        for field in ["link", "index", "playback_background", "playback_parent", "playback_consumer"] {
            let duplicate = changed(first, background: { $0.append(.init(name: field, value: nil)) })
            invalidController.start(plan: duplicate, shouldPause: { false }, isCurrent: { true }, adopt: adopt)
            check(invalidController.snapshot.failure == .invalidPlan && invalidState.calls == 0,
                  "Duplicate \(field), including a missing-value duplicate, is rejected")
            let missingValue = changed(first, background: {
                $0.removeAll { $0.name == field }; $0.append(.init(name: field, value: nil))
            })
            invalidController.start(plan: missingValue, shouldPause: { false }, isCurrent: { true }, adopt: adopt)
            check(invalidController.snapshot.failure == .invalidPlan && invalidState.calls == 0,
                  "Missing-value \(field) is rejected")
        }
        let native = SPTorrentSubtitleCache(store: asyncStore)
        let nativePlan = plan(track: 27, origin: -250_000)
        native.start(plan: nativePlan, shouldPause: { false }, isCurrent: { true }, adopt: adopt)
        await until { native.snapshot.state == .ready }
        let observed = NativeProbe.shared.last!
        check(observed.1 == 27 && observed.2 == -250_000 && observed.3 == 12345,
              "Native adapter supplies exact track, signed origin and source length")
        check(observed.0 == nativePlan.backgroundURL.absoluteString, "Native adapter uses the independent background producer URL")
        let paused = LockedState()
        let pausedNative = SPTorrentSubtitleCache(store: asyncStore)
        pausedNative.start(plan: plan(track: 28), shouldPause: { !paused.released }, isCurrent: { true }, adopt: adopt)
        try? await Task.sleep(for: .milliseconds(100))
        check(pausedNative.isPreparing && NativeProbe.shared.count == 1,
              "Background preparation waits before native open while playback has priority")
        paused.release()
        await until { pausedNative.snapshot.state == .ready }
        controller.cancel(); switched.cancel(); native.cancel(); pausedNative.cancel()
        pausedHit.cancel(); firstFlight.cancel(); queued.cancel()
        let leftovers = try files.subpathsOfDirectory(atPath: directory.path).filter { $0.contains("subtitle-tmp") }
        check(leftovers.isEmpty, "Atomic writes leave no staging files")
        print("Torrent subtitle cache checks passed (\(checks) assertions).")
    }

}

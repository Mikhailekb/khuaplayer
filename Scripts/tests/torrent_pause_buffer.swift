import Foundation
import Darwin

// Standalone manager checks compile without TorrentServer.swift.
struct SPTorrentPrefetchCapacityStop: Equatable, Sendable {
    let requestID: UUID
    let fileID: Int
    let rangeStart: Int64
    let rangeEnd: Int64
    let nextOffset: Int64
    let revision: Int64
}

@main @MainActor
struct TorrentPauseBufferChecks {
    static var checks = 0
    static var port = 0
    static var eventFile = URL(fileURLWithPath: "/dev/null")
    static let fileLength: Int64 = 8 * 1_024 * 1_024 * 1_024
    static let identity = SPTorrentPauseBuffer.Identity(hash: String(repeating: "a", count: 40),
                                                      fileID: 7, sessionGeneration: UUID())

    static func main() async {
        guard CommandLine.arguments.count == 3, let fixturePort = Int(CommandLine.arguments[1]) else {
            fatalError("Pass loopback fixture port and event file")
        }
        port = fixturePort
        eventFile = URL(fileURLWithPath: CommandLine.arguments[2])
        do {
            try await automaticRecoveryChecks()
            try await capacityProofChecks()
            try await exactWindowChecks()
            try await slidingWindowChecks()
            try await rollingCapacityChecks()
            try await quotaShrinkChecks()
            try await stopResumeChecks()
            try await generationChecks()
            try await protocolChecks()
            try await largeBodyChecks()
            print("Torrent pause buffer checks passed (\(checks) checks).")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    static func automaticRecoveryChecks() async throws {
        let manager = SPTorrentPauseBuffer()
        let prefixGate = eventFile.deletingLastPathComponent().appendingPathComponent("hold-recovery-prefix")
        try Data().write(to: prefixGate)
        var sourceParts = URLComponents(url: url("recover-short", "recover-partial"), resolvingAgainstBaseURL: false)!
        sourceParts.queryItems!.append(URLQueryItem(name: "close_gate", value: prefixGate.lastPathComponent))
        let source = sourceParts.url!
        manager.onChange = { snapshot in
            if snapshot.receivedBytes > 0 { try? FileManager.default.removeItem(at: prefixGate) }
        }
        manager.start(identity: identity, streamURL: source, offset: 1000,
                      fileLength: fileLength, forwardEndOffset: 201_000)
        try await awaitTransientFailure(manager)
        let acceptedPrefix = manager.snapshot.receivedBytes
        manager.onChange = nil
        check(acceptedPrefix > 0 && acceptedPrefix <= 100_000 && manager.snapshot.state == .filling,
              "a transient partial response keeps buffering enabled instead of requiring manual Resume")
        try await awaitState(manager, .filled)
        let recovered = requests("recover-partial")
        check(recovered.count == 2 && recovered[1]["range"] as? String == "bytes=\(1000 + acceptedPrefix)-200999" &&
              requestID(recovered[0]) != requestID(recovered[1]),
              "a real truncated response automatically resumes exactly its validated suffix with a fresh nonce")

        let preheaders = SPTorrentPauseBuffer(retryDelays: [.milliseconds(150)])
        let gate = eventFile.deletingLastPathComponent().appendingPathComponent("hold-preheaders-recover-preheaders")
        try Data().write(to: gate)
        preheaders.start(identity: identity, streamURL: url("preheaders", "recover-preheaders"), offset: 1234,
                         fileLength: fileLength, forwardEndOffset: 101_234)
        try await awaitTransientFailure(preheaders)
        check(preheaders.snapshot.failure == .transport && preheaders.snapshot.receivedBytes == 0,
              "a transport close before response headers retains zero accepted bytes and remains recoverable")
        let oldNonce = requestID(requests("recover-preheaders")[0])
        try FileManager.default.removeItem(at: gate)
        try await awaitState(preheaders, .filled)
        let beforeHeadersReads = requests("recover-preheaders")
        check(beforeHeadersReads.last?["range"] as? String == "bytes=1234-101233" &&
              requestID(beforeHeadersReads.last!) != oldNonce,
              "pre-header recovery retries the original finite range without claiming unvalidated coverage")

        let backoff = SPTorrentPauseBuffer(retryDelays: [.milliseconds(100), .milliseconds(200), .milliseconds(400)])
        let backoffSource = url("short", "retry-backoff")
        backoff.start(identity: identity, streamURL: backoffSource, offset: 0,
                      fileLength: fileLength, forwardEndOffset: 8 * 1_024 * 1_024)
        try await awaitTransientFailure(backoff)
        let pollDeadline = ProcessInfo.processInfo.systemUptime + 2
        var pollCount: Int64 = 0
        while requests("retry-backoff").count < 5 && ProcessInfo.processInfo.systemUptime < pollDeadline {
            pollCount += 1
            backoff.start(identity: identity, streamURL: backoffSource, offset: pollCount,
                          fileLength: fileLength, forwardEndOffset: 8 * 1_024 * 1_024 + pollCount)
            try await Task.sleep(for: .milliseconds(10))
        }
        let attempts = requests("retry-backoff")
        check(attempts.count == 5, "frequent advancing ACKs neither bypass nor indefinitely postpone automatic recovery")
        let times = attempts.compactMap { $0["monotonic"] as? Double }
        check(times.count == 5 && times[1] - times[0] >= 0.08 && times[2] - times[1] >= 0.18 &&
              times[3] - times[2] >= 0.38 && times[4] - times[3] >= 0.38,
              "repeated transient failures use increasing retry delays and a capped request frequency")
        backoff.stop()
        let stoppedCount = requests("retry-backoff").count
        try await Task.sleep(for: .milliseconds(500))
        check(backoff.snapshot.state == .stopped && requests("retry-backoff").count == stoppedCount,
              "manual Stop cancels a pending automatic recovery and all late callbacks")

        let advanced = SPTorrentPauseBuffer(retryDelays: [.milliseconds(100)])
        let advancedSource = url("recover-short", "retry-advanced")
        advanced.start(identity: identity, streamURL: advancedSource, offset: 0,
                       fileLength: fileLength, forwardEndOffset: 200_000)
        try await awaitTransientFailure(advanced)
        advanced.start(identity: identity, streamURL: advancedSource, offset: 150_000,
                       fileLength: fileLength, forwardEndOffset: 300_000)
        check(advanced.snapshot.rangeStart == 150_000 && advanced.snapshot.receivedBytes == 0,
              "a newer approved start beyond the delivered frontier does not borrow an unvalidated byte gap")
        try await awaitState(advanced, .filled)
        check(requests("retry-advanced").last?["range"] as? String == "bytes=150000-299999",
              "the existing retry deadline uses the latest exact worker-approved start and upper bound")

        let stopped = SPTorrentPauseBuffer(retryDelays: [.milliseconds(100)])
        stopped.onChange = { snapshot in
            if snapshot.failure == .transport || snapshot.failure == .shortRead { stopped.stop() }
        }
        stopped.start(identity: identity, streamURL: url("short", "retry-reentrant-stop"), offset: 0,
                      fileLength: fileLength, forwardEndOffset: 100_000)
        try await awaitState(stopped, .stopped)
        try await Task.sleep(for: .milliseconds(200))
        check(requests("retry-reentrant-stop").count == 1,
              "synchronous Stop from the recovery notification prevents its scheduled retry")
        stopped.onChange = nil

        let replaced = SPTorrentPauseBuffer(retryDelays: [.milliseconds(100)])
        replaced.start(identity: identity, streamURL: url("short", "retry-replaced-old"), offset: 0,
                       fileLength: fileLength, forwardEndOffset: 100_000)
        try await awaitTransientFailure(replaced)
        replaced.cancel()
        replaced.start(identity: identity, streamURL: url("valid", "retry-replaced-new"), offset: 1000,
                       fileLength: fileLength, forwardEndOffset: 101_000)
        try await awaitState(replaced, .filled)
        try await Task.sleep(for: .milliseconds(200))
        check(requests("retry-replaced-old").count == 1 && requests("retry-replaced-new").count == 1,
              "source replacement invalidates the old recovery timer before it can mutate or restart the new source")

        var disposable: SPTorrentPauseBuffer? = SPTorrentPauseBuffer(retryDelays: [.milliseconds(100)])
        weak var weakDisposable = disposable
        disposable!.start(identity: identity, streamURL: url("short", "retry-deinit"), offset: 0,
                          fileLength: fileLength, forwardEndOffset: 100_000)
        try await awaitTransientFailure(disposable!)
        disposable = nil
        check(weakDisposable == nil, "a sleeping retry task does not retain its manager")
        try await Task.sleep(for: .milliseconds(200))
        check(requests("retry-deinit").count == 1, "deinitialization cancels the pending recovery request")

        let terminal = SPTorrentPauseBuffer(retryDelays: [.milliseconds(30)])
        for endpoint in ["wrong-start", "auth", "redirect-other"] {
            let tag = "retry-terminal-" + endpoint
            terminal.start(identity: identity, streamURL: url(endpoint, tag), offset: 0,
                           fileLength: fileLength, forwardEndOffset: 100_000)
            try await awaitState(terminal, .failed)
            try await Task.sleep(for: .milliseconds(120))
            check(requests(tag).count == 1,
                  "\(endpoint) remains terminal and never enters automatic transient recovery")
        }
    }

    static func capacityProofChecks() async throws {
        let manager = SPTorrentPauseBuffer()
        let tag = "capacity-proof"
        let source = capacitySource(tag)
        var upper: Int64 = 1_024 * 1_024
        _ = try await capacityState(tag, upper: upper)
        manager.start(identity: identity, streamURL: source, offset: 0,
                      fileLength: fileLength, forwardEndOffset: 2 * upper)
        try await awaitTransientFailure(manager)
        var proof = capacityProof(try await capacityState(tag))!
        let failed = manager.snapshot
        for invalid in [SPTorrentPrefetchCapacityStop(requestID: UUID(), fileID: proof.fileID,
                            rangeStart: proof.rangeStart, rangeEnd: proof.rangeEnd, nextOffset: proof.nextOffset, revision: proof.revision),
                        SPTorrentPrefetchCapacityStop(requestID: proof.requestID, fileID: proof.fileID + 1,
                            rangeStart: proof.rangeStart, rangeEnd: proof.rangeEnd, nextOffset: proof.nextOffset, revision: proof.revision),
                        SPTorrentPrefetchCapacityStop(requestID: proof.requestID, fileID: proof.fileID,
                            rangeStart: proof.rangeStart, rangeEnd: proof.rangeEnd, nextOffset: proof.nextOffset + 1, revision: proof.revision),
                        SPTorrentPrefetchCapacityStop(requestID: proof.requestID, fileID: proof.fileID,
                            rangeStart: proof.rangeStart, rangeEnd: proof.rangeEnd + 1, nextOffset: proof.nextOffset, revision: proof.revision)] {
            manager.start(identity: identity, streamURL: source, offset: 0,
                          fileLength: fileLength, forwardEndOffset: 2 * upper, capacityStop: invalid)
        }
        check(manager.snapshot == failed && requests(tag).count == 1,
              "wrong request, file, range or delivered frontier cannot turn a real transport error into capacity wait")
        manager.start(identity: identity, streamURL: source, offset: 0,
                      fileLength: fileLength, forwardEndOffset: upper, capacityStop: proof)
        check(manager.snapshot.state == .waitingForCapacity && manager.snapshot.failure == nil &&
              manager.snapshot.receivedBytes == upper && requests(tag).count == 1,
              "an exact worker capacity proof parks a validated premature response without another HTTP request")
        for cycle in 1...3 {
            for _ in 0..<20 {
                manager.start(identity: identity, streamURL: source, offset: 0,
                              fileLength: fileLength, forwardEndOffset: upper, capacityStop: proof)
            }
            try await Task.sleep(for: .milliseconds(120))
            check(manager.snapshot.state == .waitingForCapacity && requests(tag).count == 2 * cycle - 1,
                  "capacity cycle \(cycle) waits without polling HTTP or replaying an old proof")
            let previousUpper = upper
            upper += 512 * 1_024
            _ = try await capacityState(tag, upper: upper)
            manager.start(identity: identity, streamURL: source, offset: 0,
                          fileLength: fileLength, forwardEndOffset: upper, capacityStop: proof)
            try await awaitState(manager, .filled)
            check(requests(tag).count == 2 * cycle && requests(tag).last?["range"] as? String ==
                  "bytes=\(previousUpper)-\(upper - 1)",
                  "capacity cycle \(cycle) automatically fills exactly the released suffix")
            let full = manager.snapshot
            for _ in 0..<10 {
                manager.start(identity: identity, streamURL: source, offset: 0,
                              fileLength: fileLength, forwardEndOffset: upper, capacityStop: proof)
            }
            check(manager.snapshot == full && requests(tag).count == 2 * cycle,
                  "capacity cycle \(cycle) remains full without a refill loop")
            let staleUpper = upper + 512 * 1_024
            upper += 256 * 1_024
            _ = try await capacityState(tag, upper: upper)
            manager.start(identity: identity, streamURL: source, offset: 0,
                          fileLength: fileLength, forwardEndOffset: staleUpper, capacityStop: proof)
            try await awaitTransientFailure(manager)
            let nextProof = capacityProof(try await capacityState(tag))!
            check(nextProof.requestID != proof.requestID && manager.snapshot.receivedBytes == upper,
                  "capacity cycle \(cycle) requires fresh proof for its new finite request")
            proof = nextProof
            manager.start(identity: identity, streamURL: source, offset: 0,
                          fileLength: fileLength, forwardEndOffset: upper, capacityStop: proof)
        }
        check(manager.snapshot.state == .waitingForCapacity && requests(tag).count == 7,
              "three complete cache wait, release, fill and exhaust cycles stay bounded")
        let newUpper = upper + 512 * 1_024
        _ = try await capacityState(tag, upper: newUpper)
        // A capacity ACK can restore credit before the application ever saw the
        // numeric shrink. Stop from its synchronous notification must still win.
        manager.onChange = { snapshot in
            if snapshot.state == .waitingForCapacity { manager.stop() }
        }
        manager.stop()
        let stopped = manager.snapshot
        try await Task.sleep(for: .milliseconds(100))
        check(stopped.state == .stopped && manager.snapshot == stopped && requests(tag).count == 7,
              "manual Stop leaves capacity waiting dormant without a timer or delayed HTTP restart")
        manager.onChange = nil
        manager.start(identity: identity, streamURL: source, offset: 0,
                      fileLength: fileLength, forwardEndOffset: newUpper, capacityStop: proof)
        try await awaitState(manager, .filled)
        check(requests(tag).count == 8 && requests(tag).last?["range"] as? String == "bytes=\(upper)-\(newUpper - 1)",
              "explicit Resume after capacity Stop reads only the remaining finite suffix")

        let earlyTag = "capacity-proof-before-terminal"
        let earlySource = capacitySource(earlyTag, delayClose: true)
        let earlyUpper: Int64 = 512 * 1_024
        _ = try await capacityState(earlyTag, upper: earlyUpper)
        manager.start(identity: identity, streamURL: earlySource, offset: 0,
                      fileLength: fileLength, forwardEndOffset: 2 * earlyUpper)
        var earlyProof: SPTorrentPrefetchCapacityStop?
        for _ in 0..<100 where earlyProof == nil {
            earlyProof = capacityProof(try await capacityState(earlyTag))
            if earlyProof == nil { try await Task.sleep(for: .milliseconds(5)) }
        }
        check(earlyProof != nil && manager.snapshot.state == .filling,
              "the fixture publishes worker proof before URLSession reports the premature terminal error")
        let earlyExpanded = 2 * earlyUpper + 128 * 1_024
        _ = try await capacityState(earlyTag, upper: earlyExpanded)
        manager.start(identity: identity, streamURL: earlySource, offset: 0,
                      fileLength: fileLength, forwardEndOffset: earlyExpanded, capacityStop: earlyProof)
        try await awaitState(manager, .filled)
        check(requests(earlyTag).count == 2 && requests(earlyTag).last?["range"] as? String ==
              "bytes=\(earlyUpper)-\(earlyExpanded - 1)",
              "proof arriving before the terminal callback authorizes one suffix after validation completes")

        let lateTag = "capacity-late-advanced-stop"
        let lateSource = capacitySource(lateTag)
        _ = try await capacityState(lateTag, upper: earlyUpper)
        manager.start(identity: identity, streamURL: lateSource, offset: 0,
                      fileLength: fileLength, forwardEndOffset: 2 * earlyUpper)
        try await awaitTransientFailure(manager)
        let lateProof = capacityProof(try await capacityState(lateTag))!
        let advanced = earlyUpper + 64 * 1_024
        _ = try await capacityState(lateTag, upper: earlyExpanded)
        manager.onChange = { snapshot in
            if snapshot.state == .waitingForCapacity { manager.stop() }
        }
        manager.start(identity: identity, streamURL: lateSource, offset: advanced,
                      fileLength: fileLength, forwardEndOffset: earlyExpanded, capacityStop: lateProof)
        try await Task.sleep(for: .milliseconds(100))
        check(manager.snapshot.state == .stopped && manager.snapshot.rangeStart == advanced &&
              manager.snapshot.receivedBytes == 0 && requests(lateTag).count == 1,
              "late proof accepts an advanced exact Core frontier, and synchronous Stop prevents its credited suffix")
        manager.onChange = nil
        manager.start(identity: identity, streamURL: lateSource, offset: advanced,
                      fileLength: fileLength, forwardEndOffset: earlyExpanded, capacityStop: lateProof)
        try await awaitState(manager, .filled)
        check(requests(lateTag).count == 2 && requests(lateTag).last?["range"] as? String ==
              "bytes=\(advanced)-\(earlyExpanded - 1)",
              "explicit Resume after late-proof Stop begins at the current exact frontier without borrowing a gap")

        let rewindTag = "capacity-proof-metadata-rewind"
        let rewindSource = capacitySource(rewindTag)
        _ = try await capacityState(rewindTag, upper: 2000)
        manager.start(identity: identity, streamURL: rewindSource, offset: 1000,
                      fileLength: fileLength, forwardEndOffset: 3000)
        try await awaitTransientFailure(manager)
        let rewindFailure = manager.snapshot
        let rewindProof = capacityProof(try await capacityState(rewindTag))!
        manager.start(identity: identity, streamURL: rewindSource, offset: 0,
                      fileLength: fileLength, forwardEndOffset: 2000, capacityStop: rewindProof)
        check(manager.snapshot == rewindFailure && manager.snapshot.rangeStart == 1000 &&
              manager.snapshot.receivedBytes == 1000 && requests(rewindTag).count == 1,
              "a metadata read-offset rewind cannot use late proof to claim an earlier unvalidated byte gap")
        manager.start(identity: identity, streamURL: rewindSource, offset: 1000,
                      fileLength: fileLength, forwardEndOffset: 2000, capacityStop: rewindProof)
        check(manager.snapshot.state == .waitingForCapacity && manager.snapshot.receivedBytes == 1000,
              "a rejected backward frontier does not consume proof for the original validated window")

        let delayedTag = "capacity-proof-after-paused-refresh"
        let delayedSource = capacitySource(delayedTag)
        let delayedUpper: Int64 = 64 * 1_024
        _ = try await capacityState(delayedTag, upper: delayedUpper)
        manager.start(identity: identity, streamURL: delayedSource, offset: 0,
                      fileLength: fileLength, forwardEndOffset: 2 * delayedUpper)
        try await awaitTransientFailure(manager)
        let delayedProof = capacityProof(try await capacityState(delayedTag))!
        try await Task.sleep(for: .milliseconds(2100))
        check(requests(delayedTag).count == 1 && manager.snapshot.state == .filling,
              "the default recovery grace leaves time for the paused two-second capacity ACK refresh")
        manager.start(identity: identity, streamURL: delayedSource, offset: 0,
                      fileLength: fileLength, forwardEndOffset: delayedUpper, capacityStop: delayedProof)
        try await Task.sleep(for: .milliseconds(1100))
        check(requests(delayedTag).count == 1 && manager.snapshot.state == .waitingForCapacity,
              "an exact late capacity proof cancels generic recovery before it replaces the finite request nonce")

        let zero = SPTorrentPauseBuffer(retryDelays: [.milliseconds(100), .milliseconds(200)])
        let zeroTag = "capacity-zero-body-recovery"
        let zeroSource = capacitySource(zeroTag)
        _ = try await capacityState(zeroTag, upper: delayedUpper)
        zero.start(identity: identity, streamURL: zeroSource, offset: delayedUpper,
                   fileLength: fileLength, forwardEndOffset: 2 * delayedUpper)
        try await wait {
            Set(requests(zeroTag).compactMap { requestID($0) }).count >= 3 && zero.snapshot.failure != nil
        }
        let zeroAttempts = requests(zeroTag)
        check(Set(zeroAttempts.compactMap { requestID($0) }).count == 3 && zero.snapshot.receivedBytes == 0,
              "repeated zero-body quota closes have bounded recovery frequency and never invent progress")
        let zeroProof = capacityProof(try await capacityState(zeroTag))!
        zero.start(identity: identity, streamURL: zeroSource, offset: delayedUpper,
                   fileLength: fileLength, forwardEndOffset: delayedUpper, capacityStop: zeroProof)
        try await Task.sleep(for: .milliseconds(300))
        check(zero.snapshot.state == .waitingForCapacity && requests(zeroTag).count == zeroAttempts.count,
              "zero-credit capacity proof parks recovery without a retry loop")

        let invalidTag = "capacity-invalid-headers"
        let invalidSource = url("wrong-start", invalidTag)
        manager.start(identity: identity, streamURL: invalidSource, offset: 1000,
                      fileLength: fileLength, forwardEndOffset: 2000)
        try await awaitState(manager, .failed)
        let invalid = manager.snapshot
        let forged = SPTorrentPrefetchCapacityStop(requestID: UUID(uuidString: requestID(requests(invalidTag)[0])!)!,
            fileID: identity.fileID, rangeStart: 1000, rangeEnd: 2000, nextOffset: 1000, revision: 1)
        manager.start(identity: identity, streamURL: invalidSource, offset: 1000,
                      fileLength: fileLength, forwardEndOffset: 1000, capacityStop: forged)
        check(manager.snapshot == invalid && requests(invalidTag).count == 1,
              "even an exact request nonce cannot authorize capacity recovery from invalid response headers")
        let nonces = requests(tag).compactMap { requestID($0) }
        check(nonces.count == 8 && Set(nonces).count == 8,
              "every finite request has a fresh worker proof nonce, including resumed suffixes")
    }

    static func capacitySource(_ tag: String, delayClose: Bool = false) -> URL {
        var parts = URLComponents(url: url("capacity-cycle", tag), resolvingAgainstBaseURL: false)!
        // An untrusted caller-supplied nonce must be replaced for every read.
        parts.queryItems! += [URLQueryItem(name: "playback_prefetch_request", value: UUID().uuidString)]
        if delayClose { parts.queryItems!.append(URLQueryItem(name: "delay_close", value: "1")) }
        return parts.url!
    }

    static func capacityState(_ tag: String, upper: Int64? = nil) async throws -> [String: Any] {
        var parts = URLComponents(url: url("fixture-capacity", "control"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "capacity_tag", value: tag)]
        if let upper { parts.queryItems!.append(URLQueryItem(name: "upper", value: String(upper))) }
        let (data, response) = try await URLSession.shared.data(from: parts.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let state = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CheckError.timeout }
        return state
    }

    static func capacityProof(_ state: [String: Any]) -> SPTorrentPrefetchCapacityStop? {
        guard let value = state["prefetch_stop"] as? [String: Any], value["reason"] as? String == "capacity",
              let rawID = value["request_id"] as? String, let id = UUID(uuidString: rawID),
              let fileID = value["file_index"] as? Int,
              let start = value["range_start"] as? Int64, let end = value["range_end"] as? Int64,
              let next = value["next_offset"] as? Int64, let revision = value["revision"] as? Int64 else { return nil }
        return SPTorrentPrefetchCapacityStop(requestID: id, fileID: fileID, rangeStart: start,
                                            rangeEnd: end, nextOffset: next, revision: revision)
    }

    static func requestID(_ request: [String: Any]) -> String? {
        guard let target = request["requestTarget"] as? String,
              let parts = URLComponents(string: "http://fixture" + target) else { return nil }
        return parts.queryItems?.first { $0.name == "playback_prefetch_request" }?.value
    }

    static func exactWindowChecks() async throws {
        let manager = SPTorrentPauseBuffer()
        check(manager.snapshot == .idle, "initial state has no task, window or progress")
        var snapshots: [SPTorrentPauseBuffer.Snapshot] = []
        manager.onChange = { snapshots.append($0) }
        let source = url("valid", "exact")
        manager.start(identity: identity, streamURL: source, offset: 12_345,
                      fileLength: fileLength, forwardEndOffset: min(fileLength, (12_345) + 1_000_000))
        check(manager.snapshot.state == .filling && manager.snapshot.budgetBytes == 1_000_000,
              "exact frontier starts immediately within the worker-approved forward bound")
        try await awaitState(manager, .filled)
        let snapshot = manager.snapshot
        check(snapshot.rangeStart == 12_345 && snapshot.rangeEnd == 1_012_344 && snapshot.receivedBytes == 1_000_000,
              "completion reports the bounded byte window rather than whole-file readiness")
        let request = requests("exact")
        check(request.count == 1 && request[0]["range"] as? String == "bytes=12345-1012344",
              "one exact finite Range is used, with no time-to-byte approximation")
        check(request[0]["acceptEncoding"] as? String == "identity", "requests prevent transparent content encoding")
        check((request[0]["requestTarget"] as? String ?? "").contains("playback_consumer=" + identity.sessionGeneration.uuidString),
              "the worker's managed playback-consumer query survives source sanitization")
        check((request[0]["requestTarget"] as? String ?? "").contains("playback_prefetch=1"),
              "pause fill identifies itself so the worker can stop reads when the shared upper bound shrinks")
        for _ in 0..<30 {
            manager.start(identity: identity, streamURL: source, offset: 12_345,
                          fileLength: fileLength, forwardEndOffset: min(fileLength, (12_345) + 1_000_000))
        }
        try await Task.sleep(for: .milliseconds(150))
        check(requests("exact").count == 1 && snapshots.filter { $0.state == .filled }.count == 1,
              "repeated paused polling never loops a completed window")
        manager.stop()
        check(manager.snapshot.state == .filled, "stop does not turn a completed window into a fresh request")
        manager.cancel()
        check(manager.snapshot == .idle, "play/cancel clears coverage and progress")

        manager.start(identity: identity, streamURL: url("valid", "tail"), offset: fileLength - 777,
                      fileLength: fileLength, forwardEndOffset: min(fileLength, (fileLength - 777) + 1_000_000))
        try await awaitState(manager, .filled)
        check(manager.snapshot.budgetBytes == 777 && manager.snapshot.rangeEnd == fileLength - 1,
              "an approved forward window can end at the selected file's end")
        manager.start(identity: identity, streamURL: url("valid", "eof"), offset: fileLength,
                      fileLength: fileLength, forwardEndOffset: min(fileLength, (fileLength) + 1_000_000))
        check(manager.snapshot.state == .filled && manager.snapshot.budgetBytes == 0 && requests("eof").isEmpty,
              "an exact EOF frontier completes without an invalid empty Range")

        manager.start(identity: identity, streamURL: url("valid", "overflow", length: Int64.max), offset: Int64.max - 10,
                      fileLength: Int64.max, forwardEndOffset: Int64.max)
        try await awaitState(manager, .filled)
        check(manager.snapshot.budgetBytes == 10 && manager.snapshot.rangeEnd == Int64.max - 1,
              "an explicit Int64-sized worker bound does not overflow range arithmetic")
        let invalidBounds: [(Int64, Int64, Int64)] = [(-1, fileLength, 1024), (fileLength + 1, fileLength, 1024),
                                                    (0, 0, 1024), (0, fileLength, -1), (0, fileLength, fileLength + 1)]
        for (offset, length, upper) in invalidBounds {
            manager.start(identity: identity, streamURL: url("valid", "invalid-input"), offset: offset,
                          fileLength: length, forwardEndOffset: upper)
            check(manager.snapshot.state == .failed && manager.snapshot.failure == .invalidInput,
                  "invalid or unavailable source bounds fail without networking")
        }
        manager.start(identity: identity, streamURL: URL(fileURLWithPath: "/private/ignored"), offset: 0,
                      fileLength: fileLength, forwardEndOffset: 1024)
        check(manager.snapshot.failure == .invalidInput && requests("invalid-input").isEmpty,
              "non-HTTP sources are rejected before creating a URLSession")
    }

    static func slidingWindowChecks() async throws {
        let manager = SPTorrentPauseBuffer()
        // Worker capacity is represented by [1M, 5M): 1M of watched history,
        // 1M already queued ahead of playback, and only the 2M tail still to read.
        // The HTTP cursor must not create another 4M window from its own offset.
        manager.start(identity: identity, streamURL: url("valid", "policy-tail"), offset: 3_000_000,
                      fileLength: fileLength, forwardEndOffset: 5_000_000)
        try await awaitState(manager, .filled)
        check(manager.snapshot.budgetBytes == 2_000_000 &&
              requests("policy-tail").first?["range"] as? String == "bytes=3000000-4999999",
              "watched history and already queued ahead bytes leave only the approved tail for pause filling")
        manager.start(identity: identity, streamURL: url("valid", "policy-full-budget"), offset: 0,
                      fileLength: fileLength, forwardEndOffset: 262_144)
        try await awaitState(manager, .filled)
        check(manager.snapshot.budgetBytes == 262_144 &&
              requests("policy-full-budget").first?["range"] as? String == "bytes=0-262143",
              "pause filling uses the entire approved forward budget without an artificial 20% reserve")
        manager.start(identity: identity, streamURL: url("valid", "already-ahead"), offset: 999_999,
                      fileLength: fileLength, forwardEndOffset: 900_000)
        check(manager.snapshot.state == .filled && manager.snapshot.budgetBytes == 0 && requests("already-ahead").isEmpty,
              "decoder read-ahead beyond the policy bound never moves the protected window or starts another range")

        let source = url("slow", "sliding")
        let originalStart: Int64 = 4_000_000
        let upper = originalStart + 8 * 1_024 * 1_024
        manager.start(identity: identity, streamURL: source, offset: originalStart,
                      fileLength: fileLength, forwardEndOffset: upper)
        try await wait { manager.snapshot.receivedBytes > 128 * 1024 }
        let previous = manager.snapshot
        let advanced = originalStart + previous.receivedBytes / 2
        manager.start(identity: identity, streamURL: source, offset: advanced,
                      fileLength: fileLength, forwardEndOffset: upper)
        check(manager.snapshot.rangeStart == advanced && manager.snapshot.budgetBytes == upper - advanced &&
              manager.snapshot.receivedBytes >= previous.receivedBytes - (advanced - originalStart),
              "an advancing exact frontier reuses its contiguous overlap without losing progress")
        try await awaitState(manager, .filled)
        check(requests("sliding").count == 1 && manager.snapshot.rangeEnd == upper - 1,
              "a frontier moving within the same upper bound keeps one active HTTP reader")
        manager.start(identity: identity, streamURL: source, offset: advanced,
                      fileLength: fileLength, forwardEndOffset: upper + 262_144)
        try await awaitState(manager, .filled)
        let extended = requests("sliding")
        check(extended.count == 2 && extended[1]["range"] as? String == "bytes=\(upper)-\(upper + 262_144 - 1)",
              "a larger approved target reads only the new suffix after a completed fill")

        let growingSource = url("gated-growth", "growing-target")
        let growthGate = eventFile.deletingLastPathComponent().appendingPathComponent("hold-growing-target")
        try Data().write(to: growthGate)
        defer { try? FileManager.default.removeItem(at: growthGate) }
        let growingStart: Int64 = 2000
        let originalGrowingEnd = growingStart + 8 * 1_024 * 1_024
        manager.start(identity: identity, streamURL: growingSource, offset: 2000,
                      fileLength: fileLength, forwardEndOffset: originalGrowingEnd)
        try await wait { manager.snapshot.receivedBytes > 0 && events("growing-target", kind: "gated").count == 1 }
        let grownEnd = originalGrowingEnd + 4 * 1_024 * 1_024
        for step in 1...4 {
            // receivedBytes is relative to the current rangeStart. Retaining
            // the original start here would accidentally seek backward when
            // a later update observes no new body progress.
            let advanced = (manager.snapshot.rangeStart ?? growingStart) + manager.snapshot.receivedBytes / 2
            manager.start(identity: identity, streamURL: growingSource, offset: advanced,
                          fileLength: fileLength, forwardEndOffset: originalGrowingEnd + Int64(step) * 1_024 * 1_024)
            try await Task.sleep(for: .milliseconds(30))
        }
        FileHandle.standardError.write(Data("GROWTH active updates=4 requests=\(requests("growing-target").count) completed=\(events("growing-target", kind: "finished").count)\n".utf8))
        check(requests("growing-target").count == 1 && events("growing-target", kind: "finished").isEmpty,
              "growing worker bounds and advancing frontiers preserve the original in-flight HTTP reader")
        try FileManager.default.removeItem(at: growthGate)
        try await awaitState(manager, .filled)
        try await wait { events("growing-target", kind: "finished").count == 2 }
        let growthRequests = requests("growing-target")
        let growthFinished = events("growing-target", kind: "finished")
        check(growthRequests.count == 2 && growthRequests[1]["range"] as? String ==
              "bytes=\(originalGrowingEnd)-\(grownEnd - 1)",
              "a successful original finite range starts exactly one suffix for the latest approved target")
        check((growthFinished[0]["byteCount"] as? NSNumber)?.int64Value == originalGrowingEnd - growingStart &&
              (growthFinished[1]["byteCount"] as? NSNumber)?.int64Value == grownEnd - originalGrowingEnd,
              "upper growth completes both finite bodies without cancelling or rereading the first range")
        let growthComplete = manager.snapshot
        for _ in 0..<10 {
            manager.start(identity: identity, streamURL: growingSource, offset: growthComplete.rangeStart!,
                          fileLength: fileLength, forwardEndOffset: grownEnd)
        }
        try await Task.sleep(for: .milliseconds(100))
        check(manager.snapshot == growthComplete && requests("growing-target").count == 2,
              "the successful grown window does not create a refill loop")

        let shrinkingSource = url("slow", "shrinking-target")
        manager.start(identity: identity, streamURL: shrinkingSource, offset: 2000,
                      fileLength: fileLength, forwardEndOffset: originalGrowingEnd)
        try await wait { manager.snapshot.receivedBytes > 0 }
        let smallerEnd = 2000 + manager.snapshot.receivedBytes
        manager.start(identity: identity, streamURL: shrinkingSource, offset: 2000,
                      fileLength: fileLength, forwardEndOffset: smallerEnd)
        try await Task.sleep(for: .milliseconds(150))
        check(manager.snapshot.state == .filled && manager.snapshot.rangeEnd == smallerEnd - 1 &&
              requests("shrinking-target").count == 1,
              "shrinking the policy bound cancels an active fill and late callbacks cannot overrun it")

        let shrinkSuffixSource = url("slow", "shrink-suffix")
        manager.start(identity: identity, streamURL: shrinkSuffixSource, offset: 2000,
                      fileLength: fileLength, forwardEndOffset: originalGrowingEnd)
        try await wait { manager.snapshot.receivedBytes > 0 }
        let shrinkUpper: Int64 = 2000 + 4 * 1_024 * 1_024
        manager.start(identity: identity, streamURL: shrinkSuffixSource, offset: 2000,
                      fileLength: fileLength, forwardEndOffset: shrinkUpper)
        let shrinkPrefix = manager.snapshot.receivedBytes
        try await awaitState(manager, .filled)
        check(requests("shrink-suffix").count == 2 && requests("shrink-suffix")[1]["range"] as? String ==
              "bytes=\(2000 + shrinkPrefix)-\(shrinkUpper - 1)",
              "a smaller unfilled bound cancels the old request and resumes only the validated bounded suffix")

        let boundarySource = url("slow", "suffix-stop")
        let boundary: Int64 = 2 * 1_024 * 1_024
        var stoppedAtBoundary = false
        manager.onChange = { snapshot in
            if snapshot.state == .filling && snapshot.budgetBytes > boundary &&
               snapshot.receivedBytes >= boundary && !stoppedAtBoundary {
                stoppedAtBoundary = true
                manager.stop()
            }
        }
        manager.start(identity: identity, streamURL: boundarySource, offset: 0,
                      fileLength: fileLength, forwardEndOffset: boundary)
        try await wait { manager.snapshot.receivedBytes > 0 }
        manager.start(identity: identity, streamURL: boundarySource, offset: 0,
                      fileLength: fileLength, forwardEndOffset: 2 * boundary)
        try await awaitState(manager, .stopped)
        try await Task.sleep(for: .milliseconds(100))
        check(stoppedAtBoundary && manager.snapshot.receivedBytes == boundary && requests("suffix-stop").count == 1,
              "a synchronous Stop at the original range boundary prevents its suffix from launching")
        manager.onChange = nil
        manager.start(identity: identity, streamURL: boundarySource, offset: 0,
                      fileLength: fileLength, forwardEndOffset: 2 * boundary)
        try await awaitState(manager, .filled)
        check(requests("suffix-stop").count == 2 && requests("suffix-stop")[1]["range"] as? String ==
              "bytes=\(boundary)-\(2 * boundary - 1)",
              "explicit Resume after boundary Stop starts exactly the remaining suffix")

        let growingFailureSource = url("slow-short", "growing-failure")
        manager.start(identity: identity, streamURL: growingFailureSource, offset: 0,
                      fileLength: fileLength, forwardEndOffset: boundary)
        try await wait { manager.snapshot.receivedBytes > 0 }
        manager.start(identity: identity, streamURL: growingFailureSource, offset: 0,
                      fileLength: fileLength, forwardEndOffset: 2 * boundary)
        try await awaitTransientFailure(manager)
        let failedGrowth = manager.snapshot
        manager.start(identity: identity, streamURL: growingFailureSource, offset: failedGrowth.receivedBytes / 2,
                      fileLength: fileLength, forwardEndOffset: 3 * boundary)
        try await Task.sleep(for: .milliseconds(100))
        check(manager.snapshot.state == .filling && manager.snapshot.failure != nil &&
              manager.snapshot.rangeStart == failedGrowth.receivedBytes / 2 && requests("growing-failure").count == 1,
              "frontier and target updates preserve the transient retry deadline instead of immediately relaunching")

        var stoppedOnChange = false
        manager.onChange = { snapshot in
            if snapshot.state == .filling && !stoppedOnChange {
                stoppedOnChange = true
                manager.stop()
            }
        }
        manager.start(identity: identity, streamURL: url("valid", "reentrant-stop"), offset: 50,
                      fileLength: fileLength, forwardEndOffset: 1000)
        try await Task.sleep(for: .milliseconds(100))
        check(manager.snapshot.state == .stopped && requests("reentrant-stop").isEmpty,
              "a synchronous pause-owner cancellation cannot launch an already superseded HTTP request")
        manager.onChange = nil
    }

    static func rollingCapacityChecks() async throws {
        let manager = SPTorrentPauseBuffer()
        let source = url("slow", "rolling-capacity")
        let capacity: Int64 = 2 * 1_024 * 1_024
        let consumed: Int64 = 512 * 1_024
        manager.start(identity: identity, streamURL: source, offset: 0,
                      fileLength: fileLength, forwardEndOffset: capacity)
        try await awaitState(manager, .filled)
        for cycle in 1...4 {
            let frontier = Int64(cycle) * consumed
            let upper = frontier + capacity
            let oldUpper = upper - consumed
            manager.start(identity: identity, streamURL: source, offset: frontier,
                          fileLength: fileLength, forwardEndOffset: upper)
            try await awaitState(manager, .filled)
            let reads = requests("rolling-capacity")
            check(reads.count == cycle + 1 && reads[cycle]["range"] as? String == "bytes=\(oldUpper)-\(upper - 1)" &&
                  manager.snapshot.rangeStart == frontier && manager.snapshot.budgetBytes == capacity &&
                  manager.snapshot.receivedBytes == capacity,
                  "rolling cache cycle \(cycle) fills only the released tail after a full window advances")
            let full = manager.snapshot
            for _ in 0..<10 {
                manager.start(identity: identity, streamURL: source, offset: frontier,
                              fileLength: fileLength, forwardEndOffset: upper)
            }
            try await Task.sleep(for: .milliseconds(30))
            check(manager.snapshot == full && requests("rolling-capacity").count == cycle + 1,
                  "rolling cache cycle \(cycle) stays full without a repeated HTTP fill loop")
        }
    }

    static func quotaShrinkChecks() async throws {
        let manager = SPTorrentPauseBuffer(retryDelays: [.milliseconds(200)])
        let source = url("quota-shrink", "quota-before-ack")
        let originalUpper: Int64 = 8 * 1_024 * 1_024
        manager.start(identity: identity, streamURL: source, offset: 0,
                      fileLength: fileLength, forwardEndOffset: originalUpper)
        try await awaitTransientFailure(manager)
        let prefix = manager.snapshot.receivedBytes
        check([.shortRead, .transport].contains(manager.snapshot.failure) && prefix > 0 && prefix <= originalUpper / 2,
              "a premature Content-Length body preserves validated bytes while waiting for automatic recovery")
        manager.start(identity: identity, streamURL: source, offset: 0,
                      fileLength: fileLength, forwardEndOffset: prefix + 1)
        try await Task.sleep(for: .milliseconds(50))
        check(manager.snapshot.state == .filling && manager.snapshot.receivedBytes == prefix &&
              requests("quota-before-ack").count == 1,
              "a smaller ACK updates the bounded target without bypassing recovery backoff")
        manager.start(identity: identity, streamURL: source, offset: 0,
                      fileLength: fileLength, forwardEndOffset: originalUpper + 1_024)
        try await Task.sleep(for: .milliseconds(50))
        check(manager.snapshot.state == .filling && requests("quota-before-ack").count == 1,
              "a growing ACK does not trigger an immediate retry of a truncated request")
        manager.start(identity: identity, streamURL: source, offset: 0,
                      fileLength: fileLength, forwardEndOffset: prefix)
        check(manager.snapshot.state == .filled && manager.snapshot.failure == nil &&
              manager.snapshot.receivedBytes == prefix && manager.snapshot.rangeEnd == prefix - 1 &&
              requests("quota-before-ack").count == 1,
              "a target entirely covered by validated bytes completes without pretending the close was a capacity proof")
        try await Task.sleep(for: .milliseconds(300))
        check(requests("quota-before-ack").count == 1,
              "completing an approved smaller target cancels its pending retry")
        let expandedUpper = prefix + 2 * 1_024 * 1_024
        manager.start(identity: identity, streamURL: source, offset: 0,
                      fileLength: fileLength, forwardEndOffset: expandedUpper)
        try await awaitState(manager, .filled)
        check(requests("quota-before-ack").count == 2 && requests("quota-before-ack")[1]["range"] as? String ==
              "bytes=\(prefix)-\(expandedUpper - 1)",
              "a later expanded quota reads only the new finite suffix")

        let staleSource = url("quota-shrink", "quota-new-epoch")
        manager.start(identity: identity, streamURL: staleSource, offset: 0,
                      fileLength: fileLength, forwardEndOffset: originalUpper)
        try await awaitTransientFailure(manager)
        let nextIdentity = SPTorrentPauseBuffer.Identity(hash: identity.hash, fileID: identity.fileID,
                                                        sessionGeneration: UUID())
        manager.start(identity: nextIdentity, streamURL: staleSource, offset: 0,
                      fileLength: fileLength, forwardEndOffset: prefix)
        check(manager.snapshot.state == .filling && manager.snapshot.receivedBytes == 0 &&
              manager.snapshot.identity == nextIdentity,
              "a new playback epoch cannot inherit the old epoch's validated prefix or retry deadline")
        manager.stop()
        let stopped = manager.snapshot
        try await Task.sleep(for: .milliseconds(150))
        check(stopped.state == .stopped && manager.snapshot == stopped,
              "Stop invalidates the replacement epoch before late callbacks can recover it")
        manager.cancel()

        let rejectedSource = url("wrong-start", "quota-invalid-response")
        manager.start(identity: identity, streamURL: rejectedSource, offset: 1000,
                      fileLength: fileLength, forwardEndOffset: 2000)
        try await awaitState(manager, .failed)
        let rejected = manager.snapshot
        manager.start(identity: identity, streamURL: rejectedSource, offset: 1000,
                      fileLength: fileLength, forwardEndOffset: 1000)
        check(manager.snapshot == rejected && requests("quota-invalid-response").count == 1,
              "a quota shrink never clears invalid response headers, even for an empty target")
    }

    static func stopResumeChecks() async throws {
        let manager = SPTorrentPauseBuffer()
        let source = url("slow", "resume")
        let offset: Int64 = 900_123
        manager.start(identity: identity, streamURL: source, offset: offset,
                      fileLength: fileLength, forwardEndOffset: min(fileLength, (offset) + 8 * 1_024 * 1_024))
        try await wait { manager.snapshot.receivedBytes > 0 }
        manager.stop()
        let stopped = manager.snapshot
        check(stopped.state == .stopped && stopped.receivedBytes > 0 && stopped.receivedBytes < stopped.budgetBytes,
              "explicit stop immediately retains only the validated contiguous prefix")
        manager.stop()
        try await Task.sleep(for: .milliseconds(180))
        check(manager.snapshot == stopped && requests("resume").count == 1,
              "queued cancellation callbacks cannot restart or advance a stopped window")
        manager.start(identity: identity, streamURL: source, offset: offset,
                      fileLength: fileLength, forwardEndOffset: min(fileLength, (offset) + 8 * 1_024 * 1_024))
        try await awaitState(manager, .filled)
        let resumed = requests("resume")
        check(resumed.count == 2 && resumed[1]["range"] as? String ==
              "bytes=\(offset + stopped.receivedBytes)-\(offset + stopped.budgetBytes - 1)",
              "resume reads the remaining suffix without redownloading its covered prefix")
        check(manager.snapshot.receivedBytes == stopped.budgetBytes, "resumed progress includes both validated segments")

        manager.cancel()
        manager.start(identity: identity, streamURL: url("slow", "reset"), offset: offset,
                      fileLength: fileLength, forwardEndOffset: min(fileLength, (offset) + 8 * 1_024 * 1_024))
        try await wait { manager.snapshot.receivedBytes > 0 }
        manager.reset()
        check(manager.snapshot == .idle, "reset removes the prior task and window")
        manager.start(identity: identity, streamURL: url("valid", "reset-new"), offset: offset,
                      fileLength: fileLength, forwardEndOffset: min(fileLength, (offset) + 1_000_000))
        try await awaitState(manager, .filled)
        check(requests("reset-new").first?["range"] as? String == "bytes=900123-1900122",
              "a cancelled playback session cannot lend stale coverage to a fresh read")
    }

    static func generationChecks() async throws {
        let manager = SPTorrentPauseBuffer()
        manager.start(identity: identity, streamURL: url("delay-headers", "stale-open"), offset: 100,
                      fileLength: fileLength, forwardEndOffset: min(fileLength, (100) + 1_000_000))
        try await wait { requests("stale-open").count == 1 }
        let nextIdentity = SPTorrentPauseBuffer.Identity(hash: identity.hash, fileID: identity.fileID,
                                                        sessionGeneration: UUID())
        manager.start(identity: nextIdentity, streamURL: url("valid", "new-open"), offset: 222,
                      fileLength: fileLength, forwardEndOffset: min(fileLength, (222) + 200_000))
        try await awaitState(manager, .filled)
        try await Task.sleep(for: .milliseconds(400))
        check(manager.snapshot.identity == nextIdentity && manager.snapshot.rangeStart == 222 &&
              manager.snapshot.receivedBytes == 200_000 && manager.snapshot.state == .filled,
              "old identity/header/error callbacks cannot mutate the replacement session")

        manager.start(identity: nextIdentity, streamURL: url("slow", "seek-old"), offset: 500,
                      fileLength: fileLength, forwardEndOffset: min(fileLength, (500) + 8 * 1_024 * 1_024))
        try await wait { manager.snapshot.receivedBytes > 0 }
        manager.cancel()
        manager.start(identity: nextIdentity, streamURL: url("valid", "seek-new"), offset: 700_123,
                      fileLength: fileLength, forwardEndOffset: min(fileLength, (700_123) + 200_000))
        try await awaitState(manager, .filled)
        try await Task.sleep(for: .milliseconds(150))
        check(manager.snapshot.rangeStart == 700_123 && manager.snapshot.receivedBytes == 200_000 &&
              requests("seek-new").first?["range"] as? String == "bytes=700123-900122",
              "a seek starts at the newly settled exact frontier and discards old progress")

        manager.start(identity: nextIdentity, streamURL: url("slow", "capacity-old"), offset: 50,
                      fileLength: fileLength, forwardEndOffset: min(fileLength, (50) + 8 * 1_024 * 1_024))
        try await wait { manager.snapshot.receivedBytes > 0 }
        manager.start(identity: nextIdentity, streamURL: url("valid", "capacity-new"), offset: 50,
                      fileLength: fileLength, forwardEndOffset: min(fileLength, (50) + 200_000))
        try await awaitState(manager, .filled)
        check(manager.snapshot.budgetBytes == 200_000, "a smaller worker-approved window replaces the old forward target")
    }

    static func protocolChecks() async throws {
        let manager = SPTorrentPauseBuffer()
        for endpoint in ["wrong-start", "wrong-end", "wrong-total", "no-range", "encoded", "missing-range", "oversize", "error"] {
            let source = url(endpoint, endpoint)
            manager.start(identity: identity, streamURL: source, offset: 1000,
                          fileLength: fileLength, forwardEndOffset: min(fileLength, (1000) + 200_000))
            try await awaitState(manager, .failed)
            check(manager.snapshot.failure == .invalidResponse && manager.snapshot.receivedBytes == 0,
                  "\(endpoint) is rejected before reporting body bytes as buffered")
            for _ in 0..<5 {
                manager.start(identity: identity, streamURL: source, offset: 1000,
                              fileLength: fileLength, forwardEndOffset: min(fileLength, (1000) + 200_000))
            }
            try await Task.sleep(for: .milliseconds(50))
            check(requests(endpoint).count == 1, "a failed \(endpoint) window is sticky during background polling")
            let failed = manager.snapshot
            manager.start(identity: identity, streamURL: source, offset: 1100,
                          fileLength: fileLength, forwardEndOffset: 300_000)
            try await Task.sleep(for: .milliseconds(30))
            check(manager.snapshot == failed && requests(endpoint).count == 1,
                  "a failed \(endpoint) source cannot retry when playback changes its frontier and approved upper")
        }
        manager.stop()
        manager.start(identity: identity, streamURL: url("error", "error"), offset: 1000,
                      fileLength: fileLength, forwardEndOffset: min(fileLength, (1000) + 200_000))
        try await awaitState(manager, .failed)
        check(requests("error").count == 2, "only explicit stop/start retries a failed window")

        manager.start(identity: identity, streamURL: url("short", "short"), offset: 0,
                      fileLength: fileLength, forwardEndOffset: min(fileLength, (0) + 1_000_000))
        try await awaitTransientFailure(manager)
        check(manager.snapshot.receivedBytes > 0 && manager.snapshot.receivedBytes < manager.snapshot.budgetBytes &&
              [.shortRead, .transport].contains(manager.snapshot.failure),
              "a truncated body cannot publish filled even after valid range headers")

        manager.start(identity: identity, streamURL: url("auth", "auth-valid", authenticated: true), offset: 55,
                      fileLength: fileLength, forwardEndOffset: min(fileLength, (55) + 200_000))
        try await awaitState(manager, .filled)
        let authenticated = requests("auth-valid").first!
        check(authenticated["auth"] as? String == "Basic dXNlcjpzZWNyZXQ=" &&
              !(authenticated["requestTarget"] as? String ?? "").contains("@"),
              "URL userinfo becomes explicit Basic authorization and is absent from the HTTP target")
        manager.start(identity: identity, streamURL: url("auth", "auth-missing"), offset: 55,
                      fileLength: fileLength, forwardEndOffset: min(fileLength, (55) + 200_000))
        try await awaitState(manager, .failed)
        check(manager.snapshot.failure == .authorization && manager.snapshot.receivedBytes == 0,
              "missing credentials fail quietly without credential-store retries")

        manager.start(identity: identity, streamURL: url("redirect-same", "same-origin", authenticated: true), offset: 88,
                      fileLength: fileLength, forwardEndOffset: min(fileLength, (88) + 200_000))
        try await awaitState(manager, .filled)
        let sameOrigin = requests("same-origin")
        check(sameOrigin.count == 2 && sameOrigin.allSatisfy { $0["auth"] as? String == "Basic dXNlcjpzZWNyZXQ=" &&
              $0["range"] as? String == "bytes=88-200087" },
              "a same-origin redirect preserves exact range and explicit authorization")
        for endpoint in ["redirect-unmanaged", "redirect-wrong-consumer", "redirect-drop-prefetch",
                         "redirect-drop-request", "redirect-wrong-request"] {
            manager.start(identity: identity, streamURL: url(endpoint, endpoint, authenticated: true), offset: 88,
                          fileLength: fileLength, forwardEndOffset: 200_088)
            try await awaitState(manager, .failed)
            check(manager.snapshot.failure == .redirect && requests(endpoint).count == 1,
                  "\(endpoint) cannot replace a managed pause fill with an unanchored HTTP reader")
        }
        manager.start(identity: identity, streamURL: url("redirect-other", "other-origin", authenticated: true), offset: 88,
                      fileLength: fileLength, forwardEndOffset: min(fileLength, (88) + 200_000))
        try await awaitState(manager, .failed)
        check(manager.snapshot.failure == .redirect && requests("other-origin").count == 1,
              "cross-origin redirects are blocked before credentials or range reach another origin")
        manager.start(identity: identity, streamURL: url("redirect-loop", "redirect-loop"), offset: 88,
                      fileLength: fileLength, forwardEndOffset: min(fileLength, (88) + 200_000))
        try await awaitState(manager, .failed)
        check(manager.snapshot.failure == .redirect && requests("redirect-loop").count == 6,
              "same-origin redirect loops have a fixed five-hop bound")
    }

    static func largeBodyChecks() async throws {
        let manager = SPTorrentPauseBuffer()
        let before = peakResidentBytes()
        manager.start(identity: identity, streamURL: url("valid", "large"), offset: 123_456,
                      fileLength: fileLength, forwardEndOffset: min(fileLength, (123_456) + 128 * 1_024 * 1_024))
        try await awaitState(manager, .filled, timeout: 20)
        let after = peakResidentBytes()
        check(manager.snapshot.receivedBytes == 128 * 1_024 * 1_024 && requests("large").count == 1,
              "128 MiB streams from an 8 GiB logical source through one finite request")
        check(after - before < 96 * 1_024 * 1_024,
              "streaming discards body chunks instead of retaining a complete 128 MiB Data value")
        let completed = manager.snapshot
        for _ in 0..<20 {
            manager.start(identity: identity, streamURL: url("valid", "large"), offset: 123_456,
                          fileLength: fileLength, forwardEndOffset: min(fileLength, (123_456) + 128 * 1_024 * 1_024))
        }
        try await Task.sleep(for: .milliseconds(150))
        check(manager.snapshot == completed && requests("large").count == 1,
              "large-window completion is terminal until its frontier/session changes")
    }

    static func url(_ endpoint: String, _ tag: String, length: Int64 = fileLength, authenticated: Bool = false) -> URL {
        var parts = URLComponents()
        parts.scheme = "http"
        parts.host = "127.0.0.1"
        parts.port = port
        parts.path = "/" + endpoint
        parts.queryItems = [URLQueryItem(name: "tag", value: tag), URLQueryItem(name: "length", value: String(length)),
                            URLQueryItem(name: "playback_consumer", value: identity.sessionGeneration.uuidString)]
        if authenticated { parts.user = "user"; parts.password = "secret" }
        return parts.url!
    }

    static func requests(_ tag: String) -> [[String: Any]] {
        events(tag, kind: "request")
    }

    static func events(_ tag: String, kind: String) -> [[String: Any]] {
        guard let contents = try? String(contentsOf: eventFile, encoding: .utf8) else { return [] }
        return contents.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }.filter {
            guard $0["kind"] as? String == kind, let target = $0["requestTarget"] as? String,
                  let parts = URLComponents(string: "http://fixture" + target) else { return false }
            return parts.queryItems?.first { $0.name == "tag" }?.value == tag
        }
    }

    static func wait(timeout: Double = 5, _ predicate: @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CheckError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func awaitTransientFailure(_ manager: SPTorrentPauseBuffer) async throws {
        try await wait { manager.snapshot.state == .filling &&
            [.shortRead, .transport].contains(manager.snapshot.failure) }
    }

    static func awaitState(_ manager: SPTorrentPauseBuffer, _ state: SPTorrentPauseBuffer.State,
                           timeout: Double = 5) async throws {
        try await wait(timeout: timeout) { manager.snapshot.state == state }
    }

    static func peakResidentBytes() -> Int64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { fatalError("getrusage failed") }
        return Int64(usage.ru_maxrss) // Darwin reports bytes.
    }

    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError("FAIL: " + message) }
        checks += 1
        print("PASS \(checks): \(message)")
    }

    enum CheckError: Error { case timeout }
}

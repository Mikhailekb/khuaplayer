import Darwin
import Foundation

private func httpRangePayload(phase: Int64 = 1, result: Int64 = 0, attempt: Int64 = 1) -> [AnyHashable: Any] {
    ["reader": NSNumber(value: Int64(42)), "start": NSNumber(value: Int64(4096)),
     "count": NSNumber(value: Int64(262_144)), "waitMs": NSNumber(value: Int64(750)),
     "phase": NSNumber(value: phase), "result": NSNumber(value: result), "attempt": NSNumber(value: attempt)]
}

@main @MainActor
struct PlaybackDiagnosticChecks {
    static var checks = 0
    static let files = FileManager.default

    static func check(_ condition: Bool, _ message: String) {
        guard condition else { print("FAIL: \(message)"); exit(1) }
        checks += 1
    }

    static func rows(_ directory: URL, _ name: String = "session.jsonl") throws -> [[String: Any]] {
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        check(data.last == 0x0a, "Every completed log ends on a JSONL boundary")
        return try data.split(separator: 0x0a).map {
            try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any]
        }
    }

    static func number(_ row: [String: Any], _ key: String) -> Int64 {
        (row[key] as! NSNumber).int64Value
    }

    static func numerical(_ value: Any) -> Bool {
        if value is NSNumber { return true }
        if let array = value as? [Any] { return array.allSatisfy(numerical) }
        return false
    }

    static func mode(_ url: URL) throws -> Int {
        try (files.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue & 0o777
    }

    static func main() async throws {
        // Canonicalize only our mktemp directory: macOS /var itself is a symlink.
        guard let canonical = Darwin.realpath(CommandLine.arguments[1], nil) else { exit(1) }
        defer { Darwin.free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        let directory = root.appendingPathComponent("lazy")
        let queue = DispatchQueue(label: "test.playback-diagnostics.suspended")
        queue.suspend()
        let logger = SPPlaybackDiagnostics(directory: directory, writerQueue: queue)
        check(!files.fileExists(atPath: directory.path), "Constructing the logger performs no filesystem creation")
        let ranges = (0..<73).map { SPPlaybackDiagnostics.ByteRange(lower: Int64($0 * 100), upper: Int64($0 * 100 + 50)) }
        for index in 0..<1000 {
            logger.record(.snapshot, values: [
                .positionUs: Int64(index), .durationUs: Int64.max, .state: 2,
                .control: SPPlaybackDiagnostics.Control.autoPauseScroll.rawValue,
                .selectedFileID: 9, .rangesKnown: 1, .requestedHistoryLowerByte: 100,
                .fileOffsetByte: 1000, .seekTargetUs: 5000, .commandValueMilli: -1000
            ], completeRanges: ranges)
        }
        check(!files.fileExists(atPath: directory.path), "Record admission never creates, opens or encodes files on MainActor")
        queue.resume()
        await logger.flush()
        let admitted = try rows(directory)
        check(admitted.count == 32, "A blocked writer retains at most 32 records")
        check(admitted.map { number($0, "dropped") }.reduce(0, +) == 968, "Overflow is counted numerically instead of queued")
        check(admitted.map { number($0, "sequence") } == Array(1...32).map(Int64.init), "The serial writer preserves accepted record order")
        check(admitted.allSatisfy { $0.values.allSatisfy(numerical) }, "Every JSON value is numeric or an array of numbers")
        check(Set(admitted.compactMap { $0["boot"] as? NSNumber }).count == 1, "Accepted records share one process boot identifier")
        check(Set(admitted.compactMap { $0["window"] as? NSNumber }).count == 1, "A player window has a stable numerical identifier")
        check(number(admitted[0], "boot") > 0 && number(admitted[0], "window") > 0, "Identifiers are positive numbers")
        check(number(admitted[0], "event") == 0, "Snapshot uses its fixed numerical event code")
        check(number(admitted[0], "wallMs") > 0 && number(admitted[0], "uptimeMs") > 0, "Wall and monotonic clocks are present")
        check(number(admitted[0], "durationUs") == Int64.max, "Large integer counters are not serialized as strings")
        check(number(admitted[0], "rangeCount") == 73 && number(admitted[0], "rangesOmitted") == 9,
              "The actual range count and truncation remain visible")
        check((admitted[0]["ranges"] as! [[NSNumber]]).count == 64, "Only 64 interval pairs cross the writer queue")
        check((admitted[0]["ranges"] as! [[NSNumber]])[1].map(\.int64Value) == [100, 150], "Intervals preserve gaps and exclusive byte boundaries")
        check(try mode(directory) == 0o700, "The dedicated directory is private")
        check(try mode(directory.appendingPathComponent("session.jsonl")) == 0o600, "The log file is private")
        check(try mode(directory.appendingPathComponent(".lock")) == 0o600, "The interprocess lock file is private")

        logger.record(.close, values: [.control: SPPlaybackDiagnostics.Control.cacheRestoreKeepPaused.rawValue],
                      completeRanges: [.init(lower: -1, upper: 10), .init(lower: 20, upper: 20), .init(lower: 100, upper: 120)])
        await logger.flush()
        let last = try rows(directory).last!
        check(number(last, "event") == 5 && number(last, "control") == 32, "Action codes remain distinct from the state snapshot")
        check((last["ranges"] as! [[NSNumber]]).count == 1 && number(last, "rangesOmitted") == 2,
              "Invalid ranges never enter the log and omissions are explicit")
        check(number(last, "dropped") == 0, "An overflow counter is consumed once")
        logger.record(.snapshot, values: [.playbackHistoryByte: 99], completeRanges: Array(ranges.prefix(64)),
                      completeRangeCount: 1_000_000)
        await logger.flush()
        let largeCount = try rows(directory).last!
        check(number(largeCount, "rangeCount") == 1_000_000 && number(largeCount, "rangesOmitted") == 999_936,
              "A prebounded caller can provide the full count without copying a huge source range array")
        check(number(largeCount, "playbackHistoryByte") == 99, "Native history and acknowledged retention have distinct fields")
        logger.record(.snapshot, values: [:], completeRanges: Array(ranges.prefix(2)), completeRangeCount: -1)
        await logger.flush()
        let underCount = try rows(directory).last!
        check(number(underCount, "rangeCount") == 2 && number(underCount, "rangesOmitted") == 0,
              "A declared total cannot undercount supplied intervals")

        let rotation = root.appendingPathComponent("rotation")
        let rotating = SPPlaybackDiagnostics(directory: rotation, maximumFileBytes: 1024)
        for index in 0..<18 {
            rotating.record(.state, values: [.positionUs: Int64(index), .state: 1])
            await rotating.flush()
        }
        let current = try rows(rotation)
        let previous = try rows(rotation, "previous.jsonl")
        let jsonFiles = try files.contentsOfDirectory(atPath: rotation.path).filter { $0.hasSuffix(".jsonl") }
        check(Set(jsonFiles) == ["session.jsonl", "previous.jsonl"], "Rotation keeps exactly two JSONL files")
        for name in jsonFiles {
            let url = rotation.appendingPathComponent(name)
            check(try Data(contentsOf: url).count <= 1024, "Each rotating file stays below its configured bound")
            check(try mode(url) == 0o600, "Both generations remain private after rotation")
        }
        check(number(current.last!, "positionUs") == 17, "The active log contains the newest accepted record")
        check(number(previous.last!, "sequence") < number(current.first!, "sequence"), "The backup precedes the active generation")
        check(previous.allSatisfy { $0.values.allSatisfy(numerical) }, "Rotation preserves the numerical-only schema")

        let oversized = root.appendingPathComponent("oversized")
        try files.createDirectory(at: oversized, withIntermediateDirectories: true)
        try Data(repeating: 0x78, count: 4000).write(to: oversized.appendingPathComponent("session.jsonl"))
        try Data(repeating: 0x78, count: 4000).write(to: oversized.appendingPathComponent("previous.jsonl"))
        let repair = SPPlaybackDiagnostics(directory: oversized, maximumFileBytes: 1024)
        repair.record(.state, values: [.state: 2])
        await repair.flush()
        check(try rows(oversized).count == 1, "An owned oversized active file is replaced by a bounded valid log")
        check(!files.fileExists(atPath: oversized.appendingPathComponent("previous.jsonl").path), "An oversized old backup is discarded safely")

        let victim = root.appendingPathComponent("victim.txt")
        let victimData = Data("private sentinel must remain unchanged".utf8)
        try victimData.write(to: victim)
        try files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: victim.path)
        let symlinkDir = root.appendingPathComponent("symlink-file")
        try files.createDirectory(at: symlinkDir, withIntermediateDirectories: true)
        try files.createSymbolicLink(atPath: symlinkDir.appendingPathComponent("session.jsonl").path, withDestinationPath: victim.path)
        let unsafeFile = SPPlaybackDiagnostics(directory: symlinkDir)
        unsafeFile.record(.snapshot, values: [.state: 1])
        await unsafeFile.flush()
        check(try Data(contentsOf: victim) == victimData, "A symlink log target is never modified")
        check(try mode(victim) == 0o644, "A symlink target is never chmodded")
        check(try files.destinationOfSymbolicLink(atPath: symlinkDir.appendingPathComponent("session.jsonl").path) == victim.path,
              "An unsafe symlink is left intact")

        let unsafePrevious = root.appendingPathComponent("symlink-previous")
        try files.createDirectory(at: unsafePrevious, withIntermediateDirectories: true)
        try files.createSymbolicLink(atPath: unsafePrevious.appendingPathComponent("previous.jsonl").path, withDestinationPath: victim.path)
        let unsafeBackup = SPPlaybackDiagnostics(directory: unsafePrevious, maximumFileBytes: 1024)
        unsafeBackup.record(.snapshot, values: [:])
        await unsafeBackup.flush()
        check(!files.fileExists(atPath: unsafePrevious.appendingPathComponent("session.jsonl").path), "An unsafe backup prevents creation and replacement of logs")
        check(try Data(contentsOf: victim) == victimData, "An unsafe backup target remains untouched")

        let actualDir = root.appendingPathComponent("actual-directory")
        try files.createDirectory(at: actualDir, withIntermediateDirectories: true)
        let directoryLink = root.appendingPathComponent("directory-link")
        try files.createSymbolicLink(atPath: directoryLink.path, withDestinationPath: actualDir.path)
        let unsafeDirectory = SPPlaybackDiagnostics(directory: directoryLink.appendingPathComponent("child"))
        unsafeDirectory.record(.snapshot, values: [:])
        await unsafeDirectory.flush()
        check(try files.contentsOfDirectory(atPath: actualDir.path).isEmpty, "A symlink path component is never traversed")

        let nonDirectory = root.appendingPathComponent("not-a-directory")
        try victimData.write(to: nonDirectory)
        let unavailable = SPPlaybackDiagnostics(directory: nonDirectory.appendingPathComponent("child"))
        unavailable.record(.snapshot, values: [:])
        await unavailable.flush()
        unavailable.record(.snapshot, values: [:])
        await unavailable.flush()
        check(try Data(contentsOf: nonDirectory) == victimData, "An unavailable directory silently disables logging without changing playback inputs")

        let fifoDir = root.appendingPathComponent("fifo")
        try files.createDirectory(at: fifoDir, withIntermediateDirectories: true)
        check(Darwin.mkfifo(fifoDir.appendingPathComponent(".lock").path, 0o600) == 0, "Owned FIFO fixture is created")
        let fifoLogger = SPPlaybackDiagnostics(directory: fifoDir)
        fifoLogger.record(.snapshot, values: [:])
        await fifoLogger.flush()
        check(!files.fileExists(atPath: fifoDir.appendingPathComponent("session.jsonl").path), "A FIFO lock cannot block the writer or create a log")

        let bridgeDir = root.appendingPathComponent("http-bridge")
        let bridgeName = Notification.Name("OwnedPlaybackDiagnosticTest-\(UUID())")
        var bridge: SPPlaybackDiagnostics? = SPPlaybackDiagnostics(directory: bridgeDir, notificationName: bridgeName)
        let secondWindow = SPPlaybackDiagnostics(sharingWriterWith: bridge!)
        check(!files.fileExists(atPath: bridgeDir.path), "Installing the observer does no filesystem work")
        for phase: Int64 in 1...3 {
            NotificationCenter.default.post(name: bridgeName, object: nil,
                userInfo: httpRangePayload(phase: phase, result: phase == 1 ? 0 : -1_094_995_529, attempt: phase))
        }
        await bridge!.flush()
        let phases = try rows(bridgeDir)
        check(phases.count == 3 && phases.map { number($0, "rangePhase") } == [1, 2, 3],
              "Each of the three native read phases becomes exactly one numerical record")
        check(phases.allSatisfy { number($0, "event") == 6 && number($0, "window") == 0 && $0.values.allSatisfy(numerical) },
              "Background read events share the bounded numerical writer with no guessed player window")
        check(number(phases[2], "rangeResult") == -1_094_995_529 && number(phases[2], "rangeRequestCount") == 262_144 &&
              number(phases[2], "rangeCount") == 0, "Signed native errors and request bytes do not collide with the cache interval count")
        check(phases.allSatisfy { $0["reader"] == nil && $0["start"] == nil && $0["count"] == nil && $0["url"] == nil },
              "The bridge maps only the fixed typed numerical fields, never arbitrary producer keys")
        var malformed: [[AnyHashable: Any]] = []
        for value: Any in [NSNumber(value: true), NSNumber(value: Double(1)), "42", NSNull(), NSNumber(value: UInt64.max)] {
            var input = httpRangePayload(); input["reader"] = value; malformed.append(input)
        }
        for (key, values): (String, [Int64]) in [
            ("reader", [0, -1]), ("start", [-1]), ("count", [0, -1, 262_145]),
            ("waitMs", [-1]), ("phase", [0, 4]), ("attempt", [0, 4])
        ] {
            for value in values {
                var input = httpRangePayload(); input[key] = NSNumber(value: value); malformed.append(input)
            }
        }
        var missing = httpRangePayload(); missing.removeValue(forKey: "count"); malformed.append(missing)
        var extra = httpRangePayload(); extra["url"] = "must never reach a log"; malformed.append(extra)
        var nonStringKey = httpRangePayload(); nonStringKey.removeValue(forKey: "count"); nonStringKey[123] = 10; malformed.append(nonStringKey)
        for input in malformed { NotificationCenter.default.post(name: bridgeName, object: nil, userInfo: input) }
        NotificationCenter.default.post(name: bridgeName, object: NSObject(), userInfo: httpRangePayload())
        NotificationCenter.default.post(name: bridgeName, object: nil, userInfo: nil)
        await bridge!.flush()
        check(try rows(bridgeDir).count == 3, "Boolean, floating, string, unsigned overflow, bad bounds, missing/extra keys and nonnil object are rejected")
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                NotificationCenter.default.post(name: bridgeName, object: nil,
                    userInfo: httpRangePayload(phase: 3, result: -60, attempt: 2))
                continuation.resume()
            }
        }
        await bridge!.flush()
        check(try rows(bridgeDir).count == 4, "A native-thread notification reaches the writer without waiting for MainActor")
        bridge!.record(.state, values: [.state: 3])
        secondWindow.record(.state, values: [.state: 4])
        await bridge!.flush()
        let windows = try rows(bridgeDir).suffix(2)
        check(Set(windows.map { number($0, "window") }).count == 2 && Set(windows.map { number($0, "boot") }).count == 1,
              "Multiple player wrappers have distinct window IDs and share one boot/writer")
        bridge = nil
        NotificationCenter.default.post(name: bridgeName, object: nil, userInfo: httpRangePayload())
        await secondWindow.flush()
        check(try rows(bridgeDir).count == 7, "Sharing and releasing window wrappers never duplicates the process writer's observer")

        let defaultIsolatedDir = root.appendingPathComponent("no-test-observer")
        let defaultIsolated = SPPlaybackDiagnostics(directory: defaultIsolatedDir)
        NotificationCenter.default.post(name: bridgeName, object: nil, userInfo: httpRangePayload())
        await defaultIsolated.flush(); await secondWindow.flush()
        check(!files.fileExists(atPath: defaultIsolatedDir.path), "An injected writer never observes production or other tests by default")

        let bridgeBoundDir = root.appendingPathComponent("http-bounded")
        let bridgeBoundName = Notification.Name("OwnedBoundedPlaybackDiagnosticTest-\(UUID())")
        let blockedQueue = DispatchQueue(label: "test.playback-diagnostics.http-suspended")
        blockedQueue.suspend()
        let bridgeBounded = SPPlaybackDiagnostics(directory: bridgeBoundDir, writerQueue: blockedQueue,
                                                   notificationName: bridgeBoundName)
        for _ in 0..<1000 { NotificationCenter.default.post(name: bridgeBoundName, object: nil, userInfo: httpRangePayload()) }
        check(!files.fileExists(atPath: bridgeBoundDir.path), "A notification callback cannot write or encode logs while the utility writer is blocked")
        blockedQueue.resume(); await bridgeBounded.flush()
        let bridgeAdmitted = try rows(bridgeBoundDir)
        check(bridgeAdmitted.count == 32 && bridgeAdmitted.map { number($0, "dropped") }.reduce(0, +) == 968,
              "Native read notifications use the same 32-record admission bound and numerical drop counter")

        let bridgeRotationDir = root.appendingPathComponent("http-rotation")
        let bridgeRotationName = Notification.Name("OwnedRotatingPlaybackDiagnosticTest-\(UUID())")
        let bridgeRotation = SPPlaybackDiagnostics(directory: bridgeRotationDir, maximumFileBytes: 1024,
                                                     notificationName: bridgeRotationName)
        for _ in 0..<15 {
            NotificationCenter.default.post(name: bridgeRotationName, object: nil, userInfo: httpRangePayload())
            await bridgeRotation.flush()
        }
        let rotatedNames = try files.contentsOfDirectory(atPath: bridgeRotationDir.path).filter { $0.hasSuffix(".jsonl") }
        check(Set(rotatedNames) == ["session.jsonl", "previous.jsonl"], "Native read records rotate into the existing two generations")
        for name in rotatedNames {
            let path = bridgeRotationDir.appendingPathComponent(name)
            check(try Data(contentsOf: path).count <= 1024 && mode(path) == 0o600,
                  "Native read logs preserve the byte cap and private permissions")
            check(try rows(bridgeRotationDir, name).allSatisfy { $0.values.allSatisfy(numerical) },
                  "Native read rotation preserves numerical-only JSON values")
        }
        let lifetimeDir = root.appendingPathComponent("http-lifetime")
        let lifetimeName = Notification.Name("OwnedLifetimePlaybackDiagnosticTest-\(UUID())")
        let lifetimeQueue = DispatchQueue(label: "test.playback-diagnostics.http-lifetime")
        var lifetime: SPPlaybackDiagnostics? = SPPlaybackDiagnostics(directory: lifetimeDir,
            writerQueue: lifetimeQueue, notificationName: lifetimeName)
        NotificationCenter.default.post(name: lifetimeName, object: nil, userInfo: httpRangePayload())
        await lifetime!.flush()
        lifetime = nil
        NotificationCenter.default.post(name: lifetimeName, object: nil, userInfo: httpRangePayload())
        await withCheckedContinuation { continuation in lifetimeQueue.async { continuation.resume() } }
        check(try rows(lifetimeDir).count == 1, "A released isolated writer removes its observer without retaining itself")
        print("PASS: \(checks) private playback diagnostics checks")
    }
}

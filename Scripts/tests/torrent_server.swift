import Foundation

@MainActor
private final class TorrentConfigurationBox {
    var value = SPTorrentConfiguration(cacheSizeMiB: 256)
}

@main @MainActor
struct TorrentServerChecks {
    static var assertions = 0
    static var ownedServer: SPTorrentServer?
    static var cacheChanges = 0
    static func main() async {
        setbuf(stdout, nil)
        do { try await run() }
        catch {
            ownedServer?.shutdown()
            print("FAIL: \(error.localizedDescription)")
            try? await Task.sleep(for: .seconds(1))
            exit(1)
        }
    }
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { print("FAIL: \(message)"); ownedServer?.shutdown(); exit(1) }
        assertions += 1
        print("PASS \(assertions): \(message)")
    }
    static func wait(_ predicate: @MainActor () -> Bool, timeout: Double = 3) async throws -> Bool {
        let limit = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < limit {
            if predicate() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }
    static func link(_ index: Int, mode: String = "Movie") -> String {
        "magnet:?xt=urn:btih:" + String(format: "%040x", index) + "&dn=" + mode
    }
    static func run() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Pass the protocol-fixture executable path") }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("khua-torrent-client-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let server = SPTorrentServer(workerURL: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: false),
                                    temporaryDirectory: scratch, metadataTimeout: 0.5, idleTimeout: 0.1,
                                    peerDiscoveryEnabled: false, settingsProvider: { SPTorrentConfiguration() })
        ownedServer = server
        defer { server.shutdown(); ownedServer = nil }
        do { _ = try await server.add(magnet: "https://invalid.example/torrent"); check(false, "non-magnet is rejected") }
        catch SPTorrentServerError.invalidInput { check(!server.isRunning, "invalid input never launches worker") }
        do { _ = try await server.add(magnet: link(1, mode: "badid")); check(false, "missing file ID is rejected") }
        catch SPTorrentServerError.invalidResponse { check(server.activeTorrentCount == 0, "missing authoritative ID is rejected before lease creation") }
        do { _ = try await server.add(magnet: link(2, mode: "duplicate")); check(false, "duplicate file IDs are rejected") }
        catch SPTorrentServerError.invalidResponse { check(server.activeTorrentCount == 0, "duplicate server file IDs are rejected") }
        do { _ = try await server.add(magnet: link(3, mode: "timeout")); check(false, "metadata timeout is reported") }
        catch SPTorrentServerError.metadataTimeout { check(server.activeTorrentCount == 0, "metadata timeout leaves no phantom lease") }
        let first = Task { try await server.add(magnet: link(4, mode: "timeout")) }
        try await Task.sleep(for: .milliseconds(100))
        let queued = Task { try await server.add(magnet: link(5)) }
        try await Task.sleep(for: .milliseconds(30))
        queued.cancel()
        do { _ = try await queued.value; check(false, "cancelled queued add is rejected") }
        catch is CancellationError { check(true, "queued cancellation resumes promptly without acquiring a lease") }
        do { _ = try await first.value; check(false, "active metadata request still times out") }
        catch SPTorrentServerError.metadataTimeout { check(true, "queued cancellation preserves the active add operation") }
        let interrupted = Task { try await server.add(magnet: link(6, mode: "timeout")) }
        try await Task.sleep(for: .milliseconds(100))
        let waiting = Task { try await server.add(magnet: link(7)) }
        try await Task.sleep(for: .milliseconds(30))
        server.shutdown()
        do { _ = try await waiting.value; check(false, "shutdown rejects pending add") }
        catch is CancellationError { check(true, "shutdown releases queued continuations") }
        do { _ = try await interrupted.value; check(false, "shutdown ends active metadata lookup") }
        catch { check(true, "shutdown invalidates active metadata lookup") }
        try await Task.sleep(for: .milliseconds(300))
        check(!server.isRunning && server.activeTorrentCount == 0, "queued work cannot restart a shutdown worker")
        let descriptor = try await server.add(magnet: link(8))
        check(server.isRunning && descriptor.files.first?.id == 7, "fresh explicit open restarts worker and preserves nonsequential server ID")
        let file = descriptor.files[0]
        let url = try server.streamURL(hash: descriptor.hash, file: file)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        check(components.queryItems?.first(where: { $0.name == "index" })?.value == "7" && components.user != nil && components.password != nil,
              "stream URL carries exact server ID and private credentials")
        let status = try await server.status(hash: descriptor.hash)
        check(status.bufferedBytes == 65536 && status.bufferCapacityBytes == 128 * 1024 * 1024 && status.downloadBytesPerSecond == 128000,
              "status exposes actual byte and rate metrics without per-piece requests")
        let retained = try server.retain(descriptor)
        server.release(descriptor)
        server.release(descriptor)
        _ = try await server.status(hash: retained.hash)
        check(server.activeTorrentCount == 1 && descriptor.leaseID != retained.leaseID, "release is idempotent and cannot drop another owner")
        do { _ = try server.streamURL(hash: retained.hash, file: SPTorrentFile(id: 1, path: file.path, length: file.length)); check(false, "invented ID rejected") }
        catch SPTorrentServerError.invalidFile { check(true, "invented client file ID cannot start a stream") }
        do { try await server.remove(hash: retained.hash); check(false, "leased torrent cannot be removed") }
        catch SPTorrentServerError.invalidLease { check(true, "explicit removal cannot interrupt another owner") }
        server.release(retained)
        check(try await wait({ server.activeTorrentCount == 0 }), "last owner releases torrent slot")
        let metainfo = Data("d4:infod4:name5:Movieee".utf8)
        let metainfoHash = try SPTorrentInput.infoHash(in: metainfo)
        let originalMagnet = "magnet:?xt=urn:btih:" + metainfoHash
        let magnetOwner = try await server.add(magnet: originalMagnet)
        check(magnetOwner.originalTorrentData == nil && magnetOwner.originalLink == originalMagnet,
              "magnet descriptor retains only its original source")
        let sourceURL = scratch.appendingPathComponent("original.torrent", isDirectory: false)
        try metainfo.write(to: sourceURL)
        let upgraded = try await server.add(torrentFile: sourceURL)
        try FileManager.default.removeItem(at: sourceURL)
        check(upgraded.originalTorrentData == metainfo && upgraded.originalLink == originalMagnet && server.activeTorrentCount == 1,
              "duplicate metainfo open upgrades shared source without replacing player leases")
        let newOwner = try server.retain(magnetOwner)
        check(newOwner.originalTorrentData == metainfo,
              "retained lease carries original bytes after source file deletion")
        server.release(magnetOwner); server.release(upgraded); server.release(newOwner)
        check(try await wait({ server.activeTorrentCount == 0 }), "upgraded source leases release normally")
        let slow = try await server.add(magnet: link(9, mode: "slow"))
        let destination = scratch.appendingPathComponent("whole.mp4", isDirectory: false)
        var closedOwner = false
        var sawProgress = false
        _ = try await server.saveFile(slow, file: slow.files[0], to: destination) { progress in
            sawProgress = progress.receivedBytes > 0
            if !closedOwner { closedOwner = true; server.release(slow) }
        }
        let expected = Data((0..<4096).flatMap { _ in Array(UInt8.min...UInt8.max) })
        check(try sawProgress && closedOwner && Data(contentsOf: destination) == expected,
              "download owns a lease after the player closes and writes exact authenticated bytes")
        check(try await wait({ server.activeTorrentCount == 0 && !server.isRunning }), "completed save releases its last lease and idle worker")
        let cancelledOwner = try await server.add(magnet: link(10, mode: "slow"))
        let cancelledDestination = scratch.appendingPathComponent("cancelled.mp4", isDirectory: false)
        var received = false
        let saving = Task { try await server.saveFile(cancelledOwner, file: cancelledOwner.files[0], to: cancelledDestination) { progress in
            if progress.receivedBytes > 0 { received = true }
        } }
        check(try await wait({ received }), "slow save actually starts before cancellation")
        saving.cancel()
        do { _ = try await saving.value; check(false, "active download cancellation reported") }
        catch { check(!FileManager.default.fileExists(atPath: cancelledDestination.path), "active cancellation leaves no partial destination") }
        _ = try await server.status(hash: cancelledOwner.hash)
        check(server.activeDownloadCount == 0 && server.activeTorrentCount == 1, "cancelled download releases only its own lease")
        server.release(cancelledOwner)
        check(try await wait({ server.activeTorrentCount == 0 && !server.isRunning }), "final player close stops worker")
        check(try await wait({ (try? FileManager.default.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("KhuaTorrent-") }.isEmpty) == true }), "all owned worker state directories are removed")
        try await cacheConfigurationChecks(fixture: CommandLine.arguments[1], scratch: scratch)
        try await startupConfigurationChecks(fixture: CommandLine.arguments[1], scratch: scratch)
        try await explicitCacheRestartChecks(fixture: CommandLine.arguments[1], scratch: scratch)
        try await retirementShutdownChecks(fixture: CommandLine.arguments[1], scratch: scratch)
        try await playbackWindowChecks(fixture: CommandLine.arguments[1], scratch: scratch)
        try await prefetchCapacityProofChecks(fixture: CommandLine.arguments[1], scratch: scratch)
        print("Torrent server protocol checks passed (\(assertions) assertions).")
    }

    static func cacheConfigurationChecks(fixture: String, scratch: URL) async throws {
        let directory = scratch.appendingPathComponent("cache-checks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "khua.torrent-server-cache-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let notifications = NotificationCenter()
        func desired(_ size: Int) {
            SPTorrentPreferences.setCacheSizeMiB(size, defaults: defaults, notifications: notifications)
        }
        desired(256)
        let server = SPTorrentServer(workerURL: URL(fileURLWithPath: fixture), temporaryDirectory: directory,
                                    idleTimeout: 30, peerDiscoveryEnabled: false,
                                    settingsProvider: { SPTorrentPreferences.configuration(defaults: defaults) },
                                    notifications: notifications)
        ownedServer = server
        defer { server.shutdown() }
        let token = notifications.addObserver(forName: SPTorrentServer.cacheConfigurationDidChangeNotification,
                                              object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { cacheChanges += 1 }
        }
        defer { notifications.removeObserver(token) }
        func events() -> [[String: Any]] {
            guard let data = try? String(contentsOf: directory.appendingPathComponent("fixture-events.jsonl"),
                                         encoding: .utf8) else { return [] }
            return data.split(separator: "\n").compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            }
        }
        func starts() -> [[String: Any]] { events().filter { $0["kind"] as? String == "start" } }
        check(server.effectiveCacheSizeBytes == nil && !server.hasPendingCacheChange,
              "An idle server has no effective worker configuration")
        let first = try await server.add(magnet: link(30))
        let originalURL = try server.streamURL(hash: first.hash, file: first.files[0])
        let duplicate = try await server.add(magnet: link(30))
        check(server.activeTorrentCount == 1 && starts().count == 1,
              "Two leases of one hash share one configured cache and worker")
        check(cacheChanges == 1, "A ready worker publishes its effective cache state without polling")
        check(starts().first?["cacheSize"] as? Int64 == 256 * 1024 * 1024,
              "The worker reads the selected binary cache size from settings.json at launch")
        desired(512)
        let activeStatus = try await server.status(hash: first.hash)
        check(server.hasPendingCacheChange && server.effectiveCacheSizeBytes == 256 * 1024 * 1024
              && activeStatus.bufferCapacityBytes == 256 * 1024 * 1024,
              "Changing desired cache preserves the active worker's effective capacity")
        check(cacheChanges == 1, "A pending preference does not advertise a changed worker configuration")
        check(try server.streamURL(hash: first.hash, file: first.files[0]) == originalURL,
              "A desired cache change preserves an existing authenticated stream URL")
        desired(256)
        check(!server.hasPendingCacheChange && starts().count == 1,
              "Returning to the active setting clears pending state without a restart")
        desired(512)
        server.release(first)
        _ = try await server.status(hash: duplicate.hash)
        check(server.activeTorrentCount == 1 && starts().count == 1,
              "Closing one shared owner does not apply settings or interrupt the second owner")
        let other = try await server.add(magnet: link(31))
        check(try await server.status(hash: other.hash).bufferCapacityBytes == 256 * 1024 * 1024
              && server.activeTorrentCount == 2 && starts().count == 1,
              "New torrents join the existing worker's immutable configuration while leases remain")
        server.release(duplicate)
        server.release(other)
        check(try await wait({ !server.isRunning && server.activeTorrentCount == 0 }),
              "The final lease close retires a worker with pending configuration")
        let slow = try await server.add(magnet: link(32, mode: "slow"))
        check(server.effectiveCacheSizeBytes == 512 * 1024 * 1024
              && starts().last?["cacheSize"] as? Int64 == 512 * 1024 * 1024 && !server.hasPendingCacheChange,
              "The next worker uses the fresh desired configuration")
        let destination = directory.appendingPathComponent("saved.mp4")
        var received = false
        let saving = Task { try await server.saveFile(slow, file: slow.files[0], to: destination) { progress in
            if progress.receivedBytes > 0 { received = true }
        } }
        check(try await wait({ received }), "A real authenticated save starts before changing its cache preference")
        desired(1024)
        server.release(slow)
        check(server.activeDownloadCount == 1 && server.activeTorrentCount == 1 && server.hasPendingCacheChange,
              "A save keeps its independent lease after the player closes")
        check(try await server.status(hash: slow.hash).bufferCapacityBytes == 512 * 1024 * 1024,
              "An in-flight save keeps the old worker and its effective capacity")
        _ = try await saving.value
        check(try Data(contentsOf: destination) == Data((0..<4096).flatMap { _ in Array(UInt8.min...UInt8.max) }),
              "Deferring the new setting preserves every saved byte")
        check(try await wait({ !server.isRunning && server.activeTorrentCount == 0 }),
              "Completing the final save permits configuration replacement")
        let closing = try await server.add(magnet: link(33))
        check(server.effectiveCacheSizeBytes == 1024 * 1024 * 1024,
              "A worker opened after the save uses its newly desired capacity")
        desired(2048)
        let barrier = directory.appendingPathComponent("hold-rem-" + closing.hash)
        try Data().write(to: barrier)
        server.release(closing)
        check(try await wait({ FileManager.default.fileExists(atPath: directory.appendingPathComponent("rem-started-" + closing.hash).path) }),
              "The last torrent's removal holds the add lock across a worker request")
        let queued = Task { try await server.add(magnet: link(34)) }
        try await Task.sleep(for: .milliseconds(30))
        desired(128)
        try FileManager.default.removeItem(at: barrier)
        let next = try await queued.value
        check(server.activeTorrentCount == 1 && server.effectiveCacheSizeBytes == 128 * 1024 * 1024,
              "Queued opens survive configuration replacement and read the latest desired size")
        _ = try await server.status(hash: next.hash)
        server.release(next)
        check(try await wait({ server.activeTorrentCount == 0 }) && server.isRunning,
              "An unchanged worker remains available through its ordinary idle timeout")
        desired(2048)
        check(!server.isRunning && server.effectiveCacheSizeBytes == nil,
              "A setting changed with no owners retires the idle worker immediately")
        let final = try await server.add(magnet: link(35))
        check(try await server.status(hash: final.hash).bufferCapacityBytes == 2048 * 1024 * 1024
              && starts().last?["cacheSize"] as? Int64 == 2048 * 1024 * 1024,
              "The largest supported setting reaches the next worker and its status")
        check(events().filter { $0["kind"] as? String == "start" }.count == 5,
              "Each safe configuration boundary starts exactly one replacement worker")
        check(!events().contains { $0["path"] as? String == "/settings" },
              "No cache preference change calls the destructive live settings endpoint")
        check(cacheChanges == 11, "Worker starts, retirements and save ownership changes publish effective cache state")
        server.release(final)
    }

    static func startupConfigurationChecks(fixture: String, scratch: URL) async throws {
        let directory = scratch.appendingPathComponent("startup-cache-checks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "khua.torrent-startup-cache-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let notifications = NotificationCenter()
        let server = SPTorrentServer(workerURL: URL(fileURLWithPath: fixture), temporaryDirectory: directory,
                                    idleTimeout: 30, peerDiscoveryEnabled: false,
                                    settingsProvider: { SPTorrentPreferences.configuration(defaults: defaults) },
                                    notifications: notifications)
        ownedServer = server
        defer { server.shutdown() }
        let barrier = directory.appendingPathComponent("hold-echo")
        try Data().write(to: barrier)
        let opening = Task { try await server.add(magnet: link(40)) }
        check(try await wait({ FileManager.default.fileExists(atPath: directory.appendingPathComponent("echo-started").path) }),
              "The fixture pauses worker readiness after reading its startup configuration")
        SPTorrentPreferences.setCacheSizeMiB(256, defaults: defaults, notifications: notifications)
        SPTorrentPreferences.setCacheSizeMiB(512, defaults: defaults, notifications: notifications)
        check(server.effectiveCacheSizeBytes == 128 * 1024 * 1024 && server.hasPendingCacheChange,
              "Desired changes during startup do not mutate or cancel the worker being prepared")
        try FileManager.default.removeItem(at: barrier)
        let first = try await opening.value
        check(try await server.status(hash: first.hash).bufferCapacityBytes == 128 * 1024 * 1024,
              "The first accepted lease retains the worker's original startup snapshot")
        server.release(first)
        check(try await wait({ !server.isRunning && server.activeTorrentCount == 0 }),
              "Closing the startup lease permits the deferred configuration change")
        let next = try await server.add(magnet: link(41))
        check(try await server.status(hash: next.hash).bufferCapacityBytes == 512 * 1024 * 1024
              && !server.hasPendingCacheChange,
              "The next safe startup uses the latest desired value, skipping obsolete intermediate sizes")
        server.release(next)
    }

    static func explicitCacheRestartChecks(fixture: String, scratch: URL) async throws {
        let directory = scratch.appendingPathComponent("explicit-cache-restart-checks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = TorrentConfigurationBox()
        let server = SPTorrentServer(workerURL: URL(fileURLWithPath: fixture), temporaryDirectory: directory,
                                    metadataTimeout: 0.5, idleTimeout: 30, peerDiscoveryEnabled: false,
                                    settingsProvider: { configuration.value }, notifications: NotificationCenter())
        ownedServer = server
        defer { server.shutdown() }
        try await server.prepareForCacheRestart()
        check(!server.isRunning && !server.hasActiveTorrentOperation,
              "Preparing an idle cache restart never launches a worker")
        let first = try await server.add(magnet: link(50))
        let oldURL = try server.streamURL(hash: first.hash, file: first.files[0])
        configuration.value = SPTorrentConfiguration(cacheSizeMiB: 512)
        do {
            try await server.prepareForCacheRestart()
            check(false, "Restart must reject a playback lease not closed by the coordinator")
        } catch SPTorrentServerError.cacheRestartBusy {
            check(try await server.status(hash: first.hash).bufferCapacityBytes == 256 * 1024 * 1024
                  && server.isRunning, "Refusing a restart preserves every active playback lease")
        }
        let terminationDelay = directory.appendingPathComponent("termination-delay-ms")
        try Data("300".utf8).write(to: terminationDelay)
        let closingAt = ProcessInfo.processInfo.systemUptime
        server.release(first)
        try await server.prepareForCacheRestart(timeout: 10)
        check(!server.isRunning && server.activeTorrentCount == 0 && server.effectiveCacheSizeBytes == nil,
              "A coordinated restart clears unowned records without starting the replacement session")
        check(ProcessInfo.processInfo.systemUptime - closingAt >= 0.25,
              "Explicit restart waits for the retired process to exit before returning")
        try FileManager.default.removeItem(at: terminationDelay)
        do { _ = try server.retain(first); check(false, "A previous session lease cannot be retained") }
        catch SPTorrentServerError.invalidLease {
            check(true, "Restarted sessions reject old descriptor leases")
        }
        let reopened = try await server.add(magnet: link(50, mode: "slow"))
        let reopenedURL = try server.streamURL(hash: reopened.hash, file: reopened.files[0])
        check(reopened.leaseID != first.leaseID && server.effectiveCacheSizeBytes == 512 * 1024 * 1024
              && reopenedURL != oldURL,
              "Explicit reopening creates a fresh lease and stream with the selected cache size")
        let destination = directory.appendingPathComponent("restart-save.mp4")
        var received = false
        let saving = Task { try await server.saveFile(reopened, file: reopened.files[0], to: destination) { progress in
            if progress.receivedBytes > 0 { received = true }
        } }
        check(try await wait({ received }), "The independent file save is active before requesting an explicit restart")
        server.release(reopened)
        configuration.value = SPTorrentConfiguration(cacheSizeMiB: 1024)
        do { try await server.prepareForCacheRestart(); check(false, "A save must block explicit restart") }
        catch SPTorrentServerError.cacheRestartBusy {
            check(server.activeDownloadCount == 1 && server.isRunning
                  && server.effectiveCacheSizeBytes == 512 * 1024 * 1024,
                  "Explicit cache restart never cancels an independently leased file save")
        }
        _ = try await saving.value
        check(try Data(contentsOf: destination) == Data((0..<4096).flatMap { _ in Array(UInt8.min...UInt8.max) }),
              "A save blocked from restart still writes every authenticated byte")
        try await server.prepareForCacheRestart()
        let closed = try await server.add(magnet: link(51))
        let barrier = directory.appendingPathComponent("hold-rem-" + closed.hash)
        try Data().write(to: barrier)
        server.release(closed)
        check(try await wait({ FileManager.default.fileExists(atPath: directory.appendingPathComponent("rem-started-" + closed.hash).path) }),
              "A deterministic cleanup operation holds the lock before bounded restart")
        check(server.hasActiveTorrentOperation, "The coordinator can observe in-flight torrent cleanup")
        let waitingRestart = Task { try await server.prepareForCacheRestart(timeout: 0.05) }
        do { try await waitingRestart.value; check(false, "Restart must not wait indefinitely for cleanup") }
        catch SPTorrentServerError.cacheRestartBusy {
            check(server.isRunning && server.hasActiveTorrentOperation,
                  "A bounded restart timeout leaves the existing operation untouched")
        }
        let cancelledRestart = Task { try await server.prepareForCacheRestart() }
        try await Task.sleep(for: .milliseconds(20))
        cancelledRestart.cancel()
        do { try await cancelledRestart.value; check(false, "Cancelling a waiting restart must finish promptly") }
        catch is CancellationError { check(true, "Restart cancellation does not cancel the active cleanup") }
        let queued = Task { try await server.add(magnet: link(52)) }
        let racingRestart = Task { try await server.prepareForCacheRestart() }
        try await Task.sleep(for: .milliseconds(20))
        try FileManager.default.removeItem(at: barrier)
        let independent = try await queued.value
        do { try await racingRestart.value; check(false, "A newly opened independent lease must block restart") }
        catch SPTorrentServerError.cacheRestartBusy {
            _ = try await server.status(hash: independent.hash)
            check(server.activeTorrentCount == 1,
                  "A queued independent open survives a racing restart without lease eviction")
        }
        server.release(independent)
        try await server.prepareForCacheRestart()
        let refuse = directory.appendingPathComponent("refuse-start")
        try Data().write(to: refuse)
        do { _ = try await server.add(magnet: link(53)); check(false, "The replacement worker failure must be surfaced") }
        catch {
            check(!server.isRunning && server.activeTorrentCount == 0,
                  "A failed replacement session leaves no worker or phantom lease")
        }
        try FileManager.default.removeItem(at: refuse)
        let recovered = try await server.add(magnet: link(53))
        check(server.isRunning && server.effectiveCacheSizeBytes == 1024 * 1024 * 1024,
              "A later explicit open can recover from replacement worker failure")
        server.release(recovered)
        try await server.prepareForCacheRestart()
        let metainfo = Data("d4:infod4:name5:Movieee".utf8)
        let uploaded = try await server.add(torrentData: metainfo)
        let metainfoHash = try SPTorrentInput.infoHash(in: metainfo)
        check(uploaded.originalTorrentData == metainfo && uploaded.hash == metainfoHash,
              "Retained metainfo opens directly from memory without its original file")
        server.release(uploaded)
        try await server.prepareForCacheRestart()
        let reopenedData = try await server.add(torrentData: uploaded.originalTorrentData!)
        check(reopenedData.hash == uploaded.hash && reopenedData.leaseID != uploaded.leaseID,
              "A cache restart can reopen the exact retained torrent as a fresh session")
        server.release(reopenedData)
        try await server.prepareForCacheRestart()
        do { _ = try await server.add(torrentData: Data([0])); check(false, "Invalid retained metainfo must be rejected") }
        catch SPTorrentInputError.invalidTorrent {
            check(!server.isRunning, "Invalid retained data never starts a worker")
        }
        do { _ = try await server.add(torrentData: Data(count: 32 * 1024 * 1024 + 1)); check(false, "Oversized retained metainfo must be rejected") }
        catch SPTorrentInputError.tooLarge {
            check(!server.isRunning, "In-memory metainfo keeps the same 32 MiB safety limit")
        }
        let cancelledDataOpen = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await server.add(torrentData: metainfo)
        }
        do { _ = try await cancelledDataOpen.value; check(false, "Cancelled retained source open must not start") }
        catch is CancellationError {
            check(!server.isRunning, "A cancelled retained-source request cannot launch or acquire a lease")
        }
    }

    static func retirementShutdownChecks(fixture: String, scratch: URL) async throws {
        let directory = scratch.appendingPathComponent("retirement-shutdown-checks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("500".utf8).write(to: directory.appendingPathComponent("termination-delay-ms"))
        let configuration = TorrentConfigurationBox()
        let server = SPTorrentServer(workerURL: URL(fileURLWithPath: fixture), temporaryDirectory: directory,
                                    idleTimeout: 30, peerDiscoveryEnabled: false,
                                    settingsProvider: { configuration.value }, notifications: NotificationCenter())
        ownedServer = server
        defer { server.shutdown() }
        func events() -> [[String: Any]] {
            guard let text = try? String(contentsOf: directory.appendingPathComponent("fixture-events.jsonl"),
                                         encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            }
        }
        let first = try await server.add(magnet: link(60))
        configuration.value = SPTorrentConfiguration(cacheSizeMiB: 512)
        server.release(first)
        check(try await wait({ !server.isRunning && server.activeTorrentCount == 0 }),
              "Configuration rotation can outlive its logical worker while the process exits")
        let waitingOpen = Task { try await server.add(magnet: link(61)) }
        check(try await wait({ server.hasActiveTorrentOperation }),
              "An explicit open waits for the retiring worker before starting a replacement")
        server.shutdown()
        do { _ = try await waitingOpen.value; check(false, "A shutdown must invalidate an open waiting on retirement") }
        catch is CancellationError {
            check(!server.isRunning && server.activeTorrentCount == 0,
                  "A pending retirement cannot resurrect a worker after shutdown")
        }
        check(events().filter { $0["kind"] as? String == "start" }.count == 1,
              "Shutdown during retirement creates no hidden replacement process")
        let echoBarrier = directory.appendingPathComponent("hold-echo")
        try Data().write(to: echoBarrier)
        let opening = Task { try await server.add(magnet: link(62)) }
        check(try await wait({ FileManager.default.fileExists(atPath: directory.appendingPathComponent("echo-started").path) }),
              "A startup can be cancelled while its child process is already running")
        let cancellingAt = ProcessInfo.processInfo.systemUptime
        opening.cancel()
        try FileManager.default.removeItem(at: echoBarrier)
        do { _ = try await opening.value; check(false, "The cancelled startup must not acquire a lease") }
        catch { check(server.activeTorrentCount == 0, "Cancelled startup cleanup leaves no playback lease") }
        try await server.prepareForCacheRestart(timeout: 10)
        check(ProcessInfo.processInfo.systemUptime - cancellingAt >= 0.4
              && events().filter { $0["kind"] as? String == "stop" }.count == 2,
              "Restart preparation also waits for disposal of a cancelled startup child")
        _ = try await server.add(magnet: link(63))
        let shutdownAt = ProcessInfo.processInfo.systemUptime
        server.shutdown()
        try await server.prepareForCacheRestart(timeout: 10)
        check(ProcessInfo.processInfo.systemUptime - shutdownAt >= 0.4
              && events().filter { $0["kind"] as? String == "stop" }.count == 3,
              "Explicit shutdown disposal is tracked until its owned process exits")
        let final = try await server.add(magnet: link(64))
        check(server.isRunning && server.effectiveCacheSizeBytes == 512 * 1024 * 1024,
              "A fresh explicit open remains available after shutdown and retirement complete")
        let lifecycle = events().filter { ["start", "stop"].contains($0["kind"] as? String ?? "") }
            .compactMap { $0["kind"] as? String }
        check(lifecycle == ["start", "stop", "start", "stop", "start", "stop", "start"],
              "New workers start only after the preceding owned worker has exited")
        server.release(final)
        try await server.prepareForCacheRestart(timeout: 10)
    }

    static func prefetchCapacityProofChecks(fixture: String, scratch: URL) async throws {
        let directory = scratch.appendingPathComponent("prefetch-capacity-proof-checks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let server = SPTorrentServer(workerURL: URL(fileURLWithPath: fixture), temporaryDirectory: directory,
                                    peerDiscoveryEnabled: false, settingsProvider: { SPTorrentConfiguration() },
                                    notifications: NotificationCenter())
        ownedServer = server
        defer { server.shutdown() }
        let descriptor = try await server.add(magnet: link(71))
        let file = descriptor.files[0]
        let override = directory.appendingPathComponent("window-reply-override-" + descriptor.leaseID.uuidString + ".json")
        let requestID = UUID()
        var ackRevision: Int64 = 0
        func update(_ proof: Any?) async throws -> SPTorrentPlaybackWindow {
            ackRevision += 1
            if let proof {
                try JSONSerialization.data(withJSONObject: ["prefetch_stop": proof]).write(to: override, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: override)
            }
            return try await server.updatePlaybackWindow(descriptor, file: file,
                historyLowerBound: 0, playbackOffset: 262144, forwardUpperBound: file.length)
        }
        func proof(_ changes: [String: Any] = [:]) -> [String: Any] {
            var value: [String: Any] = ["reason": "capacity", "request_id": requestID.uuidString,
                "file_index": file.id, "range_start": Int64(131072), "range_end": file.length,
                "next_offset": Int64(524288), "revision": ackRevision + 1]
            value.merge(changes) { _, replacement in replacement }
            return value
        }
        let absent = try await update(nil)
        check(absent.prefetchCapacityStop == nil, "An omitted prefetch stop carries no capacity proof")
        let null = try await update(NSNull())
        check(null.prefetchCapacityStop == nil, "A null prefetch stop carries no capacity proof")
        let valid = try await update(proof())
        check(valid.prefetchCapacityStop == SPTorrentPrefetchCapacityStop(requestID: requestID,
              fileID: file.id, rangeStart: 131072, rangeEnd: file.length, nextOffset: 524288, revision: ackRevision),
              "A valid capacity proof preserves its exact request, file, exclusive range and revision")
        check(valid.prefetchCapacityStop!.nextOffset > valid.forwardUpperBound,
              "A prior response's stop can lie beyond a later, smaller acknowledged cache window")
        let boundary = try await update(proof(["range_start": 0, "next_offset": 0, "revision": 1,
                                               "request_id": requestID.uuidString.lowercased()]))
        check(boundary.prefetchCapacityStop?.rangeStart == 0 && boundary.prefetchCapacityStop?.nextOffset == 0
              && boundary.prefetchCapacityStop?.rangeEnd == file.length && boundary.prefetchCapacityStop?.revision == 1
              && boundary.prefetchCapacityStop?.requestID == requestID,
              "Zero progress, EOF-exclusive range end and an older positive proof revision are valid bounds")

        let malformed: [(String, Any)] = [
            ("A scalar proof is rejected", "capacity"),
            ("An array proof is rejected", []),
            ("A missing capacity reason is rejected", proof(["reason": NSNull()])),
            ("An unrelated stop reason is rejected", proof(["reason": "transport"])),
            ("A malformed request nonce is rejected", proof(["request_id": "not-a-uuid"])),
            ("A non-string request nonce is rejected", proof(["request_id": 123])),
            ("A proof for another file is rejected", proof(["file_index": file.id + 1])),
            ("A negative range start is rejected", proof(["range_start": -1])),
            ("A start after the next offset is rejected", proof(["range_start": 524289])),
            ("A next offset at the exclusive range end is rejected", proof(["next_offset": file.length])),
            ("A next offset beyond the range end is rejected", proof(["next_offset": file.length + 1])),
            ("A range end beyond the file is rejected", proof(["range_end": file.length + 1])),
            ("A zero proof revision is rejected", proof(["revision": 0])),
            ("A negative proof revision is rejected", proof(["revision": -1])),
            ("A future proof revision is rejected", proof(["revision": Int64.max])),
            ("An overflowing proof offset is rejected", proof(["range_end": UInt64.max]))
        ]
        for (message, value) in malformed {
            do { _ = try await update(value); check(false, message) }
            catch SPTorrentServerError.invalidResponse { check(true, message) }
        }
        for field in ["file_index", "range_start", "range_end", "next_offset", "revision"] {
            for (suffix, value) in [("boolean", true as Any), ("fractional", 1.5 as Any),
                                    ("string", "1" as Any), ("missing", NSNull() as Any)] {
                do { _ = try await update(proof([field: value])); check(false, "A \(suffix) \(field) is rejected") }
                catch SPTorrentServerError.invalidResponse { check(true, "A \(suffix) \(field) is rejected") }
            }
        }
        let recovered = try await update(nil)
        check(recovered.prefetchCapacityStop == nil && server.activeTorrentCount == 1,
              "Malformed proof replies do not release the lease or prevent the next valid window")
        server.release(descriptor)
    }

    static func playbackWindowChecks(fixture: String, scratch: URL) async throws {
        let directory = scratch.appendingPathComponent("playback-window-checks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let server = SPTorrentServer(workerURL: URL(fileURLWithPath: fixture), temporaryDirectory: directory,
                                    peerDiscoveryEnabled: false, settingsProvider: { SPTorrentConfiguration() },
                                    notifications: NotificationCenter())
        ownedServer = server
        defer { server.shutdown() }
        func events() -> [[String: Any]] {
            guard let text = try? String(contentsOf: directory.appendingPathComponent("fixture-events.jsonl"),
                                         encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            }
        }
        let first = try await server.add(magnet: link(70))
        let second = try await server.add(magnet: link(70))
        let file = first.files[0]
        let managed = try server.streamURL(hash: first.hash, file: file, playbackConsumer: first.leaseID)
        let query = URLComponents(url: managed, resolvingAgainstBaseURL: false)?.queryItems
        check(query?.first(where: { $0.name == "playback_consumer" })?.value == first.leaseID.uuidString,
              "Playback and pause-fill URLs carry their exact lease consumer identity")
        do { _ = try server.streamURL(hash: first.hash, file: file, playbackConsumer: UUID()); check(false, "An invented consumer must not tag a playback stream") }
        catch SPTorrentServerError.invalidLease { check(true, "Managed stream identity requires an active lease of the same torrent") }
        let initial = try await server.updatePlaybackWindow(first, file: file, historyLowerBound: 131072,
                                                            playbackOffset: 262144, forwardUpperBound: file.length)
        check(initial.historyLowerBound == 131072 && initial.playbackOffset == 262144
              && initial.forwardUpperBound == 327680 && initial.pieceLength == 65536,
              "The client returns the worker's authoritative forward bound rather than its requested file end")
        let firstEvent = events().first { $0["kind"] as? String == "window" }
        check(firstEvent?["consumer"] as? String == first.leaseID.uuidString
              && firstEvent?["file_index"] as? Int == file.id && firstEvent?["revision"] as? Int == 1,
              "The authenticated window request uses authoritative file ID and its own monotonic consumer revision")
        do { _ = try await server.updatePlaybackWindow(first, file: file, historyLowerBound: 300000,
                                                       playbackOffset: 200000, forwardUpperBound: file.length)
            check(false, "A history lower bound beyond playback must not reach the worker")
        } catch SPTorrentServerError.invalidFile { check(true, "Invalid media-relative window bounds are rejected locally") }
        let barrier = directory.appendingPathComponent("hold-window-reply-" + first.leaseID.uuidString + "-2")
        try Data().write(to: barrier)
        let obsolete = Task { try await server.updatePlaybackWindow(first, file: file, historyLowerBound: 196608,
                                                                    playbackOffset: 327680, forwardUpperBound: file.length) }
        check(try await wait({ FileManager.default.fileExists(atPath: directory.appendingPathComponent("window-reply-started-" + first.leaseID.uuidString + "-2").path) }),
              "An older window response remains in flight across a seek boundary")
        server.invalidatePlaybackWindow(first)
        let removedDuringHandover = try await wait({ events().contains {
            $0["kind"] as? String == "window" && $0["consumer"] as? String == first.leaseID.uuidString
                && $0["remove"] as? Bool == true
        } }, timeout: 0.5)
        check(!removedDuringHandover,
              "A seek invalidates stale acknowledgements locally without removing the retained worker window")
        let latest = try await server.updatePlaybackWindow(first, file: file, historyLowerBound: 65536,
                                                           playbackOffset: 196608, forwardUpperBound: file.length)
        check(latest.playbackOffset == 196608 && latest.forwardUpperBound == 262144,
              "A post-seek window can replace the prior playback anchor without following the prefetch cursor")
        try FileManager.default.removeItem(at: barrier)
        do { _ = try await obsolete.value; check(false, "An obsolete acknowledgement must not revive its old window") }
        catch is CancellationError { check(true, "Late window acknowledgements are discarded after synchronous invalidation") }
        _ = try await server.updatePlaybackWindow(second, file: file, historyLowerBound: 524288,
                                                  playbackOffset: 655360, forwardUpperBound: file.length)
        check(events().contains { $0["kind"] as? String == "window" && $0["consumer"] as? String == second.leaseID.uuidString
              && $0["revision"] as? Int == 1 },
              "Two windows of the same torrent have independent consumer revisions and playback anchors")
        server.release(first)
        check(try await wait({ events().contains { $0["kind"] as? String == "window"
            && $0["consumer"] as? String == first.leaseID.uuidString && $0["remove"] as? Bool == true
            && ($0["revision"] as? Int ?? 0) > 4 } }),
              "Releasing a playback lease removes its own window without closing another consumer")
        _ = try await server.status(hash: second.hash)
        do { _ = try await server.updatePlaybackWindow(first, file: file, historyLowerBound: 0,
                                                       playbackOffset: 0, forwardUpperBound: file.length)
            check(false, "A released consumer must not restore a playback window")
        } catch SPTorrentServerError.invalidLease { check(true, "Released source identities cannot send new retention hints") }
        await server.clearPlaybackWindow(second)
        _ = try await server.updatePlaybackWindow(second, file: file, historyLowerBound: 0,
                                                  playbackOffset: 65536, forwardUpperBound: file.length)
        check(events().contains { $0["kind"] as? String == "window" && $0["consumer"] as? String == second.leaseID.uuidString
              && $0["revision"] as? Int == 3 && $0["remove"] == nil },
              "An explicit source clear keeps a revision tombstone while allowing a newer window for the live consumer")
        let boundary = try await server.updatePlaybackWindow(second, file: file, historyLowerBound: 200000,
                                                             playbackOffset: 200000, forwardUpperBound: file.length)
        check(boundary.historyLowerBound == 196608 && boundary.playbackOffset == 200000,
              "A current piece can overhang a strict history cutoff without accepting an extra older history piece")
        server.endPlaybackWindow(second)
        check(try await wait({ events().contains { $0["kind"] as? String == "window"
            && $0["consumer"] as? String == second.leaseID.uuidString && $0["remove"] as? Bool == true
            && $0["revision"] as? Int == 5 } }),
              "A terminal source explicitly removes retained ownership without waiting for lease release")
        check(server.activeTorrentCount == 1,
              "Ending a playback window preserves the source lease for retry and independent file saving")
        let destination = directory.appendingPathComponent("whole.mp4")
        _ = try await server.saveFile(second, file: file, to: destination)
        check(events().last(where: { $0["kind"] as? String == "stream" })?["consumer"] is NSNull,
              "A whole-file save remains an unmanaged direct HTTP reader and does not move the playback window")
        check(!events().contains { $0["path"] as? String == "/settings" },
              "Playback-window updates never call the destructive settings endpoint")
        server.release(second)
    }
}

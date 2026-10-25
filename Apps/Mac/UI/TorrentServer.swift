import Foundation
import CoreFoundation
import Darwin

enum SPTorrentServerError: LocalizedError {
    case workerMissing, workerUnavailable, invalidInput, noPlayableFiles, capacityReached
    case invalidLease, invalidFile, invalidResponse, http(Int), metadataTimeout
    case destinationExists, workerExited(Int32), cacheRestartBusy

    var errorDescription: String? {
        switch self {
        case .workerMissing: return "The bundled torrent worker is unavailable."
        case .workerUnavailable: return "The torrent worker could not start."
        case .invalidInput: return "The torrent or magnet link is invalid."
        case .noPlayableFiles: return "The torrent contains no supported media files."
        case .capacityReached: return "Four torrents are already active. Close one before opening another."
        case .invalidLease: return "This torrent session has ended."
        case .invalidFile: return "The requested file is not in this torrent."
        case .invalidResponse: return "The torrent worker returned an invalid response."
        case .http(let status): return "The torrent worker returned HTTP \(status)."
        case .metadataTimeout: return "Torrent metadata did not arrive in time."
        case .destinationExists: return "A file already exists at the selected destination."
        case .workerExited(let status): return "The torrent worker stopped (\(status))."
        case .cacheRestartBusy: return "Close active torrent sessions and wait for file saves or torrent operations to finish before restarting the cache."
        }
    }
}

struct SPTorrentDownloadProgress: Sendable {
    let receivedBytes: Int64
    let expectedBytes: Int64
    var fraction: Double? {
        expectedBytes > 0 ? min(1, max(0, Double(receivedBytes) / Double(expectedBytes))) : nil
    }
}

/// Identifies one bounded prefetch response stopped by the worker's capacity
/// policy. A bare HTTP close is not evidence that the cache window is full.
struct SPTorrentPrefetchCapacityStop: Equatable, Sendable {
    let requestID: UUID
    let fileID: Int
    let rangeStart: Int64
    let rangeEnd: Int64
    let nextOffset: Int64
    let revision: Int64
}

/// Authoritative file-relative byte window applied by the worker. Its upper
/// bound is exclusive and includes whole torrent pieces, never partial data
/// falsely advertised as a completed piece.
struct SPTorrentPlaybackWindow: Equatable, Sendable {
    let historyLowerBound: Int64
    let playbackOffset: Int64
    let forwardUpperBound: Int64
    let pieceLength: Int64
    let prefetchCapacityStop: SPTorrentPrefetchCapacityStop?

    init(historyLowerBound: Int64, playbackOffset: Int64, forwardUpperBound: Int64,
         pieceLength: Int64, prefetchCapacityStop: SPTorrentPrefetchCapacityStop? = nil) {
        self.historyLowerBound = historyLowerBound
        self.playbackOffset = playbackOffset
        self.forwardUpperBound = forwardUpperBound
        self.pieceLength = pieceLength
        self.prefetchCapacityStop = prefetchCapacityStop
    }
}

/// One private worker serves all player windows. A descriptor owns a unique
/// lease; releasing one window must not interrupt another or a whole-file save.
@MainActor
final class SPTorrentServer {
    static let shared = SPTorrentServer()
    nonisolated static let workerVersion = "MatriX.147-khua.5"
    /// Default for callers without an active worker; runtime status uses the
    /// configuration captured by the worker, never the desired preference.
    nonisolated static let cacheSizeBytes = SPTorrentConfiguration().cacheSizeBytes
    nonisolated static let maximumActiveTorrents = 4
    nonisolated static let didExitNotification = Notification.Name("SPTorrentServerDidExit")
    nonisolated static let cacheConfigurationDidChangeNotification = Notification.Name("SPTorrentCacheConfigurationDidChange")

    private struct Record {
        let hash: String
        let name: String
        let files: [SPTorrentFile]
        var originalLink: String?
        var originalTorrentData: Data?
        var leases: Set<UUID>
    }
    private struct Worker: Sendable {
        let process: Process
        let directory: URL
        let endpoint: URL
        let user: String
        let password: String
        let generation: UInt64
        let configuration: SPTorrentConfiguration
    }
    private struct AddWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }
    private struct PlaybackWindowRemoval: Sendable {
        let hash: String
        let consumer: UUID
        let revision: Int64
        let generation: UInt64
    }

    private let workerURL: URL?
    private let temporaryDirectory: URL
    private let session: URLSession
    private let metadataTimeout: TimeInterval
    private let idleTimeout: TimeInterval
    private let peerDiscoveryEnabled: Bool
    private let trackerListURL: URL?
    private let settingsProvider: @MainActor () -> SPTorrentConfiguration
    private let notifications: NotificationCenter
    nonisolated(unsafe) private var settingsObserver: (any NSObjectProtocol)?
    private var worker: Worker?
    private var generation: UInt64 = 0
    private var startTask: Task<Void, any Error>?
    private var keepaliveTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var records: [String: Record] = [:]
    private var leaseHashes: [UUID: String] = [:]
    private var adding = false
    private var addWaiters: [AddWaiter] = []
    private var downloads: [UUID: SPTorrentFileDownload] = [:]
    private var retirementTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var playbackConsumerRevisions: [UUID: Int64] = [:]

    var activeTorrentCount: Int { records.count }
    var activeDownloadCount: Int { downloads.count }
    var hasActiveTorrentOperation: Bool { adding || startTask != nil || !addWaiters.isEmpty }
    var isRunning: Bool { worker?.process.isRunning == true }
    var effectiveCacheSizeBytes: Int64? { isRunning ? worker?.configuration.cacheSizeBytes : nil }
    var hasPendingCacheChange: Bool {
        guard isRunning, let worker else { return false }
        return worker.configuration != settingsProvider()
    }

    init(workerURL: URL? = nil, temporaryDirectory: URL? = nil,
         session: URLSession? = nil, metadataTimeout: TimeInterval = 60,
         idleTimeout: TimeInterval = 15, peerDiscoveryEnabled: Bool = true,
         trackerListURL: URL? = nil,
         settingsProvider: @escaping @MainActor () -> SPTorrentConfiguration = { SPTorrentPreferences.configuration() },
         notifications: NotificationCenter = .default) {
        self.workerURL = workerURL ?? Bundle.main.url(forResource: "TorrServer", withExtension: nil, subdirectory: "Torrent")
        self.temporaryDirectory = temporaryDirectory ?? FileManager.default.temporaryDirectory
        self.session = session ?? URLSession(configuration: Self.sessionConfiguration())
        self.metadataTimeout = max(0.1, metadataTimeout)
        self.idleTimeout = max(0, idleTimeout)
        self.peerDiscoveryEnabled = peerDiscoveryEnabled
        self.trackerListURL = trackerListURL
        self.settingsProvider = settingsProvider
        self.notifications = notifications
        settingsObserver = notifications.addObserver(forName: SPTorrentPreferences.changed,
                                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
    }

    deinit {
        if let settingsObserver { notifications.removeObserver(settingsObserver) }
    }

    func add(magnet: String) async throws -> SPTorrentDescriptor {
        let link = magnet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hash = SPTorrentInput.magnetHash(link) else { throw SPTorrentServerError.invalidInput }
        return try await add(hash: hash, originalLink: link, torrentData: nil)
    }

    func add(torrentFile: URL) async throws -> SPTorrentDescriptor {
        guard torrentFile.isFileURL else { throw SPTorrentServerError.invalidInput }
        let input = try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: torrentFile)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 32 * 1024 * 1024 + 1) ?? Data()
            return (data, try SPTorrentInput.infoHash(in: data))
        }.value
        try Task.checkCancellation()
        return try await add(hash: input.1, originalLink: nil, torrentData: input.0)
    }

    /// Reopens retained metainfo without requiring the original .torrent file
    /// or writing a temporary copy. Validation uses the same bounded parser.
    func add(torrentData: Data) async throws -> SPTorrentDescriptor {
        try Task.checkCancellation()
        let hash = try await Task.detached(priority: .utility) {
            try SPTorrentInput.infoHash(in: torrentData)
        }.value
        try Task.checkCancellation()
        return try await add(hash: hash, originalLink: nil, torrentData: torrentData)
    }

    /// Each successful call owns one lease, including repeated opens of the
    /// same hash. Cache slots are charged per distinct torrent, not per window.
    private func add(hash: String, originalLink: String?, torrentData: Data?) async throws -> SPTorrentDescriptor {
        try await acquireAddLock()
        defer { releaseAddLock(); scheduleIdleStop() }
        try Task.checkCancellation()
        idleTask?.cancel()
        try await ensureRunning()
        try Task.checkCancellation()
        if var existing = records[hash], isRunning {
            // A later .torrent open can supply durable metainfo for an existing
            // magnet session without replacing its worker or its other leases.
            if existing.originalLink == nil { existing.originalLink = originalLink }
            if existing.originalTorrentData == nil { existing.originalTorrentData = torrentData }
            return lease(existing)
        }
        if records.count >= Self.maximumActiveTorrents {
            // A window can close and open another torrent in the same event
            // turn, before its asynchronous release cleanup acquires this lock.
            for staleHash in records.keys.sorted() where records[staleHash]?.leases.isEmpty == true {
                _ = try await jsonRequest(path: "/torrents", body: ["action": "rem", "hash": staleHash])
                records.removeValue(forKey: staleHash)
            }
        }
        guard records.count < Self.maximumActiveTorrents else { throw SPTorrentServerError.capacityReached }
        let expectedGeneration = generation
        var created = false
        do {
            let reply: Any
            if let torrentData {
                let boundary = "KhuaTorrent-" + UUID().uuidString
                let body = await Task.detached(priority: .utility) {
                    var data = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"source.torrent\"\r\nContent-Type: application/x-bittorrent\r\n\r\n".utf8)
                    data.append(torrentData)
                    data.append(Data("\r\n--\(boundary)--\r\n".utf8))
                    return data
                }.value
                reply = try await request(path: "/torrent/upload", body: body,
                    contentType: "multipart/form-data; boundary=\(boundary)")
            } else {
                reply = try await jsonRequest(path: "/torrents", body: [
                    "action": "add", "link": originalLink ?? hash, "save_to_db": false
                ])
            }
            guard let initial = Self.statusObject(reply),
                  SPTorrentInput.normalizedHash(initial["hash"] as? String ?? "") == hash else {
                throw SPTorrentServerError.invalidResponse
            }
            created = true
            var status = SPTorrentStatus(json: initial)
            let deadline = ProcessInfo.processInfo.systemUptime + metadataTimeout
            while status.files.isEmpty {
                try Task.checkCancellation()
                guard expectedGeneration == generation else { throw SPTorrentServerError.workerUnavailable }
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw SPTorrentServerError.metadataTimeout }
                try await Task.sleep(for: .milliseconds(350))
                status = try await self.status(hash: hash, requireLease: false)
            }
            guard status.files.allSatisfy({ $0.id > 0 && !$0.path.isEmpty && !$0.path.hasSuffix("/") && !$0.path.contains("\0") }),
                  Set(status.files.map(\.id)).count == status.files.count else {
                throw SPTorrentServerError.invalidResponse
            }
            guard status.files.contains(where: { $0.isPlayable && $0.length > 0 }) else {
                throw SPTorrentServerError.noPlayableFiles
            }
            try Task.checkCancellation()
            guard expectedGeneration == generation, isRunning else { throw SPTorrentServerError.workerUnavailable }
            let record = Record(hash: hash, name: status.name.isEmpty ? (initial["title"] as? String ?? hash) : status.name,
                                files: status.files, originalLink: originalLink,
                                originalTorrentData: torrentData, leases: [])
            return lease(record)
        } catch {
            // The add lock remains held through cleanup, so a cancellation can
            // never remove a torrent just acquired by the following window.
            if created, expectedGeneration == generation, records[hash] == nil {
                let cleanup = Task { @MainActor [weak self] in
                    _ = try? await self?.jsonRequest(path: "/torrents", body: ["action": "rem", "hash": hash])
                }
                _ = await cleanup.value
            }
            throw error
        }
    }

    func retain(_ descriptor: SPTorrentDescriptor) throws -> SPTorrentDescriptor {
        guard leaseHashes[descriptor.leaseID] == descriptor.hash,
              let record = records[descriptor.hash], isRunning else { throw SPTorrentServerError.invalidLease }
        idleTask?.cancel()
        return lease(record)
    }

    func release(_ descriptor: SPTorrentDescriptor) {
        endPlaybackWindow(descriptor)
        guard let hash = leaseHashes.removeValue(forKey: descriptor.leaseID), var record = records[hash] else { return }
        record.leases.remove(descriptor.leaseID)
        records[hash] = record
        guard record.leases.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.remove(hash: hash)
        }
    }

    /// Refuses to remove a torrent still owned by any player or download.
    func remove(hash: String) async throws {
        guard let hash = SPTorrentInput.normalizedHash(hash) else { throw SPTorrentServerError.invalidInput }
        try await acquireAddLock()
        defer { releaseAddLock(); scheduleIdleStop() }
        guard let record = records[hash] else { return }
        guard record.leases.isEmpty else { throw SPTorrentServerError.invalidLease }
        let expectedGeneration = generation
        if isRunning { _ = try await jsonRequest(path: "/torrents", body: ["action": "rem", "hash": hash]) }
        if expectedGeneration == generation, records[hash]?.leases.isEmpty == true { records.removeValue(forKey: hash) }
    }

    func status(hash: String) async throws -> SPTorrentStatus {
        try await status(hash: hash, requireLease: true)
    }

    private func status(hash: String, requireLease: Bool) async throws -> SPTorrentStatus {
        guard let hash = SPTorrentInput.normalizedHash(hash) else { throw SPTorrentServerError.invalidInput }
        if requireLease, records[hash]?.leases.isEmpty != false { throw SPTorrentServerError.invalidLease }
        guard let configuration = worker?.configuration else { throw SPTorrentServerError.workerUnavailable }
        let reply = try await jsonRequest(path: "/torrents", body: ["action": "get", "hash": hash])
        guard let object = reply as? [String: Any], object["hash"] as? String == hash else {
            throw SPTorrentServerError.invalidResponse
        }
        // PreloadedBytes is the worker's resident cache count. Avoid fetching
        // the entire per-piece map for a frequently updated progress label.
        return SPTorrentStatus(json: object, cache: [
            "Filled": object["preloaded_bytes"] as? NSNumber ?? 0,
            "Capacity": configuration.cacheSizeBytes
        ])
    }

    /// Core extracts these credentials into Authorization and removes userinfo
    /// before issuing every HTTP range request. Never log the resulting URL.
    func streamURL(hash: String, file: SPTorrentFile, playbackConsumer: UUID? = nil) throws -> URL {
        guard let hash = SPTorrentInput.normalizedHash(hash),
              let record = records[hash], !record.leases.isEmpty, let worker, worker.process.isRunning else {
            throw SPTorrentServerError.invalidLease
        }
        guard record.files.contains(file), file.id > 0 else { throw SPTorrentServerError.invalidFile }
        if let playbackConsumer, leaseHashes[playbackConsumer] != hash { throw SPTorrentServerError.invalidLease }
        var components = URLComponents(url: worker.endpoint, resolvingAgainstBaseURL: false)!
        components.user = worker.user
        components.password = worker.password
        components.path = "/stream/" + (file.path as NSString).lastPathComponent
        components.queryItems = [URLQueryItem(name: "link", value: hash), URLQueryItem(name: "index", value: String(file.id)),
                                 URLQueryItem(name: "play", value: "")]
        if let playbackConsumer {
            components.queryItems?.append(URLQueryItem(name: "playback_consumer", value: playbackConsumer.uuidString))
        }
        guard let url = components.url else { throw SPTorrentServerError.invalidResponse }
        return url
    }

    /// Media timestamps, rather than the moving network reader, choose history
    /// and playback offsets. The worker assigns the shared forward RAM budget.
    func updatePlaybackWindow(_ descriptor: SPTorrentDescriptor, file: SPTorrentFile,
                              historyLowerBound: Int64, playbackOffset: Int64,
                              forwardUpperBound: Int64) async throws -> SPTorrentPlaybackWindow {
        try Task.checkCancellation()
        guard leaseHashes[descriptor.leaseID] == descriptor.hash,
              let record = records[descriptor.hash], let worker, worker.process.isRunning else {
            throw SPTorrentServerError.invalidLease
        }
        guard record.files.contains(file), file.length > 0, historyLowerBound >= 0,
              historyLowerBound <= playbackOffset, playbackOffset <= forwardUpperBound,
              forwardUpperBound > historyLowerBound, forwardUpperBound <= file.length else {
            throw SPTorrentServerError.invalidFile
        }
        let revision = try nextPlaybackWindowRevision(descriptor.leaseID)
        let expectedGeneration = worker.generation
        let reply = try await jsonRequest(path: "/playback/window", body: [
            "hash": descriptor.hash, "file_index": file.id, "consumer": descriptor.leaseID.uuidString,
            "revision": revision, "lower": historyLowerBound, "current": playbackOffset, "upper": forwardUpperBound
        ], expectedGeneration: expectedGeneration)
        try Task.checkCancellation()
        // An older network completion cannot restore a cleared or superseded
        // window, even if the source still has the same torrent hash.
        guard self.worker?.generation == expectedGeneration,
              leaseHashes[descriptor.leaseID] == descriptor.hash,
              playbackConsumerRevisions[descriptor.leaseID] == revision else { throw CancellationError() }
        guard let object = reply as? [String: Any],
              Self.windowInteger(object["revision"]) == revision,
              let lower = Self.windowInteger(object["lower"]),
              let current = Self.windowInteger(object["current"]),
              let upper = Self.windowInteger(object["upper"]),
              let pieceLength = Self.windowInteger(object["piece_length"]),
              pieceLength > 0, lower >= 0, lower <= current, current == playbackOffset,
              current <= upper, upper > lower, upper <= file.length,
              (lower >= historyLowerBound || current - lower < pieceLength),
              (upper <= forwardUpperBound || upper - current <= pieceLength) else {
            throw SPTorrentServerError.invalidResponse
        }
        let prefetchCapacityStop: SPTorrentPrefetchCapacityStop?
        if let value = object["prefetch_stop"], !(value is NSNull) {
            guard let proof = value as? [String: Any], proof["reason"] as? String == "capacity",
                  let nonce = proof["request_id"] as? String, let requestID = UUID(uuidString: nonce),
                  Self.windowInteger(proof["file_index"]) == Int64(file.id),
                  let rangeStart = Self.windowInteger(proof["range_start"]),
                  let rangeEnd = Self.windowInteger(proof["range_end"]),
                  let nextOffset = Self.windowInteger(proof["next_offset"]),
                  let stopRevision = Self.windowInteger(proof["revision"]),
                  rangeStart >= 0, rangeStart <= nextOffset, nextOffset < rangeEnd,
                  rangeEnd <= file.length, stopRevision > 0, stopRevision <= revision else {
                throw SPTorrentServerError.invalidResponse
            }
            prefetchCapacityStop = SPTorrentPrefetchCapacityStop(requestID: requestID, fileID: file.id,
                rangeStart: rangeStart, rangeEnd: rangeEnd, nextOffset: nextOffset, revision: stopRevision)
        } else {
            prefetchCapacityStop = nil
        }
        return SPTorrentPlaybackWindow(historyLowerBound: lower, playbackOffset: current,
            forwardUpperBound: upper, pieceLength: pieceLength, prefetchCapacityStop: prefetchCapacityStop)
    }

    /// Supersede in-flight acknowledgements at a seek/source boundary without
    /// removing the last retained window. The next valid media window replaces
    /// it atomically in the worker; a temporary unknown position is not a close.
    func invalidatePlaybackWindow(_ descriptor: SPTorrentDescriptor) {
        guard leaseHashes[descriptor.leaseID] == descriptor.hash,
              playbackConsumerRevisions[descriptor.leaseID] != nil else { return }
        _ = try? nextPlaybackWindowRevision(descriptor.leaseID)
    }

    /// Destructive removal belongs to the end of a source's ownership, never a
    /// seek or a transient gap in Core's packet-to-time mapping.
    func endPlaybackWindow(_ descriptor: SPTorrentDescriptor) {
        guard let removal = playbackWindowRemoval(descriptor) else { return }
        Task { @MainActor [weak self] in await self?.sendPlaybackWindowRemoval(removal) }
    }

    func clearPlaybackWindow(_ descriptor: SPTorrentDescriptor) async {
        guard let removal = playbackWindowRemoval(descriptor) else { return }
        await sendPlaybackWindowRemoval(removal)
    }

    private func nextPlaybackWindowRevision(_ consumer: UUID) throws -> Int64 {
        let previous = playbackConsumerRevisions[consumer] ?? 0
        guard previous < Int64.max else { throw SPTorrentServerError.invalidResponse }
        let revision = previous + 1
        playbackConsumerRevisions[consumer] = revision
        return revision
    }

    private func playbackWindowRemoval(_ descriptor: SPTorrentDescriptor) -> PlaybackWindowRemoval? {
        guard leaseHashes[descriptor.leaseID] == descriptor.hash,
              playbackConsumerRevisions[descriptor.leaseID] != nil,
              let worker, let revision = try? nextPlaybackWindowRevision(descriptor.leaseID) else { return nil }
        return PlaybackWindowRemoval(hash: descriptor.hash, consumer: descriptor.leaseID,
                                     revision: revision, generation: worker.generation)
    }

    private func sendPlaybackWindowRemoval(_ removal: PlaybackWindowRemoval) async {
        _ = try? await jsonRequest(path: "/playback/window", body: [
            "hash": removal.hash, "consumer": removal.consumer.uuidString,
            "revision": removal.revision, "remove": true
        ], expectedGeneration: removal.generation)
    }

    /// Streams the entire file into the user-selected destination. The save
    /// owns a separate lease and never raises the rolling media cache limit.
    /// Cancel the caller's Task to cancel the download and release that lease.
    func saveFile(_ descriptor: SPTorrentDescriptor, file: SPTorrentFile, to destination: URL,
                  replaceExisting: Bool = false,
                  progress: (@MainActor @Sendable (SPTorrentDownloadProgress) -> Void)? = nil) async throws -> URL {
        guard destination.isFileURL else { throw SPTorrentServerError.invalidInput }
        let retained = try retain(descriptor)
        let download = SPTorrentFileDownload()
        downloads[retained.leaseID] = download
        notifications.post(name: Self.cacheConfigurationDidChangeNotification, object: self)
        defer {
            downloads.removeValue(forKey: retained.leaseID)
            release(retained)
            notifications.post(name: Self.cacheConfigurationDidChangeNotification, object: self)
        }
        let url = try streamURL(hash: descriptor.hash, file: file)
        var request = Self.mediaRequest(url)
        request.timeoutInterval = 120
        return try await download.run(request: request, destination: destination,
                                      replaceExisting: replaceExisting, progress: progress)
    }

    /// The UI coordinator closes every playback lease before calling this.
    /// An independent save or a newly opened session must never be interrupted.
    /// Wait only for unowned cleanup, then leave startup to the explicit reopen.
    func prepareForCacheRestart(timeout: TimeInterval = 3) async throws {
        try Task.checkCancellation()
        guard !hasTorrentOwners else { throw SPTorrentServerError.cacheRestartBusy }
        let interval = timeout.isFinite ? max(0, min(30, timeout)) : 3
        let deadline = ProcessInfo.processInfo.systemUptime + interval
        while hasActiveTorrentOperation {
            guard !hasTorrentOwners,
                  ProcessInfo.processInfo.systemUptime < deadline else { throw SPTorrentServerError.cacheRestartBusy }
            try await Task.sleep(for: .milliseconds(20))
        }
        try Task.checkCancellation()
        guard !hasTorrentOwners else { throw SPTorrentServerError.cacheRestartBusy }
        // No suspension occurs between checking and taking this uncontended
        // lock. Queued opens are neither cancelled nor silently evicted.
        adding = true
        defer { releaseAddLock(); scheduleIdleStop() }
        retireUnownedWorker()
        let expectedGeneration = generation
        try await waitForRetiredWorkers(deadline: deadline)
        guard generation == expectedGeneration else { throw CancellationError() }
    }

    /// Application termination: only this manager's child process is stopped.
    /// The private directory is removed after its process has relinquished it.
    func shutdown() {
        generation &+= 1
        startTask?.cancel()
        startTask = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        idleTask?.cancel()
        idleTask = nil
        downloads.values.forEach { $0.cancel() }
        let waiting = addWaiters
        addWaiters.removeAll()
        waiting.forEach { $0.continuation.resume(throwing: CancellationError()) }
        records.removeAll()
        leaseHashes.removeAll()
        playbackConsumerRevisions.removeAll()
        if let previous = worker {
            worker = nil
            disposeWorker(previous)
            notifications.post(name: Self.cacheConfigurationDidChangeNotification, object: self)
        }
    }

    private func lease(_ record: Record) -> SPTorrentDescriptor {
        var record = record
        let id = UUID()
        record.leases.insert(id)
        records[record.hash] = record
        leaseHashes[id] = record.hash
        return SPTorrentDescriptor(leaseID: id, hash: record.hash, name: record.name,
                                  files: record.files, originalLink: record.originalLink,
                                  originalTorrentData: record.originalTorrentData)
    }

    private func acquireAddLock() async throws {
        try Task.checkCancellation()
        if !adding { adding = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { addWaiters.append(AddWaiter(id: id, continuation: continuation)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let index = self.addWaiters.firstIndex(where: { $0.id == id }) else { return }
                self.addWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
            }
        }
    }

    private func releaseAddLock() {
        if addWaiters.isEmpty { adding = false }
        else { addWaiters.removeFirst().continuation.resume() }
    }

    private func ensureRunning() async throws {
        retireUnownedWorkerForConfigurationChange()
        let retirementGeneration = generation
        // A coordinated restart and any independent queued open share this
        // lock. Never overlap the old process's RAM cache with its replacement.
        try await waitForRetiredWorkers(deadline: ProcessInfo.processInfo.systemUptime + 10)
        guard generation == retirementGeneration else { throw CancellationError() }
        if isRunning { return }
        if let stale = worker {
            workerTerminated(process: stale.process, generation: stale.generation, status: stale.process.terminationStatus)
        }
        if let startTask { try await startTask.value; return }
        guard let workerURL else { throw SPTorrentServerError.workerMissing }
        generation &+= 1
        let expectedGeneration = generation
        let task = Task { @MainActor [weak self] in
            guard let self else { throw SPTorrentServerError.workerUnavailable }
            try await self.startWorker(at: workerURL, generation: expectedGeneration)
        }
        startTask = task
        defer { if generation == expectedGeneration { startTask = nil } }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private func startWorker(at executable: URL, generation expectedGeneration: UInt64) async throws {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let configuration = settingsProvider()
            let directory = temporaryDirectory.appendingPathComponent("KhuaTorrent-" + UUID().uuidString, isDirectory: true)
            let password = UUID().uuidString + UUID().uuidString
            let user = "khua"
            let peerDiscoveryEnabled = peerDiscoveryEnabled
            let trackerListURL = trackerListURL
            let port = try await Task.detached(priority: .utility) {
                do {
                    try Self.prepareDirectory(directory, user: user, password: password,
                                              peerDiscoveryEnabled: peerDiscoveryEnabled,
                                              trackerListURL: trackerListURL, configuration: configuration)
                    return try Self.unusedLoopbackPort()
                } catch {
                    try? FileManager.default.removeItem(at: directory)
                    throw error
                }
            }.value
            if Task.isCancelled || generation != expectedGeneration {
                Self.removeDirectory(directory)
                throw CancellationError()
            }
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--ip", "127.0.0.1", "--port", String(port), "--path", directory.path, "--httpauth"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] process in
                let status = process.terminationStatus
                Task { @MainActor [weak self] in
                    self?.workerTerminated(process: process, generation: expectedGeneration, status: status)
                }
            }
            let endpoint = URL(string: "http://127.0.0.1:\(port)")!
            let candidate = Worker(process: process, directory: directory, endpoint: endpoint,
                                   user: user, password: password, generation: expectedGeneration,
                                   configuration: configuration)
            do { try process.run() }
            catch { Self.removeDirectory(directory); throw SPTorrentServerError.workerMissing }
            worker = candidate
            do {
                let deadline = ProcessInfo.processInfo.systemUptime + 15
                while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                    try Task.checkCancellation()
                    guard generation == expectedGeneration else { throw CancellationError() }
                    do {
                        var echo = URLRequest(url: endpoint.appendingPathComponent("echo"))
                        echo.timeoutInterval = 0.5
                        let (body, response) = try await session.data(for: echo)
                        if (response as? HTTPURLResponse)?.statusCode == 200,
                           String(data: body, encoding: .utf8) == Self.workerVersion {
                            _ = try await jsonRequest(path: "/torrents", body: ["action": "list"])
                            try await verifyAuthentication()
                            beginKeepalive()
                            notifications.post(name: Self.cacheConfigurationDidChangeNotification, object: self)
                            return
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { /* The worker can still be preparing its listeners. */ }
                    try await Task.sleep(for: .milliseconds(100))
                }
                throw SPTorrentServerError.workerUnavailable
            } catch {
                if worker?.process === process { worker = nil }
                disposeWorker(candidate)
                notifications.post(name: Self.cacheConfigurationDidChangeNotification, object: self)
                guard generation == expectedGeneration else { throw error }
                if error is CancellationError || attempt == 2 { throw error }
                try await waitForRetiredWorkers(deadline: ProcessInfo.processInfo.systemUptime + 10)
                guard generation == expectedGeneration else { throw CancellationError() }
            }
        }
    }

    private func verifyAuthentication() async throws {
        guard let worker else { throw SPTorrentServerError.workerUnavailable }
        var unauthenticated = URLRequest(url: worker.endpoint.appendingPathComponent("torrents"))
        unauthenticated.httpMethod = "POST"
        unauthenticated.httpBody = Data("{\"action\":\"list\"}".utf8)
        unauthenticated.setValue("application/json", forHTTPHeaderField: "Content-Type")
        unauthenticated.timeoutInterval = 2
        let (_, response) = try await session.data(for: unauthenticated)
        guard (response as? HTTPURLResponse)?.statusCode == 401 else { throw SPTorrentServerError.workerUnavailable }
    }

    private func workerTerminated(process: Process, generation expectedGeneration: UInt64, status: Int32) {
        guard let previous = worker, previous.generation == expectedGeneration, previous.process === process else { return }
        worker = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        records.removeAll()
        leaseHashes.removeAll()
        playbackConsumerRevisions.removeAll()
        downloads.values.forEach { $0.cancel() }
        Self.removeDirectory(previous.directory)
        notifications.post(name: Self.cacheConfigurationDidChangeNotification, object: self)
        NotificationCenter.default.post(name: Self.didExitNotification, object: self,
                                        userInfo: ["status": status])
    }

    private func beginKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                await self?.touchLeasedTorrents()
            }
        }
    }

    private func touchLeasedTorrents() async {
        for hash in records.keys.sorted() where records[hash]?.leases.isEmpty == false {
            if Task.isCancelled { return }
            _ = try? await status(hash: hash)
        }
    }

    private func scheduleIdleStop() {
        if !adding, addWaiters.isEmpty { retireUnownedWorkerForConfigurationChange() }
        guard records.isEmpty, !adding, addWaiters.isEmpty, downloads.isEmpty else { return }
        idleTask?.cancel()
        let delay = idleTimeout
        idleTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.records.isEmpty, !self.adding, self.addWaiters.isEmpty, self.downloads.isEmpty else { return }
            self.shutdown()
        }
    }

    private func settingsChanged() {
        // A startup, add or removal owns the lock across its awaits. Its next
        // idle boundary (or the next add) performs this check instead.
        guard !adding, addWaiters.isEmpty, startTask == nil else { return }
        retireUnownedWorkerForConfigurationChange()
    }

    private func retireUnownedWorkerForConfigurationChange() {
        guard let previous = worker, previous.configuration != settingsProvider() else { return }
        retireUnownedWorker()
    }

    private var hasTorrentOwners: Bool {
        !downloads.isEmpty || !leaseHashes.isEmpty || records.values.contains(where: { !$0.leases.isEmpty })
    }

    private func retireUnownedWorker() {
        guard startTask == nil, !hasTorrentOwners else { return }
        records.removeAll()
        guard let previous = worker else { return }
        // Do not use shutdown(): queued add continuations belong to the next
        // session and must survive a configuration-only worker replacement.
        generation &+= 1
        worker = nil
        playbackConsumerRevisions.removeAll()
        keepaliveTask?.cancel()
        keepaliveTask = nil
        idleTask?.cancel()
        idleTask = nil
        disposeWorker(previous)
        notifications.post(name: Self.cacheConfigurationDidChangeNotification, object: self)
    }

    private func disposeWorker(_ previous: Worker) {
        let id = ObjectIdentifier(previous.process)
        guard retirementTasks[id] == nil else { return }
        let retirement = Self.dispose(previous)
        retirementTasks[id] = retirement
        Task { @MainActor [weak self] in
            await retirement.value
            self?.retirementTasks.removeValue(forKey: id)
        }
    }

    private func waitForRetiredWorkers(deadline: TimeInterval) async throws {
        while !retirementTasks.isEmpty {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw SPTorrentServerError.cacheRestartBusy }
            try await Task.sleep(for: .milliseconds(20))
        }
        try Task.checkCancellation()
    }

    private func jsonRequest(path: String, body: [String: Any], expectedGeneration: UInt64? = nil) async throws -> Any {
        try await request(path: path, body: JSONSerialization.data(withJSONObject: body),
                          contentType: "application/json", expectedWorkerGeneration: expectedGeneration)
    }

    private func request(path: String, body: Data, contentType: String,
                         expectedWorkerGeneration: UInt64? = nil) async throws -> Any {
        guard let worker, worker.process.isRunning else { throw SPTorrentServerError.workerUnavailable }
        if let expectedWorkerGeneration, worker.generation != expectedWorkerGeneration {
            throw SPTorrentServerError.workerUnavailable
        }
        let expectedGeneration = worker.generation
        var request = URLRequest(url: worker.endpoint.appendingPathComponent(String(path.drop(while: { $0 == "/" }))))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(Self.authorization(user: worker.user, password: worker.password), forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard self.worker?.generation == expectedGeneration else { throw SPTorrentServerError.workerUnavailable }
        guard let response = response as? HTTPURLResponse else { throw SPTorrentServerError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw SPTorrentServerError.http(response.statusCode) }
        if data.isEmpty { return NSNull() }
        return try JSONSerialization.jsonObject(with: data)
    }

    private nonisolated static func statusObject(_ value: Any) -> [String: Any]? {
        if let object = value as? [String: Any] { return object }
        let array = value as? [[String: Any]]
        return array?.count == 1 ? array?.first : nil
    }

    private nonisolated static func windowInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int64(number.stringValue)
    }

    private nonisolated static func authorization(user: String, password: String) -> String {
        "Basic " + Data((user + ":" + password).utf8).base64EncodedString()
    }

    private nonisolated static func mediaRequest(_ url: URL) -> URLRequest {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let user = components.user ?? ""
        let password = components.password ?? ""
        components.user = nil
        components.password = nil
        var request = URLRequest(url: components.url!)
        request.setValue(authorization(user: user, password: password), forHTTPHeaderField: "Authorization")
        return request
    }

    private nonisolated static func sessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 8
        config.connectionProxyDictionary = [:]
        return config
    }

    private nonisolated static func prepareDirectory(_ directory: URL, user: String, password: String,
                                                    peerDiscoveryEnabled: Bool, trackerListURL: URL?,
                                                    configuration: SPTorrentConfiguration) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let accounts = try JSONSerialization.data(withJSONObject: [user: password])
        let accountsURL = directory.appendingPathComponent("accs.db", isDirectory: false)
        try accounts.write(to: accountsURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: accountsURL.path)
        // This version-pinned configuration precedes process launch. Calling
        // /settings during playback would drop every active torrent.
        let settings: [String: Any] = [
            "CacheSize": configuration.cacheSizeBytes, "ReaderReadAHead": 95, "PreloadCache": 2,
            "UseDisk": false, "RemoveCacheOnDrop": true, "TorrentsSavePath": "",
            "ConnectionsLimit": 25, "TorrentDisconnectTimeout": 30, "RetrackersMode": 0,
            "ResponsiveMode": true, "ShowFSActiveTorr": false, "TrackTimecode": false,
            "StoreSettingsInJson": true, "StoreViewedInJson": true,
            "EnableBonjour": false, "EnableDLNA": false, "EnableLPD": false,
            "DisableDHT": !peerDiscoveryEnabled, "DisablePEX": !peerDiscoveryEnabled,
            "TrackersListURL": trackerListURL?.absoluteString ?? "",
            "DisableUPNP": true, "EnableRutorSearch": false, "EnableTorznabSearch": false
        ]
        let configURL = directory.appendingPathComponent("settings.json", isDirectory: false)
        try JSONSerialization.data(withJSONObject: ["BitTorr": settings]).write(to: configURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    private nonisolated static func unusedLoopbackPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SPTorrentServerError.workerUnavailable }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw SPTorrentServerError.workerUnavailable }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { throw SPTorrentServerError.workerUnavailable }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private nonisolated static func removeDirectory(_ directory: URL) {
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) }
    }

    @discardableResult
    private nonisolated static func dispose(_ worker: Worker) -> Task<Void, Never> {
        worker.process.terminationHandler = nil
        // applicationWillTerminate cannot wait for a detached task to begin.
        // Deliver SIGTERM now; only waiting and directory cleanup are deferred.
        if worker.process.isRunning { worker.process.terminate() }
        return Task.detached(priority: .utility) {
            if worker.process.isRunning {
                let deadline = ProcessInfo.processInfo.systemUptime + 8
                while worker.process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if worker.process.isRunning { kill(worker.process.processIdentifier, SIGKILL) }
                worker.process.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: worker.directory)
        }
    }
}

/// URLSession owns its temporary file only during the delegate callback, so the
/// move/replace happens on its background delegate queue, never the main actor.
private final class SPTorrentFileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, any Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var destination: URL?
    private var replaceExisting = false
    private var cancelled = false
    private var lastProgressAt: TimeInterval = 0
    private var progress: (@MainActor @Sendable (SPTorrentDownloadProgress) -> Void)?

    func run(request: URLRequest, destination: URL, replaceExisting: Bool,
             progress: (@MainActor @Sendable (SPTorrentDownloadProgress) -> Void)?) async throws -> URL {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                self.destination = destination
                self.replaceExisting = replaceExisting
                self.progress = progress
                let config = URLSessionConfiguration.ephemeral
                config.urlCredentialStorage = nil
                config.connectionProxyDictionary = [:]
                config.timeoutIntervalForResource = 7 * 24 * 60 * 60
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: request)
                self.session = session
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = task
        lock.unlock()
        current?.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let publish = now - lastProgressAt >= 0.15 || totalBytesWritten == totalBytesExpectedToWrite
        let callback = publish ? progress : nil
        if publish { lastProgressAt = now }
        lock.unlock()
        if let callback {
            let value = SPTorrentDownloadProgress(receivedBytes: totalBytesWritten, expectedBytes: totalBytesExpectedToWrite)
            Task { @MainActor in callback(value) }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock()
        let destination = destination
        let replace = replaceExisting
        let cancelled = cancelled
        lock.unlock()
        do {
            guard !cancelled else { throw CancellationError() }
            guard let response = downloadTask.response as? HTTPURLResponse else { throw SPTorrentServerError.invalidResponse }
            guard response.statusCode == 200 else { throw SPTorrentServerError.http(response.statusCode) }
            guard let destination else { throw SPTorrentServerError.invalidResponse }
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) {
                guard replace else { throw SPTorrentServerError.destinationExists }
                // Replacement must use a sibling on the destination volume;
                // the URLSession temporary file can be on another disk.
                let staging = destination.deletingLastPathComponent()
                    .appendingPathComponent(".KhuaSave-" + UUID().uuidString, isDirectory: false)
                try fm.moveItem(at: location, to: staging)
                defer { try? fm.removeItem(at: staging) }
                lock.lock()
                let cancelledWhileMoving = self.cancelled
                lock.unlock()
                guard !cancelledWhileMoving else { throw CancellationError() }
                _ = try fm.replaceItemAt(destination, withItemAt: staging)
            } else { try fm.moveItem(at: location, to: destination) }
            finish(.success(destination))
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, any Error>) {
        lock.lock()
        let current = continuation
        continuation = nil
        let previousSession = session
        session = nil
        task = nil
        progress = nil
        lock.unlock()
        current?.resume(with: result)
        previousSession?.finishTasksAndInvalidate()
    }
}

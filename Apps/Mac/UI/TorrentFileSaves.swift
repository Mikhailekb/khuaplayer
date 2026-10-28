import Foundation

/// A saved file belongs to immutable torrent contents, not a playback lease or
/// whichever episode happens to be selected when an async callback arrives.
struct SPTorrentFileSaveID: Hashable, Sendable {
    let hash: String
    let fileID: Int
    let path: String
    let length: Int64

    init(descriptor: SPTorrentDescriptor, file: SPTorrentFile) {
        hash = descriptor.hash.lowercased()
        fileID = file.id
        path = file.path
        length = file.length
    }
}

struct SPTorrentFileSaveSnapshot: Equatable, Sendable {
    enum Phase: Sendable { case saving, cancelling, saved, failed, cancelled }

    let id: SPTorrentFileSaveID
    let file: SPTorrentFile
    let destination: URL
    var phase: Phase
    var receivedBytes: Int64
    let expectedBytes: Int64
    var failureDescription: String?

    var isActive: Bool { phase == .saving || phase == .cancelling }
    var fraction: Double {
        expectedBytes > 0 ? min(1, max(0, Double(receivedBytes) / Double(expectedBytes))) : 0
    }
}

/// Per-window owner of independently cancellable whole-file saves. Playback
/// selection is deliberately absent: the server retains each download's lease.
@MainActor
final class SPTorrentFileSaves {
    typealias Progress = @MainActor @Sendable (SPTorrentDownloadProgress) -> Void
    typealias Completion = @MainActor @Sendable (Result<URL, any Error>) -> Void
    typealias Saver = @MainActor @Sendable (
        SPTorrentDescriptor, SPTorrentFile, URL, Bool, @escaping Progress
    ) async throws -> URL

    private struct Job: Sendable {
        let token: UUID
        let destination: URL
        let task: Task<Void, Never>
    }

    var onChange: (@MainActor () -> Void)?
    private(set) var snapshots: [SPTorrentFileSaveID: SPTorrentFileSaveSnapshot] = [:]
    private var jobs: [SPTorrentFileSaveID: Job] = [:]
    private let saver: Saver
    var activeCount: Int { jobs.count }

    init(saver: @escaping Saver = { descriptor, file, destination, replace, progress in
        try await SPTorrentServer.shared.saveFile(descriptor, file: file, to: destination,
                                                  replaceExisting: replace, progress: progress)
    }) {
        self.saver = saver
    }

    deinit { for job in jobs.values { job.task.cancel() } }

    func snapshot(descriptor: SPTorrentDescriptor, file: SPTorrentFile) -> SPTorrentFileSaveSnapshot? {
        snapshots[SPTorrentFileSaveID(descriptor: descriptor, file: file)]
    }

    /// Returns false before any work/callback for an invalid or active request.
    /// A started request calls completion exactly once, including cancellation
    /// and owner teardown, so its caller can release a security-scoped grant.
    @discardableResult
    func start(descriptor: SPTorrentDescriptor, file: SPTorrentFile, to destination: URL,
               replaceExisting: Bool = false, completion: Completion? = nil) -> Bool {
        let id = SPTorrentFileSaveID(descriptor: descriptor, file: file)
        let canonicalDestination = destination.standardizedFileURL
        guard SPTorrentInput.normalizedHash(descriptor.hash) != nil, file.id > 0, file.length > 0,
              descriptor.files.contains(file), destination.isFileURL,
              jobs[id] == nil, !jobs.values.contains(where: { $0.destination == canonicalDestination }) else { return false }
        let token = UUID()
        let operation = saver
        let task = Task { @MainActor [weak self] in
            let result: Result<URL, any Error>
            do {
                try Task.checkCancellation()
                let saved = try await operation(descriptor, file, destination, replaceExisting) { [weak self] value in
                    self?.receive(value, id: id, token: token)
                }
                try Task.checkCancellation()
                result = .success(saved)
            } catch {
                result = .failure(Task.isCancelled ? CancellationError() : error)
            }
            self?.finish(result, id: id, token: token)
            completion?(result)
        }
        jobs[id] = Job(token: token, destination: canonicalDestination, task: task)
        snapshots[id] = SPTorrentFileSaveSnapshot(id: id, file: file, destination: destination,
            phase: .saving, receivedBytes: 0, expectedBytes: file.length)
        onChange?()
        return true
    }

    func cancel(descriptor: SPTorrentDescriptor, file: SPTorrentFile) {
        cancel(id: SPTorrentFileSaveID(descriptor: descriptor, file: file))
    }

    func cancel(id: SPTorrentFileSaveID) {
        guard let job = jobs[id] else { return }
        if var snapshot = snapshots[id], snapshot.phase == .saving {
            snapshot.phase = .cancelling
            snapshots[id] = snapshot
            job.task.cancel()
            onChange?()
        } else { job.task.cancel() }
    }

    /// Clearing a departed playlist hides its rows immediately, but keeps each
    /// cancellation draining until the underlying task actually acknowledges it.
    /// A late callback cannot recreate a cleared row or affect a newer request.
    func cancelAll(clear: Bool = true) {
        guard !jobs.isEmpty || !snapshots.isEmpty else { return }
        for job in jobs.values { job.task.cancel() }
        if clear { snapshots.removeAll() }
        else {
            for (id, var value) in snapshots where value.phase == .saving {
                value.phase = .cancelling
                snapshots[id] = value
            }
        }
        onChange?()
    }

    private func receive(_ progress: SPTorrentDownloadProgress, id: SPTorrentFileSaveID, token: UUID) {
        guard jobs[id]?.token == token, var snapshot = snapshots[id], snapshot.phase == .saving else { return }
        // File length is authoritative even when HTTP reports unknown/incorrect
        // Content-Length; delayed delegate notifications cannot move it backwards.
        let received = min(snapshot.expectedBytes, max(0, progress.receivedBytes))
        guard received > snapshot.receivedBytes else { return }
        snapshot.receivedBytes = received
        snapshots[id] = snapshot
        onChange?()
    }

    private func finish(_ result: Result<URL, any Error>, id: SPTorrentFileSaveID, token: UUID) {
        guard jobs[id]?.token == token else { return }
        jobs.removeValue(forKey: id)
        if var snapshot = snapshots[id] {
            switch result {
            case .success:
                snapshot.phase = .saved
                snapshot.receivedBytes = snapshot.expectedBytes
                snapshot.failureDescription = nil
            case .failure(let error):
                snapshot.phase = error is CancellationError ? .cancelled : .failed
                snapshot.failureDescription = error is CancellationError ? nil : error.localizedDescription
            }
            snapshots[id] = snapshot
        }
        onChange?()
    }
}

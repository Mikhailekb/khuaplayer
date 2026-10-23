import Foundation

/// All player windows share a worker, so changing its cache requires a single
/// coordinated handover. Every window keeps its own playback snapshot.
@MainActor
enum SPTorrentCacheReconfiguration {
    private static var isApplying = false

    private enum Failure: LocalizedError {
        case busy, saving, reconnect
        var errorDescription: String? {
            switch self {
            case .busy: return L("torrent.settings.restartBusy")
            case .saving: return L("torrent.settings.applyBlockedSave")
            case .reconnect: return L("torrent.settings.restartFailed")
            }
        }
    }

    static func apply(cacheSizeMiB: Int, controllers: [PlayerViewController]) async throws {
        guard !isApplying, SPTorrentPreferences.allowedCacheSizesMiB.contains(cacheSizeMiB) else {
            throw Failure.busy
        }
        let server = SPTorrentServer.shared
        guard server.activeDownloadCount == 0 else { throw Failure.saving }
        guard !server.hasActiveTorrentOperation,
              !controllers.contains(where: { $0.hasUnsettledTorrentOpen }) else { throw Failure.busy }
        isApplying = true
        defer { isApplying = false }

        let targets: [(PlayerViewController, SPTorrentCacheRestartSnapshot)] = try controllers.compactMap { controller in
            guard let snapshot = try controller.torrentCacheRestartSnapshot() else { return nil }
            return (controller, snapshot)
        }
        // No await occurs between the complete preflight and suspending every
        // source, so another UI operation cannot leave a partially stopped set.
        for (controller, snapshot) in targets {
            try controller.suspendTorrentForCacheRestart(snapshot)
        }

        let previousSize = SPTorrentPreferences.cacheSizeMiB
        do {
            SPTorrentPreferences.cacheSizeMiB = cacheSizeMiB
            try await server.prepareForCacheRestart(timeout: 10)
        } catch {
            SPTorrentPreferences.cacheSizeMiB = previousSize
            // A failed handover must still attempt to bring every untouched
            // source back. A user open/close invalidates its snapshot instead.
            for (controller, snapshot) in targets {
                try? await controller.resumeTorrentAfterCacheRestart(snapshot)
            }
            if server.activeDownloadCount > 0 { throw Failure.saving }
            throw Failure.busy
        }

        var hadFailure = false
        for (controller, snapshot) in targets {
            do { try await controller.resumeTorrentAfterCacheRestart(snapshot) }
            catch is CancellationError { /* A user deliberately changed/closed this source. */ }
            catch { hadFailure = true }
        }
        if hadFailure { throw Failure.reconnect }
    }
}

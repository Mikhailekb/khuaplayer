import Foundation

/// One process-wide producer for optional torrent work. Foreground subtitles
/// take priority over previews; unchanged grants do not rotate on polling.
@MainActor
final class SPTorrentBackgroundAdmission {
    static let shared = SPTorrentBackgroundAdmission()

    private enum Role { case subtitles, previews }
    private final class Entry {
        let owner: UUID
        weak var lifetime: AnyObject?
        var wantsSubtitles = false
        var wantsPreviews = false
        var onAdmission: @MainActor (Bool, Bool) -> Void

        init(owner: UUID, lifetime: AnyObject,
             onAdmission: @escaping @MainActor (Bool, Bool) -> Void) {
            self.owner = owner
            self.lifetime = lifetime
            self.onAdmission = onAdmission
        }
    }
    private struct Grant {
        let entry: Entry
        let role: Role

        func matches(_ other: Grant?) -> Bool {
            other?.entry === entry && other?.role == role
        }
    }

    private var entries: [UUID: Entry] = [:]
    private var subtitleQueue: [UUID] = []
    private var previewQueue: [UUID] = []
    private var active: Grant?
    private var reconciling = false
    private var reconciliationScheduled = false

    init() {}

    func update(owner: UUID, lifetime: AnyObject, wantsSubtitles: Bool, wantsPreviews: Bool,
                onAdmission: @escaping @MainActor (Bool, Bool) -> Void) {
        pruneExpired()
        let entry: Entry
        if let existing = entries[owner], existing.lifetime === lifetime {
            entry = existing
            entry.onAdmission = onAdmission
        } else {
            // Reusing an identifier for a new lifetime is a replacement. Keep
            // the old delivered grant long enough to revoke it before granting
            // the replacement; never transfer a live producer silently.
            removeEntry(owner)
            entry = Entry(owner: owner, lifetime: lifetime, onAdmission: onAdmission)
            entries[owner] = entry
        }
        if wantsSubtitles != entry.wantsSubtitles {
            subtitleQueue.removeAll { $0 == owner }
            if wantsSubtitles { subtitleQueue.append(owner) }
            entry.wantsSubtitles = wantsSubtitles
        }
        if wantsPreviews != entry.wantsPreviews {
            previewQueue.removeAll { $0 == owner }
            if wantsPreviews { previewQueue.append(owner) }
            entry.wantsPreviews = wantsPreviews
        }
        reconcile()
    }

    func remove(owner: UUID) {
        pruneExpired()
        removeEntry(owner)
        reconcile()
    }

    private func removeEntry(_ owner: UUID) {
        entries.removeValue(forKey: owner)
        subtitleQueue.removeAll { $0 == owner }
        previewQueue.removeAll { $0 == owner }
    }

    private func pruneExpired() {
        let expired = entries.compactMap { $0.value.lifetime == nil ? $0.key : nil }
        for owner in expired { removeEntry(owner) }
    }

    private func eligible(_ grant: Grant) -> Bool {
        guard entries[grant.entry.owner] === grant.entry, grant.entry.lifetime != nil else { return false }
        return grant.role == .subtitles ? grant.entry.wantsSubtitles : grant.entry.wantsPreviews
    }

    private func desiredGrant() -> Grant? {
        if let owner = subtitleQueue.first, let first = entries[owner] {
            if let active, active.role == .subtitles, eligible(active) { return active }
            return Grant(entry: first, role: .subtitles)
        }
        if let owner = previewQueue.first, let first = entries[owner] {
            if let active, active.role == .previews, eligible(active) { return active }
            return Grant(entry: first, role: .previews)
        }
        return nil
    }

    private func reconcile() {
        guard !reconciling else { return }
        reconciling = true
        defer { reconciling = false }
        // Callbacks may mutate requests. Recompute after every callback rather
        // than delivering a previously planned grant to a now-cancelled owner.
        // A pathological callback cannot monopolize one MainActor turn forever.
        for _ in 0..<64 {
            pruneExpired()
            let desired = desiredGrant()
            if let active, active.matches(desired) { return }
            if let previous = active {
                active = nil
                if let lifetime = previous.entry.lifetime {
                    withExtendedLifetime(lifetime) { previous.entry.onAdmission(false, false) }
                }
                continue
            }
            guard let desired else { return }
            active = desired
            if let lifetime = desired.entry.lifetime {
                withExtendedLifetime(lifetime) {
                    desired.entry.onAdmission(desired.role == .subtitles, desired.role == .previews)
                }
            }
        }
        guard !reconciliationScheduled else { return }
        reconciliationScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.reconciliationScheduled = false
            self.reconcile()
        }
    }
}

/// The native cancellation/pause probe reads only this locked flag. Its caller
/// composes other admission conditions without actor hops or UI access here.
final class SPTorrentBackgroundGate: @unchecked Sendable {
    private let lock = NSLock()
    private var paused: Bool

    init(initiallyPaused: Bool = true) {
        paused = initiallyPaused
    }

    func setPaused(_ paused: Bool) {
        lock.lock()
        self.paused = paused
        lock.unlock()
    }

    func shouldPause() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return paused
    }
}

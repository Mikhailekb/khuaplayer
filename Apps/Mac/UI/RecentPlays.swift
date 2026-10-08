import Foundation

extension Notification.Name {
    /// Posted on the main thread after the recent-play ledger changes. Every
    /// window observes it so welcome lists share one process-wide snapshot.
    static let spRecentPlaysChanged = Notification.Name("sp.recentPlaysChanged")
}

struct RecentPlay: Codable {
    let path: String
    let title: String
    var position: Double
    var duration: Double
    var lastPlayedAt: Double

    var isFinished: Bool {
        Self.isFinished(position: position, duration: duration)
    }

    var isCompleted: Bool {
        Self.isCompleted(position: position, duration: duration)
    }

    static func isFinished(position: Double, duration: Double) -> Bool {
        guard position.isFinite, duration.isFinite, duration > 0 else { return false }
        let fraction = position / duration
        return fraction > 0.93 || (duration - position < 120 && fraction > 0.85)
    }

    static func isCompleted(position: Double, duration: Double) -> Bool {
        guard position.isFinite, duration.isFinite, duration > 0 else { return false }
        return duration - position < 120 && position / duration > 0.85
    }

    var remainingText: String {
        guard duration > 0 else { return "" }
        let remain = max(0, duration - position)
        let minutes = Int((remain / 60).rounded(.up))
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}

/// Main-thread read-through value for a resume write that has been enqueued
/// but may not have reached UserDefaults yet. Duration travels with position:
/// without it, a just-finished file reopened before the async ledger write
/// lands looks like an ordinary resume point at EOF.
struct SPResumeCheckpoint: Equatable {
    let position: Double
    let duration: Double
}

/// Bounded MRU index over the `sp.pos.*` keys. Every unfinished file leaves a
/// resume key behind and nothing ever pruned them, so the defaults domain grew
/// by one path-sized key per film forever. cfprefsd treats the domain as one
/// file: the first UserDefaults read in main.swift (Bootstrap critical path)
/// deserialises all of it, and every periodic 5s resume write rewrites all of
/// it. `sp.posOrder` keeps the most recently recorded paths; anything that
/// falls off the tail loses its resume key. Legacy keys present before the
/// index existed are adopted once, in arbitrary order, capped the same way.
/// Runs on the caller's serialized resume queue.
enum SPResumePositionIndex {
    static let key = "sp.posOrder"
    static let capacity = 400
    static let positionPrefix = "sp.pos."

    static func touch(path: String, defaults: UserDefaults = .standard) {
        var order = defaults.stringArray(forKey: key) ?? adoptLegacyKeys(defaults)
        order.removeAll { $0 == path }
        order.insert(path, at: 0)
        trim(&order, defaults: defaults)
        defaults.set(order, forKey: key)
    }

    static func forget(path: String, defaults: UserDefaults = .standard) {
        guard var order = defaults.stringArray(forKey: key) else { return }
        order.removeAll { $0 == path }
        defaults.set(order, forKey: key)
    }

    private static func trim(_ order: inout [String], defaults: UserDefaults) {
        guard order.count > capacity else { return }
        for dropped in order[capacity...] {
            defaults.removeObject(forKey: positionPrefix + dropped)
        }
        order.removeLast(order.count - capacity)
    }

    private static func adoptLegacyKeys(_ defaults: UserDefaults) -> [String] {
        var order: [String] = []
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix(positionPrefix) {
            order.append(String(k.dropFirst(positionPrefix.count)))
        }
        return order
    }
}

/// Durable `sp.pos.*` storage rule. Completion truth normally also lives in
/// the bounded recent ledger, but that entry can later be evicted. Therefore a
/// finished checkpoint must remove—not store—its EOF position; otherwise the
/// orphaned key eventually reopens the file at EOF after ledger eviction.
enum SPResumePositionStore {
    static func persist(_ checkpoint: SPResumeCheckpoint,
                        path: String,
                        defaults: UserDefaults = .standard) {
        let key = "sp.pos." + path
        guard checkpoint.position.isFinite,
              !RecentPlay.isCompleted(position: checkpoint.position,
                                      duration: checkpoint.duration) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(checkpoint.position, forKey: key)
    }
}

/// Pure resume decision shared by the open path and deterministic tests.
/// Latest in-process state wins over disk. A completed item means "replay from
/// the beginning", not "resume at the final frame".
enum SPResumePolicy {
    /// Ended is semantic completion even when the final decoded PTS is a little
    /// short of the container duration. Canonicalizing to duration makes the
    /// durable RecentPlay completion test independent of that muxing detail.
    /// An unknown/invalid duration cannot be represented as "finished" by the
    /// legacy ledger, so reset its resume point to zero instead of preserving a
    /// stale near-EOF `sp.pos` value.
    static func completedCheckpoint(duration: Double) -> SPResumeCheckpoint {
        guard duration.isFinite, duration > 0 else {
            return SPResumeCheckpoint(position: 0, duration: 0)
        }
        return SPResumeCheckpoint(position: duration, duration: duration)
    }

    /// The first Playing edge after Ended starts a new viewing pass. Persist
    /// the Core's already-published seek target (normally zero for Play, but it
    /// may be an arbitrary timeline seek) so the previous finished marker no
    /// longer overrides progress from this replay.
    static func replayCheckpoint(position: Double,
                                 duration: Double) -> SPResumeCheckpoint {
        let safePosition = position.isFinite ? max(0, position) : 0
        let safeDuration = duration.isFinite ? max(0, duration) : 0
        return SPResumeCheckpoint(position: safePosition, duration: safeDuration)
    }

    static func startPosition(path: String,
                              pending: SPResumeCheckpoint?,
                              storedPosition: @autoclosure () -> Double?,
                              recents: @autoclosure () -> [RecentPlay]) -> Double? {
        if let pending {
            guard !RecentPlay.isCompleted(position: pending.position,
                                          duration: pending.duration) else { return nil }
            return validPosition(pending.position)
        }
        // A pending checkpoint is already authoritative; avoid loading and
        // decoding inputs that branch never consumes. On a miss keep the
        // existing read order, once each, before deciding completion.
        let stored = storedPosition()
        let recentEntries = recents()
        if let recent = recentEntries.first(where: { $0.path == path }), recent.isCompleted {
            return nil
        }
        return validPosition(stored)
    }

    private static func validPosition(_ position: Double?) -> Double? {
        guard let position, position.isFinite, position > 2 else { return nil }
        return position
    }
}

enum RecentPlays {
    static let capacity = 10
    private static let key = "sp.recent"

    static func load(defaults: UserDefaults = .standard) -> [RecentPlay] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([RecentPlay].self, from: data) else { return [] }
        return list.sorted { $0.lastPlayedAt > $1.lastPlayedAt }
    }

    static func record(path: String, title: String, position: Double, duration: Double,
                       insert: Bool = true, defaults: UserDefaults = .standard) {
        let existing = load(defaults: defaults)
        if !insert && !existing.contains(where: { $0.path == path }) {
            SPResumePositionIndex.touch(path: path, defaults: defaults)
            return
        }
        var list = existing.filter { $0.path != path }
        list.insert(RecentPlay(path: path, title: title, position: position,
                               duration: duration,
                               lastPlayedAt: Date().timeIntervalSince1970), at: 0)
        if list.count > capacity { list.removeLast(list.count - capacity) }
        save(list, defaults: defaults)
        SPResumePositionIndex.touch(path: path, defaults: defaults)
    }

    static func rename(from old: String, to new: String, title: String, defaults: UserDefaults = .standard) {
        guard old != new else { return }
        var list = load(defaults: defaults)
        if let i = list.firstIndex(where: { $0.path == old }) {
            let e = list[i]
            list.removeAll { $0.path == new }
            if let j = list.firstIndex(where: { $0.path == old }) {
                list[j] = RecentPlay(path: new, title: title, position: e.position, duration: e.duration,
                                     lastPlayedAt: e.lastPlayedAt)
            }
            save(list, defaults: defaults)
        }
#if SP_APP_STORE
        SPRecentBookmarks.rename(from: old, to: new)
#endif
        let oldKey = SPResumePositionIndex.positionPrefix + old
        if let pos = defaults.object(forKey: oldKey) {
            defaults.set(pos, forKey: SPResumePositionIndex.positionPrefix + new)
            defaults.removeObject(forKey: oldKey)
            SPResumePositionIndex.forget(path: old, defaults: defaults)
            SPResumePositionIndex.touch(path: new, defaults: defaults)
        }
    }

    static func remove(path: String, defaults: UserDefaults = .standard) {
        save(load(defaults: defaults).filter { $0.path != path }, defaults: defaults)
#if SP_APP_STORE
        SPRecentBookmarks.forget(path: path)
#endif
    }

    /// Clear the ledger and notify every window. Callers use the same serialized
    /// queue as record so storage and visible lists remain consistently ordered.
    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
#if SP_APP_STORE
        SPRecentBookmarks.clear()
#endif
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .spRecentPlaysChanged, object: nil)
        }
    }

    private static func save(_ list: [RecentPlay], defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: key)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .spRecentPlaysChanged, object: nil)
        }
    }
}

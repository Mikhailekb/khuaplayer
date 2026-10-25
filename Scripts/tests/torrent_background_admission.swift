import Foundation

@MainActor private final class Lifetime {}
@MainActor private final class Record {
    struct Event: Equatable {
        let owner: UUID
        let subtitles: Bool
        let previews: Bool
    }
    var events: [Event] = []
    var running: Set<UUID> = []
    var maximumRunning = 0
    var bothRoles = false
    func callback(_ owner: UUID) -> @MainActor (Bool, Bool) -> Void {
        { [self] subtitles, previews in
            events.append(Event(owner: owner, subtitles: subtitles, previews: previews))
            if subtitles || previews { running.insert(owner) } else { running.remove(owner) }
            maximumRunning = max(maximumRunning, running.count)
            bothRoles = bothRoles || (subtitles && previews)
        }
    }
}

@main @MainActor private struct TorrentBackgroundAdmissionChecks {
    static var count = 0
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { print("FAIL: \(message)"); exit(1) }
        count += 1
    }

    static func main() async {
        let scheduler = SPTorrentBackgroundAdmission(), record = Record()
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let lifeA = Lifetime(), lifeB = Lifetime(), lifeC = Lifetime(), lifeD = Lifetime()
        scheduler.update(owner: a, lifetime: lifeA, wantsSubtitles: false, wantsPreviews: true, onAdmission: record.callback(a))
        check(record.events == [.init(owner: a, subtitles: false, previews: true)], "The first eligible preview receives one grant")
        for _ in 0..<200 {
            scheduler.update(owner: a, lifetime: lifeA, wantsSubtitles: false, wantsPreviews: true, onAdmission: record.callback(a))
        }
        check(record.events.count == 1, "Unchanged polls never rotate or duplicate a stable grant")
        scheduler.update(owner: b, lifetime: lifeB, wantsSubtitles: false, wantsPreviews: true, onAdmission: record.callback(b))
        scheduler.update(owner: c, lifetime: lifeC, wantsSubtitles: false, wantsPreviews: true, onAdmission: record.callback(c))
        check(record.events.count == 1, "Queued peers cannot preempt an unchanged same-role producer")
        scheduler.update(owner: d, lifetime: lifeD, wantsSubtitles: true, wantsPreviews: true, onAdmission: record.callback(d))
        check(record.events.suffix(2) == [.init(owner: a, subtitles: false, previews: false), .init(owner: d, subtitles: true, previews: false)],
              "Subtitles revoke the preview before receiving the sole producer grant")
        scheduler.remove(owner: d)
        check(record.events.last == .init(owner: a, subtitles: false, previews: true), "A preempted preview keeps its FIFO place")
        scheduler.remove(owner: a)
        check(record.events.last == .init(owner: b, subtitles: false, previews: true), "Releasing the oldest preview admits the next FIFO owner")
        scheduler.remove(owner: b)
        check(record.events.last == .init(owner: c, subtitles: false, previews: true), "A queued third owner is not starved after earlier releases")
        scheduler.update(owner: c, lifetime: lifeC, wantsSubtitles: false, wantsPreviews: false, onAdmission: record.callback(c))
        check(record.running.isEmpty && record.events.last == .init(owner: c, subtitles: false, previews: false),
              "Disabling the last request revokes its admission")
        let beforeNoop = record.events.count
        scheduler.remove(owner: c); scheduler.remove(owner: UUID())
        scheduler.update(owner: a, lifetime: lifeA, wantsSubtitles: false, wantsPreviews: false, onAdmission: record.callback(a))
        check(record.events.count == beforeNoop, "Removing absent owners and ineligible requests generates no false callbacks")
        check(record.maximumRunning == 1 && !record.bothRoles, "No transition admits two producers or both roles at once")

        let subs = SPTorrentBackgroundAdmission(), subtitleRecord = Record()
        subs.update(owner: a, lifetime: lifeA, wantsSubtitles: true, wantsPreviews: false, onAdmission: subtitleRecord.callback(a))
        subs.update(owner: b, lifetime: lifeB, wantsSubtitles: true, wantsPreviews: false, onAdmission: subtitleRecord.callback(b))
        subs.update(owner: c, lifetime: lifeC, wantsSubtitles: true, wantsPreviews: false, onAdmission: subtitleRecord.callback(c))
        subs.remove(owner: a); subs.remove(owner: b)
        check(subtitleRecord.events.filter(\.subtitles).map(\.owner) == [a, b, c], "Subtitle peers receive FIFO admission after releases")
        subs.update(owner: c, lifetime: lifeC, wantsSubtitles: false, wantsPreviews: true, onAdmission: subtitleRecord.callback(c))
        check(subtitleRecord.events.suffix(2) == [.init(owner: c, subtitles: false, previews: false), .init(owner: c, subtitles: false, previews: true)],
              "Changing the selected role revokes before re-admitting the same owner")

        let cancellation = SPTorrentBackgroundAdmission(), cancellationRecord = Record()
        cancellation.update(owner: a, lifetime: lifeA, wantsSubtitles: false, wantsPreviews: true, onAdmission: cancellationRecord.callback(a))
        cancellation.update(owner: b, lifetime: lifeB, wantsSubtitles: false, wantsPreviews: true, onAdmission: cancellationRecord.callback(b))
        cancellation.update(owner: c, lifetime: lifeC, wantsSubtitles: false, wantsPreviews: true, onAdmission: cancellationRecord.callback(c))
        cancellation.remove(owner: b); cancellation.remove(owner: a)
        check(cancellationRecord.events.filter(\.previews).map(\.owner) == [a, c], "A cancelled waiting owner never receives a stale grant")

        let weakScheduler = SPTorrentBackgroundAdmission()
        var temporary: Lifetime? = Lifetime()
        var expiredCallbacks = 0
        weakScheduler.update(owner: a, lifetime: temporary!, wantsSubtitles: true, wantsPreviews: false) { _, _ in expiredCallbacks += 1 }
        temporary = nil
        weakScheduler.update(owner: b, lifetime: lifeB, wantsSubtitles: false, wantsPreviews: true, onAdmission: { _, _ in })
        check(expiredCallbacks == 1, "Pruning a dead active lifetime never invokes its stale callback")
        weakScheduler.remove(owner: b)
        var waiter: Lifetime? = Lifetime()
        weakScheduler.update(owner: a, lifetime: lifeA, wantsSubtitles: true, wantsPreviews: false, onAdmission: { _, _ in })
        weakScheduler.update(owner: b, lifetime: waiter!, wantsSubtitles: true, wantsPreviews: false) { _, _ in expiredCallbacks += 100 }
        waiter = nil; weakScheduler.remove(owner: a)
        check(expiredCallbacks == 1, "Dead queued lifetimes are pruned before selection")

        let replacement = SPTorrentBackgroundAdmission(), replacementRecord = Record()
        replacement.update(owner: a, lifetime: lifeA, wantsSubtitles: false, wantsPreviews: true, onAdmission: replacementRecord.callback(a))
        replacement.update(owner: a, lifetime: lifeB, wantsSubtitles: true, wantsPreviews: false, onAdmission: replacementRecord.callback(a))
        check(replacementRecord.events == [.init(owner: a, subtitles: false, previews: true),
            .init(owner: a, subtitles: false, previews: false), .init(owner: a, subtitles: true, previews: false)],
              "Reusing an owner ID with a new lifetime revokes the old producer explicitly")

        let reentrant = SPTorrentBackgroundAdmission(), reentrantRecord = Record()
        reentrant.update(owner: a, lifetime: lifeA, wantsSubtitles: false, wantsPreviews: true) { subtitles, previews in
            reentrantRecord.callback(a)(subtitles, previews)
            if !subtitles && !previews { reentrant.remove(owner: b) }
        }
        reentrant.update(owner: b, lifetime: lifeB, wantsSubtitles: true, wantsPreviews: false, onAdmission: reentrantRecord.callback(b))
        check(!reentrantRecord.events.contains(where: { $0.owner == b }), "Reentrant cancellation during revocation prevents a previously planned stale grant")
        check(reentrantRecord.running == [a] && reentrantRecord.maximumRunning == 1,
              "A reentrant cancellation recomputes the surviving producer without overlap")
        let surrender = SPTorrentBackgroundAdmission(), surrenderRecord = Record()
        var callbackDepth = 0, maximumDepth = 0
        surrender.update(owner: a, lifetime: lifeA, wantsSubtitles: true, wantsPreviews: false) { subtitles, previews in
            callbackDepth += 1; maximumDepth = max(maximumDepth, callbackDepth)
            surrenderRecord.callback(a)(subtitles, previews)
            if subtitles { surrender.remove(owner: a) }
            callbackDepth -= 1
        }
        check(surrenderRecord.events == [.init(owner: a, subtitles: true, previews: false), .init(owner: a, subtitles: false, previews: false)] && maximumDepth == 1,
              "Removing oneself inside admission produces one iterative revocation instead of recursive callback delivery")

        let fairReentry = SPTorrentBackgroundAdmission(), fairRecord = Record()
        fairReentry.update(owner: a, lifetime: lifeA, wantsSubtitles: true, wantsPreviews: false) { subtitles, previews in
            fairRecord.callback(a)(subtitles, previews)
            if !subtitles && !previews {
                fairReentry.update(owner: a, lifetime: lifeA, wantsSubtitles: true, wantsPreviews: false,
                                   onAdmission: fairRecord.callback(a))
            }
        }
        fairReentry.update(owner: b, lifetime: lifeB, wantsSubtitles: true, wantsPreviews: false, onAdmission: fairRecord.callback(b))
        fairReentry.remove(owner: a)
        check(fairRecord.events.last == .init(owner: b, subtitles: true, previews: false),
              "An owner that re-enters from its revocation callback cannot jump ahead of a queued peer")
        fairReentry.remove(owner: b)
        check(fairRecord.events.last == .init(owner: a, subtitles: true, previews: false),
              "A re-entered request keeps its new FIFO position and is admitted after the peer releases")

        let deep = SPTorrentBackgroundAdmission()
        var transitions = 0, deepDepth = 0, maxDeepDepth = 0
        func churn(_ subtitles: Bool, _ previews: Bool) {
            deepDepth += 1; maxDeepDepth = max(maxDeepDepth, deepDepth)
            transitions += 1
            if transitions < 200 {
                deep.update(owner: a, lifetime: lifeA, wantsSubtitles: !subtitles, wantsPreviews: false, onAdmission: churn)
            } else { deep.remove(owner: a) }
            deepDepth -= 1
        }
        deep.update(owner: a, lifetime: lifeA, wantsSubtitles: true, wantsPreviews: false, onAdmission: churn)
        check(transitions == 64, "Reentrant callbacks have a bounded transition budget per MainActor turn")
        for _ in 0..<100 where transitions < 200 { await Task.yield() }
        check(transitions >= 200 && maxDeepDepth == 1, "Deferred reconciliation finishes a deep finite callback chain without stack recursion")

        let gate = SPTorrentBackgroundGate()
        check(gate.shouldPause(), "The background probe starts paused before admission")
        gate.setPaused(false); check(!gate.shouldPause(), "Admission opens the lock-protected probe")
        gate.setPaused(true); check(gate.shouldPause(), "Revocation immediately closes the probe")
        let openGate = SPTorrentBackgroundGate(initiallyPaused: false)
        check(!openGate.shouldPause(), "An explicit initial gate value is respected")
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<16 {
                group.addTask {
                    for index in 0..<10_000 {
                        gate.setPaused((index + worker).isMultiple(of: 2))
                        _ = gate.shouldPause()
                    }
                }
            }
        }
        gate.setPaused(true)
        check(gate.shouldPause(), "Concurrent native probe reads and admission writes preserve the final synchronized value")
        gate.setPaused(false)
        check(!gate.shouldPause(), "The gate remains reusable after concurrent stress")
        print("PASS: \(count) torrent background admission checks")
    }
}

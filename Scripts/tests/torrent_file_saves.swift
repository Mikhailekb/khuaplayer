import Foundation

private enum SaveFailure: LocalizedError {
    case ownedFixture
    var errorDescription: String? { "Owned fixture failure" }
}

/// A controlled disk-save boundary: no user files, worker or networking. Each
/// suspended transfer has its own delegate and completion, as URLSession does.
@MainActor private final class SaveBoundary {
    final class Request {
        let descriptor: SPTorrentDescriptor
        let file: SPTorrentFile
        let destination: URL
        let replace: Bool
        let progress: SPTorrentFileSaves.Progress
        var continuation: CheckedContinuation<URL, any Error>?
        var cancellationRequested = false
        init(_ descriptor: SPTorrentDescriptor, _ file: SPTorrentFile, _ destination: URL,
             _ replace: Bool, _ progress: @escaping SPTorrentFileSaves.Progress,
             _ continuation: CheckedContinuation<URL, any Error>) {
            self.descriptor = descriptor; self.file = file; self.destination = destination
            self.replace = replace; self.progress = progress; self.continuation = continuation
        }
    }
    var requests: [Request] = []

    func save(_ descriptor: SPTorrentDescriptor, _ file: SPTorrentFile, _ destination: URL,
              _ replace: Bool, _ progress: @escaping SPTorrentFileSaves.Progress) async throws -> URL {
        let requestIndex = requests.count
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                requests.append(Request(descriptor, file, destination, replace, progress, continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.requests.indices.contains(requestIndex) else { return }
                self.requests[requestIndex].cancellationRequested = true
            }
        }
    }
    func progress(_ index: Int, _ received: Int64, _ expected: Int64 = -1) {
        requests[index].progress(.init(receivedBytes: received, expectedBytes: expected))
    }
    func succeed(_ index: Int) {
        let request = requests[index], continuation = requests[index].continuation
        request.continuation = nil
        continuation?.resume(returning: request.destination)
    }
    func fail(_ index: Int, _ error: any Error = SaveFailure.ownedFixture) {
        let request = requests[index], continuation = requests[index].continuation
        request.continuation = nil
        continuation?.resume(throwing: error)
    }
}

@MainActor private final class Completions {
    var success: [URL] = []
    var cancellations = 0
    var failures = 0
    func receive(_ result: Result<URL, any Error>) {
        switch result {
        case .success(let url): success.append(url)
        case .failure(let error):
            if error is CancellationError { cancellations += 1 } else { failures += 1 }
        }
    }
    var count: Int { success.count + cancellations + failures }
}

@main @MainActor private struct TorrentFileSaveChecks {
    static var assertions = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { print("FAIL: \(message)"); exit(1) }
        assertions += 1
        print("PASS \(assertions): \(message)")
    }
    static func settle(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        check(false, "Owned async fixture reached its expected state")
    }
    static func descriptor(_ hash: String = String(repeating: "a", count: 40),
                           files: [SPTorrentFile], lease: UUID = UUID()) -> SPTorrentDescriptor {
        .init(leaseID: lease, hash: hash, name: "Owned show", files: files, originalLink: nil)
    }
    static func main() async {
        let a = SPTorrentFile(id: 1, path: "Season 1/one.mkv", length: 1000)
        let b = SPTorrentFile(id: 2, path: "Season 1/two.mp4", length: 2000)
        let source = descriptor(files: [a, b]), boundary = SaveBoundary(), completions = Completions()
        let store = SPTorrentFileSaves(saver: boundary.save)
        var notifications = 0
        store.onChange = { notifications += 1 }
        let firstDestination = URL(fileURLWithPath: "/owned-fixture/one.mkv")
        let secondDestination = URL(fileURLWithPath: "/owned-fixture/two.mp4")
        check(store.start(descriptor: source, file: a, to: firstDestination, replaceExisting: true,
                          completion: { completions.receive($0) }), "First playlist file starts independently")
        check(!store.start(descriptor: source, file: b, to: firstDestination),
              "Two playlist files cannot concurrently write the same destination")
        check(!store.start(descriptor: source, file: b,
                           to: URL(fileURLWithPath: "/owned-fixture/nested/../one.mkv")),
              "Standardized destination aliases cannot bypass the active writer guard")
        check(store.start(descriptor: source, file: b, to: secondDestination,
                          completion: { completions.receive($0) }), "A second playlist file can download concurrently")
        check(store.activeCount == 2 && store.snapshots.count == 2, "Each transfer owns a distinct visible row")
        check(store.snapshot(descriptor: source, file: a)?.fraction == 0, "Initial progress is known zero from manifest length")
        check(!store.start(descriptor: source, file: a, to: firstDestination), "Duplicate active save cannot create another destination writer")
        let sameContentOtherLease = descriptor(source.hash.uppercased(), files: [a, b])
        check(!store.start(descriptor: sameContentOtherLease, file: a, to: firstDestination), "Changing lease/hash case does not duplicate a content-identical file")
        await settle { boundary.requests.count == 2 }
        check(boundary.requests[0].descriptor == source && boundary.requests[0].file == a,
              "The save receives its captured descriptor and requested unselected file")
        check(boundary.requests[0].replace && !boundary.requests[1].replace,
              "Destination replacement permission is isolated per request")
        boundary.progress(0, 250)
        boundary.progress(1, 1300, 9000)
        check(store.snapshot(descriptor: source, file: a)?.fraction == 0.25,
              "Unknown HTTP length uses authoritative file length")
        check(store.snapshot(descriptor: source, file: b)?.fraction == 0.65,
              "Wrong HTTP expected length cannot corrupt per-file percentage")
        let unchanged = notifications
        boundary.progress(0, -1); boundary.progress(0, 100)
        check(store.snapshot(descriptor: source, file: a)?.receivedBytes == 250 && notifications == unchanged,
              "Out-of-order/negative progress does not jump backwards or redraw")
        boundary.progress(1, Int64.max)
        check(store.snapshot(descriptor: source, file: b)?.receivedBytes == 2000,
              "Oversized progress is clamped without overflow")
        boundary.fail(0)
        boundary.succeed(1)
        await settle { store.activeCount == 0 && completions.count == 2 }
        check(store.snapshot(descriptor: source, file: a)?.phase == .failed && completions.failures == 1,
              "One failed file does not fail its sibling")
        check(store.snapshot(descriptor: source, file: b)?.phase == .saved && completions.success == [secondDestination],
              "A completed file retains its successful destination and final progress")
        check(store.snapshot(descriptor: source, file: a)?.failureDescription == "Owned fixture failure",
              "Failure detail remains available for retry UI")
        boundary.progress(0, 990)
        check(store.snapshot(descriptor: source, file: a)?.receivedBytes == 250,
              "A delayed delegate cannot revive completed work")

        check(store.start(descriptor: source, file: a, to: firstDestination,
                          completion: { completions.receive($0) }), "A failed file can be retried")
        await settle { boundary.requests.count == 3 }
        boundary.progress(0, 999)
        check(store.snapshot(descriptor: source, file: a)?.receivedBytes == 0,
              "A previous attempt cannot advance a new attempt for the same file")
        boundary.progress(2, 400)
        store.cancel(descriptor: source, file: a)
        check(store.snapshot(descriptor: source, file: a)?.phase == .cancelling && store.activeCount == 1,
              "Cancellation remains active until its actual save acknowledges it")
        check(!store.start(descriptor: source, file: a, to: firstDestination),
              "Retry cannot overlap a still-draining cancellation")
        boundary.progress(2, 800)
        check(store.snapshot(descriptor: source, file: a)?.receivedBytes == 400,
              "Cancelled transfers stop accepting progress immediately")
        await settle { boundary.requests[2].cancellationRequested }
        boundary.succeed(2) // Transport completion racing cancellation is intentional.
        await settle { store.activeCount == 0 && completions.count == 3 }
        check(store.snapshot(descriptor: source, file: a)?.phase == .cancelled && completions.cancellations == 1,
              "A late transport success after cancel cannot mark the file saved")

        let otherTorrent = descriptor(String(repeating: "b", count: 40), files: [a, b])
        check(store.start(descriptor: source, file: a, to: firstDestination,
                          completion: { completions.receive($0) }), "A cancelled file can restart after cancellation acknowledgement")
        check(store.start(descriptor: otherTorrent, file: a, to: URL(fileURLWithPath: "/owned-fixture/other/one.mkv"),
                          completion: { completions.receive($0) }), "Different torrents with the same file index/path remain separate")
        await settle { boundary.requests.count == 5 }
        boundary.progress(3, 100); boundary.progress(4, 600)
        check(store.snapshot(descriptor: source, file: a)?.receivedBytes == 100
              && store.snapshot(descriptor: otherTorrent, file: a)?.receivedBytes == 600,
              "Switching the displayed playlist cannot redirect an older file's progress")
        check(store.snapshots.count == 3, "Finished sibling state survives selecting another episode or torrent")
        store.cancelAll(clear: true)
        check(store.snapshots.isEmpty && store.activeCount == 2,
              "Closing clears visible state while draining both actual cancellation leases")
        check(!store.start(descriptor: descriptor(String(repeating: "c", count: 40), files: [a]),
                           file: a, to: firstDestination),
              "A cleared but draining writer still reserves its destination against another torrent")
        boundary.progress(3, 900); boundary.progress(4, 900)
        check(store.snapshots.isEmpty, "Late delegates cannot reinsert cleared playlist rows")
        boundary.fail(3, CancellationError()); boundary.fail(4, CancellationError())
        await settle { store.activeCount == 0 && completions.count == 5 }
        check(store.snapshots.isEmpty && completions.cancellations == 3,
              "Every started save completes once, including cleared transfers")

        let invalid = SPTorrentFile(id: 1, path: a.path, length: 999)
        let zero = SPTorrentFile(id: 3, path: "empty.mp4", length: 0)
        check(!store.start(descriptor: source, file: invalid, to: firstDestination),
              "A file with stale immutable length is rejected before networking")
        check(!store.start(descriptor: descriptor(files: [zero]), file: zero, to: firstDestination),
              "Empty files do not produce undefined progress")
        check(!store.start(descriptor: source, file: a, to: URL(string: "https://example.invalid/file")!),
              "Destination must be a local file URL")
        let zeroID = SPTorrentFile(id: 0, path: "zero-id.mp4", length: 1000)
        check(!store.start(descriptor: descriptor(files: [zeroID]), file: zeroID, to: firstDestination),
              "Zero torrent indices are rejected consistently with the worker stream API")
        check(!store.start(descriptor: descriptor(String(repeating: "z", count: 40), files: [a]),
                           file: a, to: firstDestination), "Malformed hash identities are rejected before creating a job")
        check(!store.start(descriptor: descriptor("", files: [a]), file: a, to: firstDestination),
              "An empty torrent identity cannot begin a save")
        check(boundary.requests.count == 5 && completions.count == 5,
              "Rejected starts never call the transport or completion")

        let ownerBoundary = SaveBoundary(), ownerCompletions = Completions()
        var owner: SPTorrentFileSaves? = SPTorrentFileSaves(saver: ownerBoundary.save)
        weak let weakOwner = owner
        check(owner!.start(descriptor: source, file: a, to: firstDestination,
                           completion: { ownerCompletions.receive($0) }), "An owned request begins before coordinator teardown")
        await settle { ownerBoundary.requests.count == 1 }
        owner = nil
        check(weakOwner == nil, "The running task/delegate does not keep its window coordinator alive")
        await settle { ownerBoundary.requests[0].cancellationRequested }
        ownerBoundary.fail(0, CancellationError())
        await settle { ownerCompletions.count == 1 }
        check(ownerCompletions.cancellations == 1,
              "Owner teardown cancels transport and still releases the caller's security grant")

        let immediateBoundary = SaveBoundary(), immediateCompletions = Completions()
        var immediate: SPTorrentFileSaves? = SPTorrentFileSaves(saver: immediateBoundary.save)
        check(immediate!.start(descriptor: source, file: a, to: firstDestination,
                               completion: { immediateCompletions.receive($0) }),
              "A pending main-actor save can own a security grant before transport startup")
        immediate = nil
        await settle { immediateCompletions.count == 1 }
        check(immediateBoundary.requests.isEmpty && immediateCompletions.cancellations == 1,
              "Closing before task startup skips transport but still completes cancellation exactly once")

        let cancelBoundary = SaveBoundary(), cancelStore = SPTorrentFileSaves(saver: cancelBoundary.save)
        check(cancelStore.start(descriptor: source, file: a, to: firstDestination), "Visible cancellation fixture starts")
        await settle { cancelBoundary.requests.count == 1 }
        cancelStore.cancelAll(clear: false)
        check(cancelStore.snapshot(descriptor: source, file: a)?.phase == .cancelling,
              "Cancel-all can preserve a cancelling row for visible feedback")
        cancelBoundary.fail(0, CancellationError())
        await settle { cancelStore.activeCount == 0 }
        check(cancelStore.snapshot(descriptor: source, file: a)?.phase == .cancelled,
              "Visible cancellation settles into a retryable terminal row")
        print("PASS \(assertions) concurrent torrent file-save checks")
    }
}

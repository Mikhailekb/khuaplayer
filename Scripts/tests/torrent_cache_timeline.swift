import Foundation
import CoreFoundation

// INSERT_PRESENTATION

private struct SPTorrentPlaybackContext {
    struct Descriptor { let leaseID = UUID() }
    struct File { var id = 7; let length: Int64 = 1_000_000 }
    let descriptor = Descriptor()
    var file = File()
}
private struct SPTorrentCacheSnapshot {
    struct Span { let lowerBound: Int64; let upperBound: Int64 }
    var fileID = 7
    var fileLength: Int64 = 1_000_000
    var ranges = [Span(lowerBound: 1234, upperBound: 4567)]
}
@MainActor private final class Core {
    enum Reason { case none, sourceIO, pipeline }
    var duration = 100.0
    var sourceStalled = false
    var contentSearching = false
    var sourcePlaybackWaitReason = Reason.none
    var payload = fixturePayload()
    var received: [[NSNumber]] = []
    func cachedTimeline(forByteRanges bytes: [[NSNumber]]) -> [String: Any] {
        received = bytes
        var result = payload
        if bytes.isEmpty { result["videoRanges"] = [[Double]]() }
        return result
    }
}
@MainActor private final class Rail {
    var ranges: [ClosedRange<Double>] = []
    var visible = false
    var updates = 0
    func setBufferedRanges(_ ranges: [ClosedRange<Double>], visible: Bool) {
        self.ranges = ranges; self.visible = visible; updates += 1
    }
}
@MainActor private final class Notice {
    var text: String?
    func setSticky(_ text: String?) { self.text = text }
}
private func L(_ key: String) -> String { key }
private func fixturePayload() -> [String: Any] {
    ["openGeneration": 3, "seekGeneration": 4, "duration": 100.0,
     "sourceSize": Int64(1_000_000), "mappingAvailable": false,
     "videoMappingAvailable": true, "completeIndex": false,
     "ranges": [[Double]](), "videoRanges": [[10.0,20.0],[40.0,50.0]]]
}
@MainActor private final class Controller {
    var torrentContext: SPTorrentPlaybackContext? = SPTorrentPlaybackContext()
    var torrentLastCacheSnapshot: SPTorrentCacheSnapshot?
    var torrentTimelinePresentation: SPTorrentTimelinePresentation?
    var core: Core? = Core()
    var hasMediaSession = true
    var chrome: Rail? = Rail()
    let floatingVideo = Rail()
    let notice = Notice()
    var playbackNotice: Notice? { notice }
    func playbackNoticeView() -> Notice { notice }
    func apply(_ snapshot: SPTorrentCacheSnapshot, context: SPTorrentPlaybackContext) {
        applyTorrentCacheSnapshot(snapshot, context: context)
    }
    func clear() { clearTorrentCacheTimeline(visible: false) }
    func updateNotice(waiting: Bool) {
        let core = self.core!
        // INSERT_WAIT_NOTICE
    }
    // INSERT_CONTROLLER
}

@main @MainActor private struct CachedTimelineChecks {
    static var count = 0
    static func check(_ value: Bool, _ text: String) {
        guard value else { fatalError("FAIL: \(text)") }
        count += 1; print("PASS \(count): \(text)")
    }
    static func parse(_ payload: [String: Any]) -> SPTorrentTimelinePresentation? {
        SPTorrentTimelinePresentation(payload: payload, expectedDuration: 100, expectedSourceSize: 1_000_000)
    }
    static func main() {
        let payload = fixturePayload()
        let mapped = parse(payload)!
        check(mapped.normalizedRanges == [0.1...0.2,0.4...0.5], "Native time intervals preserve a real uncached gap")
        check(mapped.mappingAvailable && !mapped.completeIndex, "Video coverage is useful without claiming a complete A/V index")
        var changed = payload
        changed["videoRanges"] = [[40.0,50.0],[10.0,15.0],[15.0,20.0]]
        check(parse(changed)?.normalizedRanges == mapped.normalizedRanges, "Only adjacent or overlapping time ranges merge")
        changed["videoRanges"] = [[10.0,20.0],[20.001,25.0]]
        check(parse(changed)?.normalizedRanges.count == 2, "A small actual hole is never rounded away")
        changed["videoRanges"] = [[Double]]()
        check(parse(changed)?.normalizedRanges.isEmpty == true, "Empty video coverage cannot borrow unrelated audio-ready ranges")
        for invalid: Any in [[[Double.nan,20]],[[10,Double.infinity]],[[20,10]],[[-1,5]],[[10,101]],[[10,20,30]],[[true,20]],[[100.00000001,100.00000002]]] {
            changed = payload; changed["videoRanges"] = invalid
            check(parse(changed) == nil, "Malformed or out-of-source native time intervals fail closed")
        }
        for key in ["duration","sourceSize","openGeneration","seekGeneration"] {
            changed = payload; changed[key] = true
            check(parse(changed) == nil, "A Boolean is not numeric source metadata")
        }
        changed = payload; changed["duration"] = 99.0
        check(parse(changed) == nil, "Another duration cannot paint this timeline")
        changed = payload; changed["sourceSize"] = 999_999
        check(parse(changed) == nil, "Another file size cannot paint this source")
        changed = payload; changed["videoMappingAvailable"] = false
        check(parse(changed)?.normalizedRanges.isEmpty == true, "Unknown mapping paints no invented time coverage")
        changed = payload; changed["videoStream"] = -1; changed["audioStream"] = 0
        changed["audioMappingAvailable"] = true; changed["audioRanges"] = [[20.0,30.0]]
        check(parse(changed)?.normalizedRanges == [0.2...0.3], "Audio-only media uses the selected audio's actual byte-time mapping")

        let controller = Controller(); let original = controller.torrentContext!
        let snapshot = SPTorrentCacheSnapshot()
        controller.apply(snapshot, context: original)
        check(controller.chrome!.ranges == mapped.normalizedRanges && controller.floatingVideo.ranges == mapped.normalizedRanges,
              "Production controller sends identical native coverage to main and PiP timelines")
        check(controller.core!.received == [[1234,4567]], "Only exact file-relative byte bounds cross the native bridge")
        let updates = controller.chrome!.updates
        var nextEpisode = original; nextEpisode.file.id = 8
        controller.torrentContext = nextEpisode
        controller.apply(snapshot, context: original)
        check(controller.chrome!.updates == updates, "A late previous episode cannot repaint another file within the same torrent lease")
        controller.torrentContext = SPTorrentPlaybackContext()
        controller.apply(snapshot, context: original)
        check(controller.chrome!.updates == updates, "A late snapshot from an old source lease cannot repaint the new source")
        let current = controller.torrentContext!
        var wrong = snapshot; wrong.fileID = 8
        controller.apply(wrong, context: current)
        wrong = snapshot; wrong.fileLength += 1
        controller.apply(wrong, context: current)
        check(controller.chrome!.updates == updates, "Wrong selected file or source length cannot publish cache coverage")
        controller.core!.payload["duration"] = 90
        controller.apply(snapshot, context: current)
        check(controller.chrome!.ranges.isEmpty && controller.floatingVideo.ranges.isEmpty,
              "A mismatched native source clears stale coverage in both timelines")
        controller.core!.payload = payload
        controller.apply(snapshot, context: current)
        var empty = snapshot; empty.ranges = []
        controller.apply(empty, context: current)
        check(controller.chrome!.ranges.isEmpty && controller.chrome!.visible, "Eviction replaces old coverage with an explicit empty rail")
        controller.clear()
        check(controller.torrentLastCacheSnapshot == nil && !controller.chrome!.visible && !controller.floatingVideo.visible,
              "Source close clears old cache state and returns local playback to its original timeline")

        controller.core!.sourcePlaybackWaitReason = .pipeline
        controller.core!.sourceStalled = true
        controller.updateNotice(waiting: true)
        check(controller.notice.text == "playback.notice.preparingPlayback", "An actual pipeline hold is not described as downloading")
        controller.core!.sourcePlaybackWaitReason = .sourceIO
        controller.core!.sourceStalled = false
        controller.updateNotice(waiting: true)
        check(controller.notice.text == "playback.notice.waitingForDownload", "A pending source read retains its network-loading notice")
        controller.core!.sourceStalled = true
        controller.updateNotice(waiting: true)
        check(controller.notice.text == "playback.notice.downloadStalled", "A stalled source request keeps its specific explanation")
        controller.updateNotice(waiting: false)
        check(controller.notice.text == nil, "Waiting recovery clears the reason notice")
        print("Cached timeline presentation checks passed (\(count) assertions).")
    }
}

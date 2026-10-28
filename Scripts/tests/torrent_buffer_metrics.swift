import Foundation

@main struct Checks {
    static func main() {
        var count = 0
        func expect(_ ok: @autoclosure () -> Bool, _ name: String) {
            precondition(ok(), name); count += 1
        }
        let hash = String(repeating: "a", count: 40)
        let file = SPTorrentFile(id: 1, path: "Season/episode.mp4", length: 1_000)
        func cache(_ ranges: [[Int64]]) -> SPTorrentCacheSnapshot {
            let resident = ranges.reduce(Int64(0)) { $0 + $1[1] - $1[0] }
            return SPTorrentCacheSnapshot(json: ["hash": hash, "file_index": 1,
                "file_offset": 0, "file_length": 1_000, "piece_length": 10,
                "resident_bytes": resident, "ranges": ranges], expectedHash: hash, file: file)!
        }
        func measure(_ ranges: [[Int64]], _ offset: Int64 = 100, _ upper: Int64 = 600) -> SPTorrentBufferMetrics? {
            .init(cache: cache(ranges), file: file, playbackOffset: offset, forwardUpperBound: upper)
        }
        let fragmented = measure([[0, 50], [100, 200], [210, 1_000]])!
        expect(fragmented.aheadBytes == 100, "a large distant cache cannot cross a ten-byte hole")
        expect(fragmented.targetBytes == 500, "target is the approved forward window, not global RAM size")
        expect(fragmented.fraction == 0.2, "only the contiguous resident prefix fills the bar")
        expect(measure([[110, 1_000]])?.aheadBytes == 0, "a missing current piece is zero even with890bytes elsewhere")
        expect(measure([[0, 100], [110, 1_000]])?.aheadBytes == 0, "half-open end does not bridge current gap")
        expect(measure([[100, 1_000]])?.aheadBytes == 500, "cap resident extent at worker-approved bound")
        expect(measure([[100, 1_000]])?.fraction == 1, "a complete forward window is full")
        expect(measure([[100, 200]], 150, 600)?.aheadBytes == 50, "playback consumes the prefix")
        expect(measure([[0, 100], [200, 1_000]], 500, 800)?.aheadBytes == 300, "seek measures the new position")
        expect(measure([[0, 200]], 500, 800)?.aheadBytes == 0, "old cached scene is not the new buffer")
        expect(measure([])?.aheadBytes == 0, "known empty cache is zero")
        expect(measure([[100, 200]], 200, 600)?.aheadBytes == 0, "last cached byte is not an extra piece")
        expect(measure([[0, 1_000]], 1_000, 1_000)?.targetBytes == 0, "end of file is an empty target")
        expect(measure([[0, 1_000]], 1_000, 1_000)?.fraction == nil, "no divide by zero or invented100percent atEOF")
        expect(measure([], -1, 600) == nil, "unknown playback anchor stays unknown")
        expect(measure([], 601, 600) == nil, "stale forward bound stays unknown")
        expect(measure([], 100, 1_001) == nil, "out-of-file bound rejected")
        expect(SPTorrentBufferMetrics(cache: nil, file: file, playbackOffset: 100, forwardUpperBound: 600) == nil,
               "absent observation is not zero or filled")
        expect(SPTorrentBufferMetrics(cache: cache([[100, 200]]),
            file: SPTorrentFile(id: 2, path: file.path, length: file.length),
            playbackOffset: 100, forwardUpperBound: 600) == nil, "another file cannot paint this row")
        expect(SPTorrentBufferMetrics(cache: cache([[100, 200]]),
            file: SPTorrentFile(id: 1, path: file.path, length: 2_000),
            playbackOffset: 100, forwardUpperBound: 600) == nil, "changed manifest length rejected")
        print("PASS \(count) contiguous resident buffer metrics checks")
    }
}

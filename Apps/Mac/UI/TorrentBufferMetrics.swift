import Foundation

/// An observation of complete resident bytes immediately ahead of playback.
/// Neither peer traffic nor the prefetch reader's cumulative HTTP progress is a
/// substitute: distant pieces and holes cannot extend this contiguous prefix.
struct SPTorrentBufferMetrics: Equatable {
    let aheadBytes: Int64
    let targetBytes: Int64

    var fraction: Double? {
        guard targetBytes > 0 else { return nil }
        return min(1, max(0, Double(aheadBytes) / Double(targetBytes)))
    }

    init?(cache: SPTorrentCacheSnapshot?, file: SPTorrentFile,
          playbackOffset: Int64, forwardUpperBound: Int64) {
        guard let cache, cache.fileID == file.id, cache.fileLength == file.length,
              playbackOffset >= 0, playbackOffset <= file.length,
              forwardUpperBound >= playbackOffset, forwardUpperBound <= file.length else { return nil }
        targetBytes = forwardUpperBound - playbackOffset
        let extent = cache.ranges.first {
            $0.lowerBound <= playbackOffset && playbackOffset < $0.upperBound
        }
        aheadBytes = extent.map { min($0.upperBound, forwardUpperBound) - playbackOffset } ?? 0
    }
}

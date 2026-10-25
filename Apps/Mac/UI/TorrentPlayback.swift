import Foundation
import CoreFoundation

// BEGIN_BUFFERED_TIMELINE_PRESENTATION
/// Display only time intervals supplied by the current source's native map.
/// Cache byte counts are never converted to time by a file-size proportion.
struct SPTorrentTimelinePresentation: Equatable {
    let openGeneration: Int64
    let seekGeneration: Int64
    let duration: Double
    let mappingAvailable: Bool
    let completeIndex: Bool
    let unmappedResidentBytes: Int64
    let normalizedRanges: [ClosedRange<Double>]

    init?(payload: [String: Any], expectedDuration: Double, expectedSourceSize: Int64) {
        guard expectedDuration.isFinite, expectedDuration > 0,
              let open = Self.integer(payload["openGeneration"]), open >= 0,
              let seek = Self.integer(payload["seekGeneration"]), seek >= 0,
              let duration = Self.number(payload["duration"]), duration > 0,
              let sourceSize = Self.integer(payload["sourceSize"]), sourceSize == expectedSourceSize,
              sourceSize > 0,
              abs(duration - expectedDuration) <= 0.05,
              let complete = payload["completeIndex"] as? Bool else { return nil }
        let audioOnly = Self.integer(payload["videoStream"]) == -1 &&
            (Self.integer(payload["audioStream"]) ?? -1) >= 0
        let flag = audioOnly ? payload["audioMappingAvailable"] : payload["videoMappingAvailable"]
        guard let available = (flag ?? payload["mappingAvailable"]) as? Bool else { return nil }
        let unmapped: Int64
        if let raw = payload["unmappedResidentBytes"] {
            guard let value = Self.integer(raw), value >= 0, value <= sourceSize else { return nil }
            unmapped = value
        } else { unmapped = 0 }
        let raw = (audioOnly ? payload["audioRanges"] : payload["videoRanges"]) ?? payload["ranges"]
        guard let pairs = raw as? [[Any]], pairs.count <= 131_072 else { return nil }
        var ranges: [ClosedRange<Double>] = []
        for pair in pairs {
            guard pair.count == 2, let lower = Self.number(pair[0]),
                  let upper = Self.number(pair[1]), lower >= 0, lower < duration,
                  lower < upper, upper <= duration + 0.000_001 else { return nil }
            if available { ranges.append((lower / duration)...min(1, upper / duration)) }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for range in ranges {
            if let previous = merged.last, range.lowerBound <= previous.upperBound {
                merged[merged.count - 1] = previous.lowerBound...max(previous.upperBound, range.upperBound)
            } else { merged.append(range) }
        }
        self.openGeneration = open
        self.seekGeneration = seek
        self.duration = duration
        self.mappingAvailable = available
        self.completeIndex = complete
        unmappedResidentBytes = unmapped
        normalizedRanges = merged
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let value = value as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return Int64(value.stringValue)
    }
}
// END_BUFFERED_TIMELINE_PRESENTATION

/// Stable media identities are independent of the worker's private port and
/// credentials. They share the local playlist's settings and resume policies.
struct SPTorrentPlaybackContext: Sendable {
    let descriptor: SPTorrentDescriptor
    let file: SPTorrentFile
    let streamURL: URL

    var rootURL: URL {
        let title = (descriptor.name as NSString).lastPathComponent
        let safeTitle = title.isEmpty || title == "." || title == ".." ? descriptor.hash : title
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/Khua/Torrent Playlists", isDirectory: true)
            .appendingPathComponent(descriptor.hash, isDirectory: true)
            .appendingPathComponent(safeTitle, isDirectory: true)
    }

    var playableFiles: [SPTorrentFile] { descriptor.files.filter(\.isPlayable) }
    var identityURL: URL { identityURL(for: file) }

    func identityURL(for file: SPTorrentFile) -> URL {
        rootURL.appendingPathComponent(file.path, isDirectory: false)
    }

    var entries: [SPPlaylistEntry] {
        playableFiles.map { item in
            let prefix = descriptor.name + "/"
            let relative = item.path.hasPrefix(prefix) ? String(item.path.dropFirst(prefix.count)) : item.path
            return SPPlaylistEntry(url: identityURL(for: item), relativePath: relative,
                displayName: item.displayName, isGrowing: false)
        }
    }

    func file(for identity: URL) -> SPTorrentFile? {
        playableFiles.first { identityURL(for: $0) == identity.standardizedFileURL }
    }
}

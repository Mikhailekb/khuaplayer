import Foundation
import CryptoKit
import CoreFoundation

/// Half-open, file-relative bytes backed by complete resident torrent pieces.
struct SPTorrentCachedByteRange: Equatable, Sendable {
    let lowerBound: Int64
    let upperBound: Int64
}

/// A cache observation, independent of download totals and retention budgets.
/// Holes remain holes; consumers must not interpolate missing media bytes.
struct SPTorrentCacheSnapshot: Equatable, Sendable {
    let fileID: Int
    let fileOffset: Int64
    let fileLength: Int64
    let pieceLength: Int64
    let residentBytes: Int64
    let ranges: [SPTorrentCachedByteRange]

    init?(json: Any, expectedHash: String, file: SPTorrentFile) {
        guard let object = json as? [String: Any],
              object["hash"] as? String == expectedHash,
              Self.integer(object["file_index"]) == Int64(file.id),
              let offset = Self.integer(object["file_offset"]), offset >= 0,
              let length = Self.integer(object["file_length"]), length > 0, length == file.length,
              offset <= Int64.max - length,
              let piece = Self.integer(object["piece_length"]), piece > 0,
              let resident = Self.integer(object["resident_bytes"]), resident >= 0, resident <= length,
              let encoded = object["ranges"] as? [[Any]], encoded.count <= 32_768 else { return nil }
        var parsed: [SPTorrentCachedByteRange] = []
        parsed.reserveCapacity(encoded.count)
        var count: Int64 = 0
        for pair in encoded {
            guard pair.count == 2, let lower = Self.integer(pair[0]), let upper = Self.integer(pair[1]),
                  lower >= 0, upper > lower, upper <= length,
                  parsed.last.map({ $0.upperBound < lower }) ?? true,
                  lower == 0 || (offset + lower) % piece == 0,
                  upper == length || (offset + upper) % piece == 0 else { return nil }
            let (sum, overflow) = count.addingReportingOverflow(upper - lower)
            guard !overflow, sum <= length else { return nil }
            count = sum
            parsed.append(SPTorrentCachedByteRange(lowerBound: lower, upperBound: upper))
        }
        guard count == resident else { return nil }
        fileID = file.id
        fileOffset = offset
        fileLength = length
        pieceLength = piece
        residentBytes = resident
        ranges = parsed
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int64(number.stringValue)
    }
}

struct SPTorrentFile: Codable, Equatable, Sendable, Identifiable {
    let id: Int
    let path: String
    let length: Int64

    var displayName: String { (path as NSString).lastPathComponent }

    var isPlayable: Bool {
        Self.playableExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    private static let playableExtensions: Set<String> = [
        "mp4", "mkv", "mov", "m4v", "avi", "webm", "ts", "m2ts", "mts",
        "mpg", "mpeg", "vob", "wmv", "flv", "ogv", "3gp", "mp3", "m4a",
        "flac", "wav", "aac", "ogg", "opus", "aiff", "alac"
    ]
}

struct SPTorrentDescriptor: Sendable, Equatable {
    let leaseID: UUID
    let hash: String
    let name: String
    let files: [SPTorrentFile]
    let originalLink: String?
    /// Original metainfo, shared by value across leases. Durable history writes
    /// it to a bounded private sidecar, never into the recent-play JSON ledger.
    let originalTorrentData: Data?

    init(leaseID: UUID, hash: String, name: String, files: [SPTorrentFile],
         originalLink: String?, originalTorrentData: Data? = nil) {
        self.leaseID = leaseID
        self.hash = hash
        self.name = name
        self.files = files
        self.originalLink = originalLink
        self.originalTorrentData = originalTorrentData
    }
}

struct SPTorrentStatus: Sendable {
    let hash: String
    let name: String
    let files: [SPTorrentFile]
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double
    let loadedBytes: Int64
    let totalBytes: Int64
    let bufferedBytes: Int64
    let bufferCapacityBytes: Int64
    let preloadedBytes: Int64
    let preloadTargetBytes: Int64
    let activePeers: Int
    let totalPeers: Int
    let connectedSeeders: Int
    let statusCode: Int
    let statusText: String

    init(json: [String: Any], cache: [String: Any]? = nil) {
        hash = (json["hash"] as? String ?? "").lowercased()
        name = json["name"] as? String ?? json["title"] as? String ?? ""
        let fileObjects = json["file_stats"] as? [[String: Any]] ?? []
        files = fileObjects.map { file in
            SPTorrentFile(
                id: Int(Self.integer(file["id"]) ?? 0),
                path: file["path"] as? String ?? "",
                length: Self.integer(file["length"]) ?? 0
            )
        }
        downloadBytesPerSecond = Self.rate(json["download_speed"])
        uploadBytesPerSecond = Self.rate(json["upload_speed"])
        loadedBytes = Self.integer(json["loaded_size"]) ?? 0
        totalBytes = Self.integer(json["torrent_size"]) ?? 0
        bufferedBytes = Self.integer(cache?["Filled"]) ?? Self.integer(json["buffered_bytes"]) ?? 0
        bufferCapacityBytes = Self.integer(cache?["Capacity"]) ?? Self.integer(json["buffer_capacity_bytes"]) ?? 0
        preloadedBytes = Self.integer(json["preloaded_bytes"]) ?? 0
        preloadTargetBytes = Self.integer(json["preload_size"]) ?? 0
        activePeers = Int(Self.integer(json["active_peers"]) ?? 0)
        totalPeers = Int(Self.integer(json["total_peers"]) ?? 0)
        connectedSeeders = Int(Self.integer(json["connected_seeders"]) ?? 0)
        statusCode = Int(Self.integer(json["stat"]) ?? 0)
        statusText = json["stat_string"] as? String ?? ""
    }

    private static func integer(_ value: Any?) -> Int64? {
        let text: String
        if let string = value as? String {
            text = string
        } else if let number = value as? NSNumber {
            text = number.stringValue
        } else {
            return nil
        }
        if let integer = Int64(text) { return max(0, integer) }
        guard let number = Double(text), number.isFinite, number >= 0,
              number < Double(Int64.max) else { return nil }
        return Int64(number)
    }

    private static func rate(_ value: Any?) -> Double {
        let number: Double?
        if let string = value as? String {
            number = Double(string)
        } else if let value = value as? NSNumber {
            number = value.doubleValue
        } else {
            number = nil
        }
        guard let number, number.isFinite else { return 0 }
        return max(0, number)
    }
}

enum SPTorrentInputError: LocalizedError {
    case invalidTorrent
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidTorrent:
            return "This torrent file is invalid or unsupported."
        case .tooLarge:
            return "This torrent file is too large. The maximum size is 32 MiB."
        }
    }
}

enum SPTorrentInput {
    static func normalizedHash(_ hash: String) -> String? {
        guard hash.utf8.count == 40,
              hash.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
        else { return nil }
        return hash.lowercased()
    }

    static func magnetHash(_ link: String) -> String? {
        guard let components = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "magnet" else { return nil }
        for item in components.queryItems ?? [] where item.name.lowercased() == "xt" {
            guard let value = item.value, value.lowercased().hasPrefix("urn:btih:") else { continue }
            let hash = String(value.dropFirst(9))
            if let normalized = normalizedHash(hash) { return normalized }
            if let bytes = decodeBase32Hash(hash) {
                return bytes.map { String(format: "%02x", $0) }.joined()
            }
        }
        return nil
    }

    static func infoHash(in data: Data) throws -> String {
        guard data.count <= 32 * 1_024 * 1_024 else { throw SPTorrentInputError.tooLarge }
        let range = try data.withUnsafeBytes { buffer in
            var scanner = BencodeScanner(bytes: buffer.bindMemory(to: UInt8.self))
            return try scanner.infoRange()
        }
        // Hash the original encoded value; decoding and re-encoding can change its identity.
        let info = data.dropFirst(range.lowerBound).prefix(range.count)
        return Insecure.SHA1.hash(data: info).map { String(format: "%02x", $0) }.joined()
    }

    private static func decodeBase32Hash(_ hash: String) -> [UInt8]? {
        let characters = Array(hash.utf8)
        guard characters.count == 32 else { return nil }
        var accumulator: UInt32 = 0
        var bitCount = 0
        var result: [UInt8] = []
        result.reserveCapacity(20)
        for character in characters {
            let value: UInt32
            switch character {
            case 65...90: value = UInt32(character - 65)
            case 97...122: value = UInt32(character - 97)
            case 50...55: value = UInt32(character - 50 + 26)
            default: return nil
            }
            accumulator = (accumulator << 5) | value
            bitCount += 5
            if bitCount >= 8 {
                bitCount -= 8
                result.append(UInt8((accumulator >> bitCount) & 0xff))
                accumulator &= (1 << bitCount) - 1
            }
        }
        return result.count == 20 ? result : nil
    }

    private struct BencodeScanner {
        let bytes: UnsafeBufferPointer<UInt8>
        var position = 0
        var items = 0

        mutating func infoRange() throws -> Range<Int> {
            try consumeItem(depth: 0)
            guard current == 100 else { throw SPTorrentInputError.invalidTorrent }
            position += 1
            var info: Range<Int>?
            var keys = Set<Data>()
            while current != 101 {
                let key = try string(depth: 1)
                guard keys.insert(Data(bytes[key])).inserted else { throw SPTorrentInputError.invalidTorrent }
                let isInfo = key.count == 4 && bytes[key.lowerBound] == 105 &&
                    bytes[key.lowerBound + 1] == 110 && bytes[key.lowerBound + 2] == 102 &&
                    bytes[key.lowerBound + 3] == 111
                let start = position
                if isInfo && (info != nil || current != 100) { throw SPTorrentInputError.invalidTorrent }
                try value(depth: 1)
                if isInfo { info = start..<position }
            }
            position += 1
            guard position == bytes.count, let info else { throw SPTorrentInputError.invalidTorrent }
            return info
        }

        private var current: UInt8? { position < bytes.count ? bytes[position] : nil }

        private mutating func consumeItem(depth: Int) throws {
            guard depth <= 64, items < 1_000_000 else { throw SPTorrentInputError.invalidTorrent }
            items += 1
        }

        private mutating func value(depth: Int) throws {
            try consumeItem(depth: depth)
            switch current {
            case 105:
                try integer()
            case 108:
                position += 1
                while current != 101 { try value(depth: depth + 1) }
                position += 1
            case 100:
                position += 1
                var keys = Set<Data>()
                while current != 101 {
                    let key = try string(depth: depth + 1)
                    guard keys.insert(Data(bytes[key])).inserted else { throw SPTorrentInputError.invalidTorrent }
                    try value(depth: depth + 1)
                }
                position += 1
            case .some(48...57):
                _ = try stringBody()
            default:
                throw SPTorrentInputError.invalidTorrent
            }
        }

        private mutating func string(depth: Int) throws -> Range<Int> {
            try consumeItem(depth: depth)
            return try stringBody()
        }

        private mutating func stringBody() throws -> Range<Int> {
            let start = position
            var length = 0
            while let character = current, (48...57).contains(character) {
                let digit = Int(character - 48)
                guard length <= (Int.max - digit) / 10 else { throw SPTorrentInputError.invalidTorrent }
                length = length * 10 + digit
                position += 1
            }
            guard position > start, current == 58,
                  position - start == 1 || bytes[start] != 48 else { throw SPTorrentInputError.invalidTorrent }
            position += 1
            guard length <= bytes.count - position else { throw SPTorrentInputError.invalidTorrent }
            let range = position..<(position + length)
            position += length
            return range
        }

        private mutating func integer() throws {
            position += 1
            let negative = current == 45
            if negative { position += 1 }
            let start = position
            while let character = current, (48...57).contains(character) { position += 1 }
            guard position > start, current == 101,
                  (position - start == 1 || bytes[start] != 48),
                  !(negative && bytes[start] == 48) else { throw SPTorrentInputError.invalidTorrent }
            position += 1
        }
    }
}

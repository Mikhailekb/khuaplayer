import Foundation

@main @MainActor
struct TorrentModelChecks {
    static var checks = 0

    static func main() throws {
        let hex = "0123456789abcdef0123456789abcdef01234567"
        check(SPTorrentInput.normalizedHash(hex.uppercased()) == hex, "hex hashes normalize case")
        check(SPTorrentInput.normalizedHash(String(repeating: "g", count: 40)) == nil, "nonhex hash is rejected")
        check(SPTorrentInput.normalizedHash(String(repeating: "0", count: 39)) == nil, "short hex hash is rejected")
        check(SPTorrentInput.magnetHash("MAGNET:?xt=URN:BTIH:" + hex.uppercased()) == hex,
              "magnet scheme and btih prefix accept mixed case")
        check(SPTorrentInput.magnetHash("magnet:?xt=urn:btih:AERUKZ4JVPG66AJDIVTYTK6N54ASGRLH") == hex,
              "32-character base32 decodes to the expected 20-byte hash")
        check(SPTorrentInput.magnetHash("magnet:?xt=urn%3Abtih%3Aaerukz4jvpg66ajdivtytk6n54asgrlh&dn=Test") == hex,
              "escaped lowercase base32 magnet is decoded")
        check(SPTorrentInput.magnetHash("magnet:?xt=urn:sha1:ignored&xt=urn:btih:" + hex) == hex,
              "btih may follow another exact-topic field")
        for link in ["https://example.com/?xt=urn:btih:" + hex, "magnet:?dn=OnlyName",
                     "magnet:?xt=urn:btih:" + String(repeating: "A", count: 31),
                     "magnet:?xt=urn:btih:" + String(repeating: "0", count: 32),
                     "magnet:?xt=urn:btih:" + String(repeating: "ſ", count: 32),
                     "magnet:?xt=urn:btmh:" + hex] {
            check(SPTorrentInput.magnetHash(link) == nil, "invalid or unsupported magnet is rejected")
        }

        // Expected digests were computed independently with Python hashlib.sha1.
        try check(SPTorrentInput.infoHash(in: torrent(Data("d4:name4:teste".utf8))) ==
              "1ade8a1a581f338e4fce4ce784da3f7d03f81f3a", "tiny torrent hashes exact info bytes")
        let binaryInfo = Data([100, 52, 58, 110, 97, 109, 101, 51, 58, 97, 0, 98, 101])
        try check(SPTorrentInput.infoHash(in: torrent(binaryInfo)) ==
              "ccff64ff1205a8000488c7f10d87983f55fce556", "binary info string preserves embedded NUL")
        let unsortedInfo = Data("d1:zi1e1:ai2ee".utf8)
        try check(SPTorrentInput.infoHash(in: torrent(unsortedInfo)) ==
              "f87163e124643bfd7983ff5d370ab5aa8244b3a2", "info dictionary bytes are not reordered")
        var padded = Data([0, 1, 2])
        padded.append(torrent(Data("d4:name4:teste".utf8)))
        let sliced = padded.dropFirst(3)
        try check(SPTorrentInput.infoHash(in: sliced) == "1ade8a1a581f338e4fce4ce784da3f7d03f81f3a",
              "Data with a nonzero start index hashes safely")

        for malformed in ["", "le", "de", "d4:info0:e", "d4:infode4:infodee",
                          "d4:infodeetrailing", "d4:infod1:ai01eee", "d4:infod1:ai-0eee",
                          "d4:infod1:ai+1eee", "d4:infod1:aieee", "d4:infod1:ai1.0eee",
                          "d4:infod1:a01:xee", "d4:infod1:a999999999999999999999999999999:xee",
                          "d4:infod1:a4:xy", "d4:infod1:ai1e1:ai2eee", "d4:infodli1eeee"] {
            expectInvalid(Data(malformed.utf8), "malformed bencode is rejected")
        }
        let depth64 = Data(("d1:a" + String(repeating: "l", count: 62) + "0:" +
                            String(repeating: "e", count: 62) + "e").utf8)
        _ = try SPTorrentInput.infoHash(in: torrent(depth64))
        check(true, "depth-64 fixture is accepted")
        let depth65 = Data(("d1:a" + String(repeating: "l", count: 63) + "0:" +
                            String(repeating: "e", count: 63) + "e").utf8)
        expectInvalid(torrent(depth65), "depth over 64 is rejected")
        let atItemLimit = Data(("d4:infod1:al" + String(repeating: "0:", count: 999_995) + "eee").utf8)
        _ = try SPTorrentInput.infoHash(in: atItemLimit)
        check(true, "one million bencoded items are accepted")
        let overItemLimit = Data(("d4:infod1:al" + String(repeating: "0:", count: 999_996) + "eee").utf8)
        expectInvalid(overItemLimit, "item count over one million is rejected")
        do {
            _ = try SPTorrentInput.infoHash(in: Data(repeating: 0, count: 32 * 1_024 * 1_024 + 1))
            fatalError("oversized torrent should fail")
        } catch SPTorrentInputError.tooLarge {
            check(true, "size over 32 MiB has the distinct tooLarge error")
        }

        let playable = ["mp4", "mkv", "mov", "m4v", "avi", "webm", "ts", "m2ts", "mts",
                        "mpg", "mpeg", "vob", "wmv", "flv", "ogv", "3gp", "mp3", "m4a",
                        "flac", "wav", "aac", "ogg", "opus", "aiff", "alac"]
        for ext in playable {
            let file = SPTorrentFile(id: 1, path: "Show/Season 1/Episode.\(ext.uppercased())", length: 5)
            check(file.isPlayable && file.displayName == "Episode.\(ext.uppercased())",
                  "recognized media extension is case insensitive")
        }
        let sidecar = SPTorrentFile(id: 2, path: "Show/Episode.srt", length: 12)
        check(!sidecar.isPlayable, "subtitle sidecar is not playable media")
        try check(JSONDecoder().decode(SPTorrentFile.self, from: JSONEncoder().encode(sidecar)) == sidecar,
              "file model Codable round trip preserves metadata")
        let descriptor = SPTorrentDescriptor(leaseID: UUID(), hash: hex, name: "Show", files: [sidecar], originalLink: nil)
        check(descriptor.files == [sidecar], "descriptor retains nonmedia sidecars")

        let response: [String: Any] = [
            "hash": hex.uppercased(), "name": "Show", "download_speed": 12.5, "upload_speed": "2.5",
            "loaded_size": Int64(9_007_199_254_740_993), "torrent_size": 99,
            "preloaded_bytes": 32, "preload_size": 64, "active_peers": 3, "total_peers": 9,
            "connected_seeders": 2, "stat": 3, "stat_string": "Torrent working",
            "file_stats": [["id": 1, "path": "Show/Film.MKV", "length": "99"],
                           ["id": 2, "path": "Show/Film.srt", "length": 12]]
        ]
        let parsed = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: response)) as! [String: Any]
        let status = SPTorrentStatus(json: parsed, cache: ["Filled": 40, "Capacity": "128"])
        check(status.hash == hex && status.name == "Show" && status.files.count == 2, "status parses hash, name and all files")
        check(status.files[0].id == 1 && status.files[0].length == 99 && !status.files[1].isPlayable,
              "status preserves server file IDs and sidecars")
        check(status.downloadBytesPerSecond == 12.5 && status.uploadBytesPerSecond == 2.5, "status parses numeric and string rates")
        check(status.loadedBytes == 9_007_199_254_740_993 && status.totalBytes == 99, "integer counters preserve values beyond Double precision")
        check(status.bufferedBytes == 40 && status.bufferCapacityBytes == 128, "PascalCase cache fields are parsed separately")
        check(status.preloadedBytes == 32 && status.preloadTargetBytes == 64, "preload fields map correctly")
        check(status.activePeers == 3 && status.totalPeers == 9 && status.connectedSeeders == 2,
              "status maps peer counts")
        check(status.statusCode == 3 && status.statusText == "Torrent working", "status maps server state")
        let defaults = SPTorrentStatus(json: [:])
        let missingID = SPTorrentStatus(json: ["file_stats": [["path": "Movie.mp4", "length": 5]]])
        check(missingID.files.first?.id == 0, "missing server file ID is invalid and is never inferred from array position")
        check(defaults.hash.isEmpty && defaults.name.isEmpty && defaults.files.isEmpty && defaults.statusText.isEmpty,
              "missing optional metadata defaults to empty values")
        check(defaults.loadedBytes == 0 && defaults.totalBytes == 0 && defaults.bufferedBytes == 0 &&
              defaults.bufferCapacityBytes == 0 && defaults.preloadedBytes == 0 && defaults.preloadTargetBytes == 0 &&
              defaults.downloadBytesPerSecond == 0 && defaults.uploadBytesPerSecond == 0 && defaults.activePeers == 0 &&
              defaults.totalPeers == 0 && defaults.connectedSeeders == 0 && defaults.statusCode == 0,
              "missing numeric status fields default to zero")
        let invalidNumbers = SPTorrentStatus(json: ["title": "Fallback", "loaded_size": 1e300,
                                                   "torrent_size": -10, "download_speed": Double.nan,
                                                   "upload_speed": Double.infinity, "active_peers": "bad"])
        check(invalidNumbers.name == "Fallback" && invalidNumbers.loadedBytes == 0 && invalidNumbers.totalBytes == 0 &&
              invalidNumbers.downloadBytesPerSecond == 0 && invalidNumbers.uploadBytesPerSecond == 0 && invalidNumbers.activePeers == 0,
              "malformed or nonfinite numeric fields cannot overflow or contaminate status")
        cacheSnapshotChecks()
        print("Torrent model checks passed (\(checks) checks)")
    }

    static func cacheSnapshotChecks() {
        let hash = String(repeating: "a", count: 40)
        let file = SPTorrentFile(id: 4, path: "Show/A.mkv", length: 72)
        let good: [String: Any] = ["hash": hash, "file_index": 4, "file_offset": 11,
            "file_length": 72, "piece_length": 16, "resident_bytes": 40,
            "ranges": [[0, 5], [21, 37], [53, 72]]]
        let snapshot = SPTorrentCacheSnapshot(json: good, expectedHash: hash, file: file)
        check(snapshot?.fileOffset == 11 && snapshot?.residentBytes == 40 && snapshot?.ranges.count == 3,
              "cache snapshot preserves actual file offset, clipped pieces and separate resident holes")
        var empty = good; empty["ranges"] = [[Int]](); empty["resident_bytes"] = 0
        check(SPTorrentCacheSnapshot(json: empty, expectedHash: hash, file: file)?.ranges.isEmpty == true,
              "empty current-file cache is valid even when other torrent files contain data")
        let invalid: [(String, Any)] = [
            ("hash", String(repeating: "b", count: 40)), ("file_index", 5), ("file_index", true),
            ("file_offset", -1), ("file_offset", Int64.max), ("file_length", 71),
            ("piece_length", 0), ("piece_length", true), ("resident_bytes", 41),
            ("resident_bytes", -1), ("resident_bytes", 1.5), ("resident_bytes", "40"),
            ("ranges", [[0, 5], [4, 21]]), ("ranges", [[21, 37], [0, 5]]),
            ("ranges", [[0, 5], [5, 21]]), ("ranges", [[-1, 5]]),
            ("ranges", [[0, 0]]), ("ranges", [[0, 73]]), ("ranges", [[1, 5]]),
            ("ranges", [[0, 6]]), ("ranges", [[false, 5]]), ("ranges", [[0, 5, 16]]),
            ("ranges", Array(repeating: [0, 1], count: 32_769))
        ]
        for (key, value) in invalid {
            var object = good; object[key] = value
            if key == "ranges", let ranges = value as? [[Int]], ranges.allSatisfy({ $0.count == 2 && $0[0] >= 0 && $0[1] > $0[0] }) {
                let sum = ranges.reduce(0) { $0 + $1[1] - $1[0] }
                if sum <= Int(file.length) { object["resident_bytes"] = sum }
            }
            check(SPTorrentCacheSnapshot(json: object, expectedHash: hash, file: file) == nil,
                  "malformed or mismatched cache field \(key) cannot claim buffered data")
        }
        let hugeFile = SPTorrentFile(id: 4, path: "Huge.mkv", length: 99)
        let huge: [String: Any] = ["hash": hash, "file_index": 4, "file_offset": Int64(9_007_199_254_740_993),
            "file_length": 99, "piece_length": 1, "resident_bytes": 99, "ranges": [[0, 99]]]
        check(SPTorrentCacheSnapshot(json: huge, expectedHash: hash, file: hugeFile)?.fileOffset == 9_007_199_254_740_993,
              "cache byte offsets retain Int64 precision above the Double exact-integer range")
    }

    static func torrent(_ info: Data) -> Data {
        var data = Data("d4:info".utf8)
        data.append(info)
        data.append(101)
        return data
    }

    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        guard try condition() else { fatalError(message) }
        checks += 1
    }

    static func expectInvalid(_ data: Data, _ message: String) {
        do {
            _ = try SPTorrentInput.infoHash(in: data)
            fatalError(message)
        } catch SPTorrentInputError.invalidTorrent {
            checks += 1
        } catch {
            fatalError("Unexpected error: \(error)")
        }
    }
}

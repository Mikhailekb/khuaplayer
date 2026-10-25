import Foundation

/// Context actions use a durable source identity, never a worker stream URL.
enum SPVideoContextPolicy {
    static func sharingURL(localPath: String?, torrentHash: String?, torrentName: String?) -> URL? {
        if let hash = torrentHash {
            let characters = Array(hash.utf8)
            guard characters.count == 40,
                  characters.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
                return nil
            }
            var components = URLComponents()
            components.scheme = "magnet"
            components.queryItems = [URLQueryItem(name: "xt", value: "urn:btih:" + hash.lowercased())]
            if let name = torrentName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                components.queryItems?.append(URLQueryItem(name: "dn", value: name))
            }
            return components.url
        }
        guard let path = localPath, path.hasPrefix("/"),
              !path.utf8.contains(0) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// A local growing prefix is not a completed item. Torrent duration comes
    /// from its complete metadata and uses the existing streamed-end guards.
    static func canRepeatEnded(isTorrent: Bool, position: Double, duration: Double,
                               growing: Bool, waiting: Bool, stalled: Bool,
                               waitingForIndex: Bool, availableEnd: Double) -> Bool {
        guard !waiting, !stalled, duration.isFinite, duration > 0,
              position.isFinite, position >= duration - 1 else { return false }
        return isTorrent || (!growing && !waitingForIndex && availableEnd < 0)
    }
}

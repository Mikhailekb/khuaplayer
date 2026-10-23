import Foundation
import CoreFoundation

/// Desired per-torrent memory limit. Each worker captures its own immutable
/// configuration before launch; changing this value never rewrites a live worker.
struct SPTorrentConfiguration: Equatable, Sendable {
    static let defaultCacheSizeMiB = 128
    static let allowedCacheSizesMiB = [128, 256, 512, 1024, 2048]

    let cacheSizeMiB: Int
    var cacheSizeBytes: Int64 { Int64(cacheSizeMiB) * 1024 * 1024 }

    init(cacheSizeMiB: Int = Self.defaultCacheSizeMiB) {
        self.cacheSizeMiB = Self.allowedCacheSizesMiB.contains(cacheSizeMiB)
            ? cacheSizeMiB : Self.defaultCacheSizeMiB
    }
}

@MainActor
enum SPTorrentPreferences {
    static let cacheSizeKey = "sp.torrent.cacheSizeMiB"
    static let allowedCacheSizesMiB = SPTorrentConfiguration.allowedCacheSizesMiB
    static let changed = Notification.Name("sp.torrentPreferencesChanged")
    static let changedNotification = changed

    static var cacheSizeMiB: Int {
        get { configuration().cacheSizeMiB }
        set { setCacheSizeMiB(newValue) }
    }

    static func configuration(defaults: UserDefaults = .standard) -> SPTorrentConfiguration {
        guard let value = defaults.object(forKey: cacheSizeKey) as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite,
              allowedCacheSizesMiB.contains(where: { Double($0) == value.doubleValue }) else {
            return SPTorrentConfiguration()
        }
        return SPTorrentConfiguration(cacheSizeMiB: value.intValue)
    }

    static func setCacheSizeMiB(_ size: Int, defaults: UserDefaults = .standard,
                                notifications: NotificationCenter = .default) {
        let desired = SPTorrentConfiguration(cacheSizeMiB: size)
        let previous = configuration(defaults: defaults)
        defaults.set(desired.cacheSizeMiB, forKey: cacheSizeKey)
        if desired != previous { notifications.post(name: changed, object: nil) }
    }
}

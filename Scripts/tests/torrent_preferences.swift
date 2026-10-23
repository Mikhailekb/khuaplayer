import Foundation

@main @MainActor
struct TorrentPreferencesChecks {
    static var assertions = 0
    static var changes = 0

    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        assertions += 1
    }

    static func main() async {
        let suite = "khua.torrent-preferences-checks." + UUID().uuidString
        let otherSuite = "khua.torrent-preferences-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let otherDefaults = UserDefaults(suiteName: otherSuite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            otherDefaults.removePersistentDomain(forName: otherSuite)
        }
        let notifications = NotificationCenter()
        check(SPTorrentPreferences.configuration(defaults: defaults).cacheSizeMiB == 128,
              "A new suite defaults to 128 MiB")
        check(SPTorrentPreferences.allowedCacheSizesMiB == [128, 256, 512, 1024, 2048],
              "Only supported per-torrent memory limits are offered")
        for invalid: Any in [true, false, "512", 0, -128, 129, 256.5, Double.infinity, Data([1, 2])] {
            defaults.set(invalid, forKey: SPTorrentPreferences.cacheSizeKey)
            check(SPTorrentPreferences.configuration(defaults: defaults) == SPTorrentConfiguration(),
                  "Invalid persisted data safely uses the default")
        }
        for size in SPTorrentPreferences.allowedCacheSizesMiB {
            SPTorrentPreferences.setCacheSizeMiB(size, defaults: defaults, notifications: notifications)
            let recreated = UserDefaults(suiteName: suite)!
            let configuration = SPTorrentPreferences.configuration(defaults: recreated)
            check(configuration.cacheSizeMiB == size, "The setting survives recreating its defaults wrapper")
            check(configuration.cacheSizeBytes == Int64(size) * 1024 * 1024,
                  "MiB converts to exact binary bytes without overflow")
            let transferred = await Task.detached { configuration }.value
            check(transferred == configuration, "The value snapshot can cross Swift 6 task boundaries")
        }
        check(SPTorrentPreferences.configuration(defaults: otherDefaults).cacheSizeMiB == 128,
              "Injected defaults isolate independent configurations")
        SPTorrentPreferences.setCacheSizeMiB(Int.max, defaults: defaults, notifications: notifications)
        check(SPTorrentPreferences.configuration(defaults: defaults).cacheSizeMiB == 128,
              "An unsupported setter value normalizes to the default")
        check(SPTorrentConfiguration(cacheSizeMiB: -1) == SPTorrentConfiguration(),
              "Injected configuration values use the same validation")
        let token = notifications.addObserver(forName: SPTorrentPreferences.changedNotification,
                                              object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { changes += 1 }
        }
        defer { notifications.removeObserver(token) }
        SPTorrentPreferences.setCacheSizeMiB(512, defaults: defaults, notifications: notifications)
        check(changes == 1, "A meaningful desired configuration change notifies observers")
        SPTorrentPreferences.setCacheSizeMiB(512, defaults: defaults, notifications: notifications)
        check(changes == 1, "Writing the same effective setting does not notify twice")
        SPTorrentPreferences.setCacheSizeMiB(-1, defaults: defaults, notifications: notifications)
        check(changes == 2, "Normalizing an invalid setter notifies when the desired value changes")
        print("Torrent preference checks passed (\(assertions) assertions).")
    }
}

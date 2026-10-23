import Foundation

/// A viewing-environment preference, independent of a film's manual picture
/// adjustments or a series profile. Every player window reads the same value.
@MainActor
enum SPHDRViewingPreferences {
    static let brightRoomKey = "sp.picture.hdrBrightRoom.enabled"
    static let changed = Notification.Name("sp.hdrViewingPreferencesChanged")

    static var brightRoomEnabled: Bool {
        get { isBrightRoomEnabled() }
        set { setBrightRoomEnabled(newValue) }
    }

    static func isBrightRoomEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: brightRoomKey) as? Bool ?? true
    }

    static func setBrightRoomEnabled(_ enabled: Bool, defaults: UserDefaults = .standard,
                                     notifications: NotificationCenter = .default) {
        guard enabled != isBrightRoomEnabled(defaults: defaults) else { return }
        defaults.set(enabled, forKey: brightRoomKey)
        notifications.post(name: changed, object: nil)
    }
}

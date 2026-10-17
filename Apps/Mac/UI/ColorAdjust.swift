import Foundation

/// Percent-based picture adjustments shared by every player window.
///
/// The adjustments panel exposes symmetric -100...100 percent sliders, while
/// the engine works in asymmetric ranges (brightness -0.5...0.5, contrast and
/// gamma 0.5...2, saturation 0...2, hue -180...180 degrees). The mapping
/// between the two lives here so it stays unit-testable without AppKit.
struct SPColorAdjust: Equatable {
    enum Field: Int, CaseIterable {
        case brightness = 0
        case contrast = 1
        case saturation = 2
        case gamma = 3
        case hue = 4
    }

    var brightness: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0
    var gamma: Double = 0
    var hue: Double = 0

    init() {}

    init(brightness: Double, contrast: Double, saturation: Double,
         gamma: Double, hue: Double) {
        self.brightness = SPColorAdjust.clamp(brightness)
        self.contrast = SPColorAdjust.clamp(contrast)
        self.saturation = SPColorAdjust.clamp(saturation)
        self.gamma = SPColorAdjust.clamp(gamma)
        self.hue = SPColorAdjust.clamp(hue)
    }

    static func clamp(_ percent: Double) -> Double {
        min(100, max(-100, percent))
    }

    var isDefault: Bool { self == SPColorAdjust() }

    // Engine values; see SPPlayerCore.h for the authoritative ranges.
    var engineBrightness: Double { brightness / 200 }     // -0.5...0.5
    var engineContrast: Double { pow(2, contrast / 100) } // 0.5...2
    var engineSaturation: Double { 1 + saturation / 100 } // 0...2
    var engineGamma: Double { pow(2, gamma / 100) }       // 0.5...2
    var engineHueDegrees: Double { hue * 1.8 }            // -180...180

    subscript(field: Field) -> Double {
        get {
            switch field {
            case .brightness: return brightness
            case .contrast: return contrast
            case .saturation: return saturation
            case .gamma: return gamma
            case .hue: return hue
            }
        }
        set {
            let clamped = SPColorAdjust.clamp(newValue)
            switch field {
            case .brightness: brightness = clamped
            case .contrast: contrast = clamped
            case .saturation: saturation = clamped
            case .gamma: gamma = clamped
            case .hue: hue = clamped
            }
        }
    }
}

/// Session-wide picture-adjustment state shared by all player windows.
///
/// Values are intentionally not persisted: they reset on relaunch, matching
/// the renderer's process-scoped adjustment semantics. Updates post `changed`
/// with the touched field in `userInfo` so observers can re-apply just that
/// engine property while a slider is being dragged.
@MainActor
enum SPColorAdjustStore {
    static let changed = Notification.Name("sp.colorAdjustChanged")

    private(set) static var current = SPColorAdjust()

    static func update(_ field: SPColorAdjust.Field, toPercent percent: Double) {
        var value = current
        value[field] = percent
        update(value, field: field)
    }

    static func reset(_ field: SPColorAdjust.Field) {
        update(field, toPercent: 0)
    }

    static func resetAll() {
        update(SPColorAdjust(), field: nil)
    }

    private static func update(_ value: SPColorAdjust, field: SPColorAdjust.Field?) {
        guard value != current else { return }
        current = value
        var userInfo: [String: Any]?
        if let field { userInfo = [SPColorAdjustChangedFieldKey: field.rawValue] }
        NotificationCenter.default.post(name: changed, object: nil, userInfo: userInfo)
    }

    /// The single touched field for incremental application, or nil when the
    /// whole adjustment set changed (reset all) and every property must be
    /// re-applied. Pure payload parsing; callable from any isolation.
    nonisolated static func changedField(of notification: Notification) -> SPColorAdjust.Field? {
        guard let raw = notification.userInfo?[SPColorAdjustChangedFieldKey] as? Int else { return nil }
        return SPColorAdjust.Field(rawValue: raw)
    }
}

/// File-scope key so the nonisolated payload parser stays dependency-free.
private let SPColorAdjustChangedFieldKey = "field"

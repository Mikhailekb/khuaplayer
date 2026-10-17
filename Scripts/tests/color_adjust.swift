import Foundation

@main
@MainActor
struct ColorAdjustChecks {
    static var checks = 0

    static func expect(_ actual: Double, _ expected: Double,
                       _ description: String, tolerance: Double = 0.000001) {
        checks += 1
        guard abs(actual - expected) <= tolerance else {
            fatalError("\(description): expected \(expected), got \(actual)")
        }
    }

    static func expect(_ actual: Int, _ expected: Int, _ description: String) {
        checks += 1
        guard actual == expected else {
            fatalError("\(description): expected \(expected), got \(actual)")
        }
    }

    static func expect(_ actual: Bool, _ expected: Bool, _ description: String) {
        checks += 1
        guard actual == expected else {
            fatalError("\(description): expected \(expected), got \(actual)")
        }
    }

    static func main() {
        mappingChecks()
        clampChecks()
        resetChecks()
        storeChecks()
        notificationPayloadChecks()
        print("Color adjust checks passed (\(checks) assertions).")
    }

    static func mappingChecks() {
        let neutral = SPColorAdjust()
        expect(neutral.isDefault, true, "Fresh adjustment set is default")
        expect(neutral.engineBrightness, 0, "Neutral brightness")
        expect(neutral.engineContrast, 1, "Neutral contrast")
        expect(neutral.engineSaturation, 1, "Neutral saturation")
        expect(neutral.engineGamma, 1, "Neutral gamma")
        expect(neutral.engineHueDegrees, 0, "Neutral hue")

        // Brightness: -100...100 percent maps linearly onto -0.5...0.5.
        expect(SPColorAdjust(brightness: -100, contrast: 0, saturation: 0,
                             gamma: 0, hue: 0).engineBrightness, -0.5,
               "Brightness floor")
        expect(SPColorAdjust(brightness: 100, contrast: 0, saturation: 0,
                             gamma: 0, hue: 0).engineBrightness, 0.5,
               "Brightness ceiling")
        expect(SPColorAdjust(brightness: 40, contrast: 0, saturation: 0,
                             gamma: 0, hue: 0).engineBrightness, 0.2,
               "Brightness midpoint")

        // Contrast and gamma ride a power curve: -100 -> 0.5, +100 -> 2.
        expect(SPColorAdjust(brightness: 0, contrast: -100, saturation: 0,
                             gamma: 0, hue: 0).engineContrast, 0.5,
               "Contrast floor")
        expect(SPColorAdjust(brightness: 0, contrast: 100, saturation: 0,
                             gamma: 0, hue: 0).engineContrast, 2,
               "Contrast ceiling")
        expect(SPColorAdjust(brightness: 0, contrast: 0, saturation: 0,
                             gamma: -100, hue: 0).engineGamma, 0.5,
               "Gamma floor")
        expect(SPColorAdjust(brightness: 0, contrast: 0, saturation: 0,
                             gamma: 100, hue: 0).engineGamma, 2,
               "Gamma ceiling")

        // Saturation: -100 percent is grayscale, +100 percent doubles.
        expect(SPColorAdjust(brightness: 0, contrast: 0, saturation: -100,
                             gamma: 0, hue: 0).engineSaturation, 0,
               "Saturation floor")
        expect(SPColorAdjust(brightness: 0, contrast: 0, saturation: 100,
                             gamma: 0, hue: 0).engineSaturation, 2,
               "Saturation ceiling")

        // Hue: percent scales onto -180...180 degrees.
        expect(SPColorAdjust(brightness: 0, contrast: 0, saturation: 0,
                             gamma: 0, hue: -100).engineHueDegrees, -180,
               "Hue floor")
        expect(SPColorAdjust(brightness: 0, contrast: 0, saturation: 0,
                             gamma: 0, hue: 100).engineHueDegrees, 180,
               "Hue ceiling")
        expect(SPColorAdjust(brightness: 0, contrast: 0, saturation: 0,
                             gamma: 0, hue: 50).engineHueDegrees, 90,
               "Hue midpoint")
    }

    static func clampChecks() {
        expect(SPColorAdjust.clamp(150), 100, "Clamp above range")
        expect(SPColorAdjust.clamp(-150), -100, "Clamp below range")
        expect(SPColorAdjust.clamp(0), 0, "Clamp keeps zero")
        expect(SPColorAdjust.clamp(72.5), 72.5, "Clamp keeps in-range value")

        let clamped = SPColorAdjust(brightness: 500, contrast: -500, saturation: 42,
                             gamma: 3, hue: -3)
        expect(clamped[.brightness], 100, "Init clamps brightness")
        expect(clamped[.contrast], -100, "Init clamps contrast")
        expect(clamped[.saturation], 42, "Init keeps in-range saturation")
        expect(clamped[.gamma], 3, "Init keeps in-range gamma")
        expect(clamped[.hue], -3, "Init keeps in-range hue")

        var viaSubscript = clamped
        viaSubscript[.saturation] = 1000
        expect(viaSubscript[.saturation], 100, "Subscript clamps on write")
    }

    static func resetChecks() {
        var value = SPColorAdjust(brightness: 20, contrast: -30, saturation: 40,
                             gamma: -50, hue: 60)
        expect(value.isDefault, false, "Modified set is not default")
        expect(value == SPColorAdjust(), false, "Modified set differs from default")

        var copy = value
        copy[.brightness] = 0
        expect(copy.brightness, 0, "Field reset through subscript")
        expect(copy.contrast, -30, "Other fields survive a single reset")

        value = SPColorAdjust()
        expect(value.isDefault, true, "Full reset returns to default")
    }

    static func storeChecks() {
        SPColorAdjustStore.resetAll()
        expect(SPColorAdjustStore.current.isDefault, true, "Store starts neutral")

        SPColorAdjustStore.update(.hue, toPercent: 80)
        expect(SPColorAdjustStore.current.hue, 80, "Store records hue update")
        expect(SPColorAdjustStore.current.engineHueDegrees, 144,
               "Store hue maps to degrees")

        SPColorAdjustStore.update(.hue, toPercent: 80)
        expect(SPColorAdjustStore.current.hue, 80, "No-op update leaves value")

        SPColorAdjustStore.update(.hue, toPercent: 200)
        expect(SPColorAdjustStore.current.hue, 100, "Store clamps input")

        SPColorAdjustStore.reset(.hue)
        expect(SPColorAdjustStore.current.hue, 0, "Field reset clears hue")
        expect(SPColorAdjustStore.current.engineHueDegrees, 0,
               "Field reset maps back to neutral engine value")

        SPColorAdjustStore.update(.gamma, toPercent: -25)
        expect(SPColorAdjustStore.current.engineGamma, 0.5 * pow(2, 0.75),
               "Second field coexists with earlier state")
        SPColorAdjustStore.resetAll()
        expect(SPColorAdjustStore.current.isDefault, true, "Reset all clears state")

        SPColorAdjustStore.resetAll()
        expect(SPColorAdjustStore.current.isDefault, true, "Reset all on defaults stays neutral")
    }

    static func notificationPayloadChecks() {
        // changedField(of:) is the parsing glue the app observer relies on.
        let fieldNote = Notification(
            name: SPColorAdjustStore.changed, object: nil,
            userInfo: ["field": SPColorAdjust.Field.contrast.rawValue])
        expect(SPColorAdjustStore.changedField(of: fieldNote) == .contrast, true,
               "Payload with a field resolves to that field")

        let fullNote = Notification(name: SPColorAdjustStore.changed, object: nil)
        expect(SPColorAdjustStore.changedField(of: fullNote) == nil, true,
               "Payload without a field resolves to nil")

        let junkNote = Notification(
            name: SPColorAdjustStore.changed, object: nil, userInfo: ["field": "junk"])
        expect(SPColorAdjustStore.changedField(of: junkNote) == nil, true,
               "Malformed payload resolves to nil")
    }
}

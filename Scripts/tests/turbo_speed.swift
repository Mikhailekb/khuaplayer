import Foundation

@main @MainActor
struct TurboSpeedChecks {
    static var checks = 0

    static func expect(_ actual: [SPTurboGesture.Effect], _ expected: [SPTurboGesture.Effect], _ message: String) {
        guard actual == expected else {
            print("FAIL: \(message): expected \(expected), got \(actual)")
            exit(1)
        }
        checks += 1
    }

    static func check(_ condition: Bool, _ message: String) {
        guard condition else { print("FAIL: \(message)"); exit(1) }
        checks += 1
    }

    static func main() {
        var gesture = SPTurboGesture()
        expect(gesture.keyDown(enabled: true, playing: true, currentRate: 1, configuredRate: 2),
               [.scheduleThreshold], "Space down must not pause a playing item")
        check(gesture.phase == .charging && gesture.blocksPlaybackControls, "Hold waits without changing playback")
        expect(gesture.keyDown(enabled: true, playing: true, currentRate: 1, configuredRate: 2), [], "Repeated down is ignored")
        expect(gesture.keyUp(), [.cancelThreshold, .togglePlayback], "Short tap pauses only on release")
        check(gesture.phase == .idle && !gesture.blocksPlaybackControls, "Release clears pending input")
        expect(gesture.keyUp(), [], "Repeated release cannot toggle twice")
        expect(gesture.thresholdFired(), [], "Cancelled tap cannot engage a late timer")

        expect(gesture.keyDown(enabled: true, playing: true, currentRate: 1.25, configuredRate: 2), [.scheduleThreshold], "Nondefault playback speed remains unchanged on down")
        expect(gesture.thresholdFired(), [.engage(rate: 2)], "Hold engages the configured speed")
        check(gesture.phase == .active && gesture.baseRate == 1.25, "Active hold remembers original speed")
        expect(gesture.thresholdFired(), [], "Threshold engages only once")
        expect(gesture.keyDown(enabled: true, playing: true, currentRate: 2, configuredRate: 2), [], "Active autorepeat cannot restart hold")
        expect(gesture.keyUp(), [.restore(rate: 1.25)], "Held release restores speed without pausing")
        expect(gesture.keyUp(), [], "Released hold cannot become a tap")

        _ = gesture.keyDown(enabled: true, playing: true, currentRate: 1, configuredRate: 2)
        expect(gesture.forceEnd(), [.cancelThreshold], "Focus loss cancels pending hold without pausing")
        expect(gesture.keyUp(), [], "Late release after focus loss is ignored")
        expect(gesture.thresholdFired(), [], "Focus loss invalidates threshold")
        _ = gesture.keyDown(enabled: true, playing: true, currentRate: 1.5, configuredRate: 3)
        expect(gesture.thresholdFired(), [.engage(rate: 3)], "Configured speed is preserved")
        expect(gesture.forceEnd(), [.restore(rate: 1.5)], "Cancellation restores the original speed")
        expect(gesture.keyUp(), [], "Late release after active cancellation cannot pause")
        expect(gesture.forceEnd(), [], "Repeated cancellation is harmless")

        for enabled in [true, false] {
            expect(gesture.keyDown(enabled: enabled, playing: false, currentRate: 1, configuredRate: 2), [], "Paused down waits for release")
            check(gesture.phase != .idle, "Paused press remembers ownership of release")
            expect(gesture.thresholdFired(), [], "Holding a paused item does not start playback")
            expect(gesture.keyDown(enabled: enabled, playing: false, currentRate: 1, configuredRate: 2), [], "Paused repeat cannot start playback")
            expect(gesture.keyUp(), [.togglePlayback], "Paused release resumes exactly once")
            expect(gesture.keyUp(), [], "Paused extra release is ignored")
        }
        expect(gesture.keyDown(enabled: false, playing: true, currentRate: 1, configuredRate: 2), [], "Disabled acceleration still defers pause until release")
        expect(gesture.thresholdFired(), [], "Disabled acceleration never engages")
        expect(gesture.keyUp(), [.togglePlayback], "Disabled acceleration retains ordinary tap behavior")
        _ = gesture.keyDown(enabled: false, playing: true, currentRate: 1, configuredRate: 2)
        expect(gesture.forceEnd(), [], "Cancelling a plain press never toggles playback")
        expect(gesture.keyUp(), [], "Cancelled plain press ignores late release")

        check(SPTurboSpeed.targetRate(base: 1.25, configured: 2) == 2, "Normal base uses configured target")
        check(SPTurboSpeed.targetRate(base: 2, configured: 2) == 4, "Already-fast base retains existing boost policy")
        check(SPTurboSpeed.targetRate(base: 4, configured: 2) == 5, "Boost remains bounded by supported playback rate")
        print("Turbo speed checks passed (\(checks) assertions).")
    }
}

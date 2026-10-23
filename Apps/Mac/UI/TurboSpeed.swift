import Foundation

enum SPTurboSpeed {
    /// Hold for 250 ms to accelerate, leaving ordinary taps as play/pause actions.
    static let holdThreshold: TimeInterval = 0.25

    static let rateOptions: [Double] = [2, 3, 4, 5]
    static let defaultRate: Double = 2

    static func targetRate(base: Double, configured: Double) -> Double {
        let boosted = base < configured - 0.001 ? configured : base * 2
        return min(max(boosted, PlayerCommandPolicy.playbackRateRange.lowerBound),
                   PlayerCommandPolicy.playbackRateRange.upperBound)
    }

    static func blocksCommand(_ command: PlayerCommand) -> Bool {
        switch command {
        case .togglePlayback, .seekRelative, .seekAbsolute, .seekCoarse,
             .setPlaybackRate, .stepFrame, .previousMedia, .nextMedia,
             .toggleFrameInterpolation, .setFrameInterpolation:
            return true
        default:
            return false
        }
    }
}

enum SPTurboSettings {
    static let enabledKey = "sp.turbo.enabled"
    static let rateKey = "sp.turbo.rate"

    static var isEnabled: Bool {
        get {

            UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var rate: Double {
        get {
            let stored = UserDefaults.standard.object(forKey: rateKey) as? Double
                ?? SPTurboSpeed.defaultRate

            return SPTurboSpeed.rateOptions.contains { abs($0 - stored) < 0.001 }
                ? stored : SPTurboSpeed.defaultRate
        }
        set { UserDefaults.standard.set(newValue, forKey: rateKey) }
    }
}

struct SPTurboGesture: Equatable {
    enum Phase: Equatable {
        case idle
        case pendingTap
        case charging
        case active
    }

    enum Effect: Equatable {
        case togglePlayback
        case scheduleThreshold
        case cancelThreshold
        case engage(rate: Double)
        case restore(rate: Double)
    }

    private(set) var phase: Phase = .idle
    private(set) var baseRate: Double = 1
    private(set) var turboRate: Double = 1

    var blocksPlaybackControls: Bool { phase != .idle }

    mutating func keyDown(enabled: Bool, playing: Bool,
                          currentRate: Double, configuredRate: Double) -> [Effect] {
        guard phase == .idle else { return [] }
        guard enabled, playing else {
            phase = .pendingTap
            return []
        }
        phase = .charging
        baseRate = currentRate
        turboRate = SPTurboSpeed.targetRate(base: currentRate, configured: configuredRate)
        return [.scheduleThreshold]
    }

    mutating func thresholdFired() -> [Effect] {
        guard phase == .charging else { return [] }
        phase = .active
        return [.engage(rate: turboRate)]
    }

    mutating func keyUp() -> [Effect] {
        end(released: true)
    }

    mutating func forceEnd() -> [Effect] {
        end(released: false)
    }

    private mutating func end(released: Bool) -> [Effect] {
        switch phase {
        case .idle:
            return []
        case .pendingTap:
            phase = .idle
            return released ? [.togglePlayback] : []
        case .charging:
            phase = .idle
            return released ? [.cancelThreshold, .togglePlayback] : [.cancelThreshold]
        case .active:
            phase = .idle
            return [.restore(rate: baseRate)]
        }
    }
}

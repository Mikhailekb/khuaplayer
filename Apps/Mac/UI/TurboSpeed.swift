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
    enum Owner: Hashable { case space, mouse }

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
    private(set) var owners: Set<Owner> = []
    private var overlappingPress = false
    private(set) var baseRate: Double = 1
    private(set) var turboRate: Double = 1

    var blocksPlaybackControls: Bool { phase != .idle }

    func hasOwner(_ owner: Owner) -> Bool { owners.contains(owner) }

    mutating func keyDown(enabled: Bool, playing: Bool,
                          currentRate: Double, configuredRate: Double) -> [Effect] {
        down(owner: .space, enabled: enabled, playing: playing,
             currentRate: currentRate, configuredRate: configuredRate)
    }

    /// Both physical inputs share one temporary rate. Joining a hold must not
    /// capture an already boosted rate as the speed to restore later.
    mutating func down(owner: Owner, enabled: Bool, playing: Bool,
                       currentRate: Double, configuredRate: Double) -> [Effect] {
        guard owners.insert(owner).inserted else { return [] }
        guard phase == .idle else {
            overlappingPress = true
            return []
        }
        overlappingPress = false
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

    mutating func keyUp() -> [Effect] { up(owner: .space) }

    mutating func up(owner: Owner) -> [Effect] {
        guard owners.remove(owner) != nil, owners.isEmpty else { return [] }
        return end(released: !overlappingPress)
    }

    /// Pointer cancellation leaves an independently held Space intact.
    mutating func forceEnd(owner: Owner) -> [Effect] {
        guard owners.remove(owner) != nil, owners.isEmpty else { return [] }
        return end(released: false)
    }

    mutating func forceEnd() -> [Effect] {
        owners.removeAll()
        return end(released: false)
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

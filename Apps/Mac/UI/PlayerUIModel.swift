import Foundation // TimeInterval（SeekBurstCadence）

// Core exposes requested, available, and active as independent runtime facts.
// The UI consumes this normalized model so buttons and menus cannot derive
// conflicting states. Content bypasses render as Off while retaining the
// request within the current media item; opening another item resets it.
// Transient preparation and seek bypasses retain the On appearance.
struct MotionPresentation: Equatable {
    enum VisualState: Equatable {
        case off
        case on
    }

    let visualState: VisualState
    let hasMedia: Bool
    let isAvailable: Bool
    let isActive: Bool
    let contentBypassed: Bool
    let status: String
    let unavailabilityDescription: String
    let requested: Bool
    let outputFPS: Double
    let sourceFPS: Double
    let coverage: Double

    init(hasMedia: Bool, requested: Bool, available: Bool,
         active: Bool, contentBypassed: Bool = false,
         outputFPS: Double = 0, sourceFPS: Double = 0,
         coverage: Double = 0, status: String,
         unavailabilityDescription: String = "") {
        self.requested = hasMedia && requested
        self.outputFPS = hasMedia ? outputFPS : 0
        self.sourceFPS = hasMedia ? sourceFPS : 0
        self.coverage = hasMedia ? coverage : 0
        self.hasMedia = hasMedia
        self.contentBypassed = hasMedia && contentBypassed
        self.visualState = hasMedia && requested && !contentBypassed ? .on : .off
        self.isAvailable = available
        self.isActive = hasMedia && active
        self.status = hasMedia ? status : L("chrome.memc.status.noMedia")
        self.unavailabilityDescription = hasMedia ? unavailabilityDescription : ""
    }

    static let idle = MotionPresentation(
        hasMedia: false, requested: false, available: false,
        active: false, status: ""
    )

    enum Light: Equatable { case red, orange, green }
    var light: Light? {
        guard hasMedia, requested else { return nil }
        if !isAvailable || contentBypassed { return .red }
        if !isActive || coverage < 0.9 { return .orange }
        return .green
    }

    var fpsReadout: String? {
        guard hasMedia else { return nil }
        let fps = outputFPS > 0 ? outputFPS : sourceFPS
        guard fps > 0 else { return nil }
        return String(format: "%.0f", fps)
    }

    var fpsReadoutDigits: Int {
        guard let readout = fpsReadout else { return 0 }

        guard isControlEnabled else { return readout.count }
        let doubled = sourceFPS > 0 ? String(format: "%.0f", sourceFPS * 2).count : 0
        return max(readout.count, doubled)
    }

    var sourceFPSText: String? {
        guard hasMedia, sourceFPS > 0 else { return nil }
        var text = String(format: "%.3f", sourceFPS)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    var selectedModeTag: Int { visualState == .on ? 1 : 0 }
    var isControlEnabled: Bool { hasMedia && isAvailable && !contentBypassed }

    func isMenuItemEnabled(tag: Int) -> Bool {
        tag == 0 || isControlEnabled
    }

    // Shared by the control, menu, and accessibility help. Diagnostic status
    // and coverage statistics stay out of this single-sentence explanation; the
    // source frame rate is appended because the chip shows only the output.
    var toolTip: String {
        guard let source = sourceFPSText else { return baseToolTip }
        return L("chrome.memc.tooltip.withSourceFPS", baseToolTip, source)
    }

    private var baseToolTip: String {
        guard hasMedia else { return L("chrome.memc.tooltip.noMedia") }
        guard isAvailable else { return L("chrome.memc.tooltip.unavailable") }
        guard !contentBypassed else {
            return unavailabilityDescription.isEmpty
                ? L("chrome.memc.tooltip.unknown") : unavailabilityDescription
        }
        guard visualState == .on else { return L("chrome.memc.tooltip.off") }
        guard isActive else { return L("chrome.memc.tooltip.on") }
        return coverage < 0.9 ? L("chrome.memc.tooltip.partial")
                              : L("chrome.memc.tooltip.active")
    }

    var accessibilityValue: String {
        guard hasMedia, isAvailable, !contentBypassed else {
            return L("chrome.a11y.unavailable")
        }
        guard visualState == .on else { return L("chrome.memc.a11y.notEnabled") }
        guard isActive else { return L("chrome.memc.a11y.preparing") }
        return coverage < 0.9 ? L("chrome.memc.a11y.partial") : L("chrome.a11y.on")
    }

    var menuToolTip: String { toolTip }
}

enum PlayerCommand: Equatable {
    case togglePlayback
    case seekRelative(Double)
    case seekAbsolute(Double)
    // Coarse keyframe seek resolved from seekRelative. `forward` selects the
    // first keyframe after the target so forward steps still advance when the
    // GOP is longer than the requested interval.
    case seekCoarse(Double, forward: Bool)
    case setPlaybackRate(Double)
    case adjustVolumePercent(Double)
    case setVolumePercent(Double)
    case toggleMute
    case toggleFullscreen
    case setLoopPointA
    case setLoopPointB
    case clearLoop
    case stepFrame(Int)
    case captureScreenshot
    case openDocument
    case loadSubtitle
    case showMediaInfo
    case selectSubtitleTrack(Int)
    case selectAudioTrack(Int)
    case setSubtitleScale(Double)
    case toggleFrameInterpolation
    case setFrameInterpolation(Bool)
    case toggleXDR
    case setXDR(Bool)
    case setRotation(Int)
    case setMirror(Int)
    case previousMedia
    case nextMedia
}

struct PlayerCommandContext: Equatable {
    var hasMedia: Bool
    var position: Double
    var duration: Double
    var volumePercent: Double
    var volumeBoostUnlocked: Bool = false
    var hasMultipleMedia: Bool
    var frameInterpolationAvailable: Bool
    var frameInterpolationRequested: Bool

    var xdrAvailable: Bool = false
    var xdrRequested: Bool = false

    var relativeSeekBase: Double? = nil

    var coarseSeekLanding: Double = -1

    static let empty = PlayerCommandContext(
        hasMedia: false, position: 0, duration: 0,
        volumePercent: 100, hasMultipleMedia: false,
        frameInterpolationAvailable: false, frameInterpolationRequested: false
    )
}

enum PlayerCommandPolicy {
    static let playbackRateRange = 0.25...5.0
    static let normalVolumePercentRange = 0.0...100.0
    static let boostedVolumePercentRange = 0.0...500.0
    static let subtitleScaleRange = 0.25...3.0

    static func backwardStepTarget(nominal: Double, position: Double,
                                   landing: Double, step: Double) -> Double {
        guard landing >= 0, nominal >= landing else { return nominal }
        return min(nominal, position - step)
    }

    static func resolve(_ command: PlayerCommand,
                        in context: PlayerCommandContext) -> PlayerCommand? {
        if requiresMedia(command), !context.hasMedia { return nil }

        switch command {
        case .seekRelative(let delta):
            let base = context.relativeSeekBase ?? context.position
            var target = base + delta
            if delta < 0 {
                target = backwardStepTarget(nominal: target, position: context.position,
                                            landing: context.coarseSeekLanding, step: -delta)
            }
            return .seekCoarse(clampSeek(target, duration: context.duration),
                               forward: delta > 0)
        case .seekAbsolute(let target):
            return .seekAbsolute(clampSeek(target, duration: context.duration))
        case .seekCoarse(let target, let forward):
            return .seekCoarse(clampSeek(target, duration: context.duration),
                               forward: forward)
        case .setPlaybackRate(let rate):
            return .setPlaybackRate(clamp(rate, to: playbackRateRange))
        case .adjustVolumePercent(let delta):
            return .setVolumePercent(clamp(context.volumePercent + delta,
                                           to: context.volumeBoostUnlocked
                                               ? boostedVolumePercentRange
                                               : normalVolumePercentRange))
        case .setVolumePercent(let value):
            return .setVolumePercent(clamp(value, to: context.volumeBoostUnlocked
                                                ? boostedVolumePercentRange
                                                : normalVolumePercentRange))
        case .setSubtitleScale(let value):
            return .setSubtitleScale(clamp(value, to: subtitleScaleRange))
        case .stepFrame(let delta):
            guard delta != 0 else { return nil }
            return .stepFrame(delta < 0 ? -1 : 1)
        case .toggleFrameInterpolation:
            let enabling = !context.frameInterpolationRequested
            if enabling && (!context.hasMedia || !context.frameInterpolationAvailable) {
                return nil
            }
            return .setFrameInterpolation(enabling)
        case .setFrameInterpolation(let enabled):
            if enabled && (!context.hasMedia || !context.frameInterpolationAvailable) {
                return nil
            }
            return .setFrameInterpolation(enabled)
        case .toggleXDR:
            let enabling = !context.xdrRequested
            if enabling && !context.xdrAvailable { return nil }
            return .setXDR(enabling)
        case .setXDR(let enabled):
            if enabled && !context.xdrAvailable { return nil }
            return .setXDR(enabled)
        case .previousMedia, .nextMedia:
            return context.hasMedia && context.hasMultipleMedia ? command : nil
        default:
            return command
        }
    }

    static func revealsControls(after command: PlayerCommand) -> Bool {
        switch command {
        case .togglePlayback, .seekRelative, .seekAbsolute, .seekCoarse,
             .setPlaybackRate, .adjustVolumePercent, .setVolumePercent, .toggleMute,
             .setLoopPointA, .setLoopPointB, .clearLoop, .stepFrame,
             .toggleFrameInterpolation, .setFrameInterpolation,
             .toggleXDR, .setXDR:
            return true
        default:
            return false
        }
    }

    private static func requiresMedia(_ command: PlayerCommand) -> Bool {
        switch command {
        case .togglePlayback, .seekRelative, .seekAbsolute, .seekCoarse,
             .setLoopPointA, .setLoopPointB, .clearLoop, .stepFrame,
             .captureScreenshot, .showMediaInfo,
             .selectSubtitleTrack, .selectAudioTrack:
            return true
        default:
            return false
        }
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }

    private static func clampSeek(_ value: Double, duration: Double) -> Double {
        let upper = duration > 0 ? duration : Double.greatestFiniteMagnitude
        return min(upper, max(0, value))
    }
}

/// The UI exposes only normal, boundary prompt, and unlocked boost states.
/// Real-time limiter activity does not create another presentation state.
enum VolumeBoostPresentation: Equatable {
    case normal
    case prompted
    case unlocked
}

enum PlayerPresentationLifecycle: Equatable {
    case empty
    case idle
    case opening
    case playing
    case paused
    case ended
    case failed
}

struct XDRPresentation: Equatable {
    let hasMedia: Bool
    let contentSDR: Bool
    let displayCapable: Bool
    let requested: Bool
    let headroom: Double

    init(hasMedia: Bool, contentSDR: Bool, displayCapable: Bool,
         requested: Bool, headroom: Double = 1) {
        self.hasMedia = hasMedia
        self.contentSDR = hasMedia && contentSDR
        self.displayCapable = displayCapable
        self.requested = requested
        self.headroom = max(1, headroom)
    }

    static let idle = XDRPresentation(hasMedia: false, contentSDR: false,
                                      displayCapable: false, requested: false)

    var isControlEnabled: Bool { hasMedia && contentSDR && displayCapable }
    var isOn: Bool { isControlEnabled && requested }
}

struct PlayerPresentationSnapshot: Equatable {
    var position: Double
    var duration: Double
    var playbackRate: Double
    var volumePercent: Double
    var isMuted: Bool
    var volumeBoost: VolumeBoostPresentation = .normal
    var hdrDescription: String?
    var hdrDetail: String?
    var motion: MotionPresentation
    var xdr: XDRPresentation = .idle
}

struct ChromePresentation: Equatable {
    var lifecycle: PlayerPresentationLifecycle
    var position: Double
    var duration: Double
    var playbackRate: Double
    var volumePercent: Double
    var isMuted: Bool
    var volumeBoost: VolumeBoostPresentation = .normal
    var hdrDescription: String?
    var hdrDetail: String?
    var motion: MotionPresentation
    var xdr: XDRPresentation = .idle

    static let empty = ChromePresentation(
        lifecycle: .empty, position: 0, duration: 0, playbackRate: 1,
        volumePercent: 100, isMuted: false,
        hdrDescription: nil, hdrDetail: nil, motion: .idle
    )

    var isPlaying: Bool { lifecycle == .playing }
    var shouldRevealControls: Bool { lifecycle == .ended }
}

/// Navigation belongs to the active catalogue, independent of whether its
/// sidebar is open. An invalid or single-item catalogue reserves no controls.
struct SPPlaylistNavigationPresentation: Equatable {
    let isVisible: Bool
    let canPrevious: Bool
    let canNext: Bool

    init(hasMedia: Bool, count: Int, currentIndex: Int, enabled: Bool = true) {
        let valid = hasMedia && count > 1 && currentIndex >= 0 && currentIndex < count
        isVisible = valid
        canPrevious = valid && enabled && currentIndex > 0
        canNext = valid && enabled && currentIndex < count - 1
    }

    static let none = Self(hasMedia: false, count: 0, currentIndex: -1)
}

enum PlayerPresentationEvent: Equatable {
    case stateChanged(PlayerPresentationLifecycle, PlayerPresentationSnapshot)
    case timelineChanged(position: Double, duration: Double, rate: Double)
    case playbackRateChanged(Double)
    case volumeChanged(percent: Double, muted: Bool, boost: VolumeBoostPresentation)
    case hdrChanged(description: String?, detail: String?)
    case motionChanged(MotionPresentation)
    case xdrChanged(XDRPresentation)
    case sessionClosed
    case terminalFailure(PlayerPresentationSnapshot)
    case recoverableWarning
}

enum PlayerFailureReason: String, Equatable {
    case incomplete
    case waitingForDownload
    case noPlayableTrack
    case unsupported
    case decodeFailed
    case generic

    var localizedTitle: String {
        self == .waitingForDownload ? L("emptyState.title.waitingForDownload") : L("emptyState.title")
    }
    var localizedReason: String {
        switch self {
        case .incomplete: return L("emptyState.reason.incomplete")
        case .waitingForDownload: return L("emptyState.reason.waitingForIndex")
        case .noPlayableTrack: return L("emptyState.reason.noPlayableTrack")
        case .unsupported: return L("emptyState.reason.unsupported")
        case .decodeFailed: return L("emptyState.reason.decodeFailed")
        case .generic: return L("emptyState.reason.generic")
        }
    }

    static func from(diagnosis: String?) -> PlayerFailureReason {
        switch diagnosis {
        case "zeroHead", "indexAtTail", "missingMetadata": return .incomplete
        case "indexAtTailDownloading": return .waitingForDownload
        case "noPlayableTrack": return .noPlayableTrack
        case "decoderCreate": return .unsupported
        case "decodeFailed": return .decodeFailed
        default: return .generic
        }
    }
}

enum PlayerFailureAction: Equatable {
    case none
    case alert
    case rememberPending(PlayerFailureReason)
    case upgradeShown(PlayerFailureReason)
}

struct PlayerFailureTracker: Equatable {
    private(set) var pending: PlayerFailureReason?
    private(set) var shown: PlayerFailureReason?

    mutating func noteError(domain: String, diagnosis: String?, terminal: Bool?) -> PlayerFailureAction {
        if domain == "SPURLError" || diagnosis == "url" { return .alert }
        guard let terminal else { return .alert }
        if !terminal { return .none }
        let reason = PlayerFailureReason.from(diagnosis: diagnosis)
        if shown != nil {
            shown = reason
            return .upgradeShown(reason)
        }
        pending = reason
        return .rememberPending(reason)
    }

    mutating func noteFailedState() -> PlayerFailureReason {
        let reason = pending ?? .generic
        pending = nil
        shown = reason
        return reason
    }

    mutating func reset() {
        pending = nil
        shown = nil
    }

    var isShowing: Bool { shown != nil }
}

enum PlayerPresentationReducer {
    static func reduce(_ current: ChromePresentation,
                       _ event: PlayerPresentationEvent) -> ChromePresentation {
        switch event {
        case .stateChanged(let lifecycle, let snapshot):
            switch lifecycle {
            case .empty:
                return reset(current, lifecycle: .empty, snapshot: snapshot,
                             motion: .idle)
            case .idle, .opening:
                return reset(current, lifecycle: lifecycle, snapshot: snapshot,
                             motion: snapshot.motion, xdr: snapshot.xdr)
            case .playing, .paused, .ended:
                return ChromePresentation(
                    lifecycle: lifecycle,
                    position: snapshot.position,
                    duration: snapshot.duration,
                    playbackRate: snapshot.playbackRate,
                    volumePercent: snapshot.volumePercent,
                    isMuted: snapshot.isMuted,
                    volumeBoost: snapshot.volumeBoost,
                    hdrDescription: snapshot.hdrDescription,
                    hdrDetail: snapshot.hdrDetail,
                    motion: snapshot.motion,
                    xdr: snapshot.xdr
                )
            case .failed:
                return reset(current, lifecycle: .failed, snapshot: snapshot,
                             motion: .idle)
            }

        case .timelineChanged(let position, let duration, let rate):
            guard current.lifecycle != .empty, current.lifecycle != .failed else {
                return current
            }
            var next = current
            next.position = position
            next.duration = duration
            next.playbackRate = rate
            return next

        case .playbackRateChanged(let rate):
            var next = current
            next.playbackRate = rate
            return next

        case .volumeChanged(let percent, let muted, let boost):
            var next = current
            next.volumePercent = percent
            next.isMuted = muted
            next.volumeBoost = boost
            return next

        case .hdrChanged(let description, let detail):
            guard current.lifecycle == .playing || current.lifecycle == .paused ||
                  current.lifecycle == .ended else { return current }
            var next = current
            next.hdrDescription = description
            next.hdrDetail = detail
            return next

        case .motionChanged(let motion):
            guard current.lifecycle != .empty, current.lifecycle != .failed else {
                return current
            }
            var next = current
            next.motion = motion
            return next

        case .xdrChanged(let xdr):
            guard current.lifecycle != .empty, current.lifecycle != .failed else {
                return current
            }
            var next = current
            next.xdr = xdr
            return next

        case .sessionClosed:
            var next = reset(current, lifecycle: .empty, snapshot: nil,
                             motion: .idle)
            // Enforce the media boundary here without requiring a prior reset event.
            next.volumePercent = min(next.volumePercent, 100)
            next.volumeBoost = .normal
            return next

        case .terminalFailure(let snapshot):
            return reset(current, lifecycle: .failed, snapshot: snapshot,
                         motion: .idle)

        case .recoverableWarning:
            return current
        }
    }

    private static func reset(_ current: ChromePresentation,
                              lifecycle: PlayerPresentationLifecycle,
                              snapshot: PlayerPresentationSnapshot?,
                              motion: MotionPresentation,
                              xdr: XDRPresentation = .idle) -> ChromePresentation {
        ChromePresentation(
            lifecycle: lifecycle,
            position: 0,
            duration: 0,
            playbackRate: snapshot?.playbackRate ?? current.playbackRate,
            volumePercent: snapshot?.volumePercent ?? current.volumePercent,
            isMuted: snapshot?.isMuted ?? current.isMuted,
            volumeBoost: snapshot?.volumeBoost ?? current.volumeBoost,
            hdrDescription: nil,
            hdrDetail: nil,
            motion: motion,
            xdr: xdr
        )
    }
}

enum SeekBurstCadence {
    /// Minimum time to recognize each preview frame, independent of seek latency.
    /// Forty milliseconds permits 25 steps per second; changes affect interaction
    /// pacing and should be evaluated with real keyboard input.
    static let dwell: TimeInterval = 0.04

    static let settleTimeout: TimeInterval = 0.30

    static let settlePoll: TimeInterval = 0.01

    static func nextTickDelay(elapsed: TimeInterval, settled: Bool) -> TimeInterval {
        if elapsed < dwell { return dwell - elapsed }
        if !settled && elapsed < settleTimeout { return min(settlePoll, settleTimeout - elapsed) }
        return dwell
    }
}

enum LaunchWindowSize {
    static let mediaWidth: CGFloat = 1280
    static let screenMargin: CGFloat = 40
    static let aspectW: CGFloat = 16
    static let aspectH: CGFloat = 9

    static func mediaContentSize(visible: CGSize) -> CGSize {
        let unclamped = CGSize(width: mediaWidth,
                               height: (mediaWidth * aspectH / aspectW).rounded())
        guard visible.width > 0, visible.height > 0 else { return unclamped }
        var w = min(mediaWidth, max(1, visible.width - screenMargin))
        var h = (w * aspectH / aspectW).rounded()
        if h > visible.height {

            h = visible.height.rounded(.down)
            w = (h * aspectW / aspectH).rounded()
        }
        return CGSize(width: w, height: h)
    }
}

// MARK: - Feature chip lamp

/// One animated quantity. Retargeting starts from the value shown at that
/// instant, so interrupted transitions continue instead of restarting.
struct SPLampTween: Equatable {
    enum Curve: Equatable { case easeOut, easeInOut }
    private(set) var from: Double
    private(set) var to: Double
    private var start: Double = 0
    private var duration: Double = 0
    private var curve: Curve = .easeInOut

    init(_ value: Double) {
        from = value
        to = value
    }

    func value(at t: Double) -> Double {
        guard duration > 0 else { return to }
        let k = min(1, max(0, (t - start) / duration))
        let e: Double
        switch curve {
        case .easeOut: e = 1 - pow(1 - k, 3)
        case .easeInOut: e = k < 0.5 ? 4 * k * k * k : 1 - pow(-2 * k + 2, 3) / 2
        }
        return from + (to - from) * e
    }

    func isSettled(at t: Double) -> Bool { duration <= 0 || t - start >= duration }

    mutating func retarget(_ target: Double, duration d: Double, at t: Double,
                           curve c: Curve = .easeInOut) {
        guard target != to else { return }
        from = value(at: t)
        to = target
        start = t
        duration = max(0, d)
        curve = c
    }

    mutating func snap() {
        from = to
        duration = 0
    }
}

/// Timing model for the lamp drawn at the leading edge of a feature chip.
/// `orbit`: a ball that circles the lamp while hovered, stepping through eight
/// positions when off and gliding with a trail when on. `moon`: a disc whose
/// lit part grows from new moon (off) to a crescent (hover) to full (on).
struct SPChipLampModel {
    enum Kind: Equatable { case orbit, moon }

    struct Frame: Equatable {
        var radius = 0.0              // orbit radius as a fraction of the full orbit
        var theta = -Double.pi / 2    // continuous orbit angle (radians)
        var angle = -Double.pi / 2    // displayed angle: stepped when off, continuous when on
        var smoothness = 0.0          // 0 = eight-step, 1 = continuous
        var trail = 0.0
        var light = 0.0               // moon: 0 new, 0.4 hover crescent, 1 full
        var bloom = 0.0               // moon: extra glow while hovered and on
    }

    static let orbitSpeed = 2 * Double.pi * 1.1     // radians per second
    static let orbitSteps = 8.0
    static let pulseDuration = 0.8                   // keyboard/menu turn-on lap
    static let hoverLight = 0.4

    let kind: Kind
    var reduceMotion = false
    private(set) var isOn = false
    private(set) var isHovered = false
    private(set) var isEnabled = true
    private var pulseUntil = -Double.infinity
    private var radius = SPLampTween(0)
    private var smoothness = SPLampTween(0)
    private var trail = SPLampTween(0)
    private var light = SPLampTween(0)
    private var bloom = SPLampTween(0)
    private var theta = -Double.pi / 2
    private var lastTime: Double?

    init(kind: Kind) { self.kind = kind }

    var isPulsing: Bool { pulseUntil > -Double.infinity }

    /// Presentation update. `animated == false` (setup, hidden replay) jumps to
    /// the final look; a turn-on without hover plays one orbit lap.
    mutating func setState(on: Bool, enabled: Bool, animated: Bool, at t: Double) {
        let turnedOn = on && !isOn
        let changed = on != isOn || enabled != isEnabled
        isOn = on
        isEnabled = enabled
        if !animated || !on || !enabled { pulseUntil = -Double.infinity }
        if turnedOn, animated, enabled, !isHovered, !reduceMotion, kind == .orbit {
            pulseUntil = t + Self.pulseDuration
        }
        if changed { retarget(at: t, pulse: turnedOn && isPulsing) }
        if !animated { snap(at: t) }
    }

    mutating func setHovered(_ hovered: Bool, at t: Double) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        retarget(at: t, hover: true)
    }

    /// Drop hover without animation (chip hidden or window deactivated).
    mutating func clearHover(at t: Double) {
        isHovered = false
        pulseUntil = -Double.infinity
        retarget(at: t)
        snap(at: t)
    }

    mutating func snap(at t: Double) {
        radius.snap(); smoothness.snap(); trail.snap(); light.snap(); bloom.snap()
        if radius.to == 0 { theta = -Double.pi / 2 }
        lastTime = t
    }

    /// Advance to `t` and return what to draw. Integrates the orbit angle and
    /// ends a finished turn-on lap.
    mutating func frame(at t: Double) -> Frame {
        if isPulsing, t >= pulseUntil {
            pulseUntil = -Double.infinity
            retarget(at: t)
        }
        let dt = lastTime.map { min(0.05, max(0, t - $0)) } ?? 0
        lastTime = t
        var f = Frame()
        switch kind {
        case .orbit:
            f.radius = radius.value(at: t)
            if f.radius > 0.001 {
                theta += Self.orbitSpeed * dt
                // Whole turns keep the eight-step phase and bound the value.
                if theta > 2 * Double.pi * 64 { theta -= 2 * Double.pi * 64 }
            } else {
                theta = -Double.pi / 2
            }
            let step = 2 * Double.pi / Self.orbitSteps
            let stepped = (theta / step + 1e-9).rounded(.down) * step
            f.theta = theta
            f.smoothness = smoothness.value(at: t)
            f.angle = stepped + (theta - stepped) * f.smoothness
            f.trail = trail.value(at: t)
        case .moon:
            f.light = light.value(at: t)
            f.bloom = bloom.value(at: t)
        }
        return f
    }

    /// True when further frames would draw the same image.
    func isSettled(at t: Double) -> Bool {
        if isPulsing { return false }
        switch kind {
        case .orbit:
            if radius.to > 0 || radius.value(at: t) > 0.001 { return false }
            return radius.isSettled(at: t)
        case .moon:
            return light.isSettled(at: t) && bloom.isSettled(at: t)
        }
    }

    private func duration(_ d: Double) -> Double { reduceMotion ? 0 : d }

    private mutating func retarget(at t: Double, hover: Bool = false, pulse: Bool = false) {
        switch kind {
        case .orbit:
            let awake = (isHovered && isEnabled) || isPulsing
            let want: Double = awake && !reduceMotion ? 1 : 0
            if want > radius.to {
                radius.retarget(1, duration: duration(pulse ? 0.2 : 0.25), at: t, curve: .easeOut)
            } else if want < radius.to {
                radius.retarget(0, duration: duration(isOn ? 0.35 : 0.3), at: t)
            }
            smoothness.retarget(isOn ? 1 : 0, duration: duration(isOn ? 0.45 : 0.3), at: t)
            trail.retarget(isOn ? 1 : 0, duration: duration(isOn ? 0.35 : 0.2), at: t)
        case .moon:
            let target = isEnabled ? (isOn ? 1 : (isHovered ? Self.hoverLight : 0)) : 0
            light.retarget(target, duration: duration(hover ? 0.3 : 0.45), at: t)
            bloom.retarget(isOn && isHovered && isEnabled ? 1 : 0, duration: duration(0.3), at: t)
        }
    }
}

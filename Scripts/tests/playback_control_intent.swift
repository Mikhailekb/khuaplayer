import Foundation

enum PlayerCommand: Equatable {
    case togglePlayback, seekRelative, seekAbsolute, seekCoarse, setPlaybackRate, stepFrame
    case previousMedia, nextMedia, toggleFrameInterpolation, setFrameInterpolation
    case unrelated
}
enum PlayerCommandPolicy { static let playbackRateRange = 0.25...8.0 }
private enum SPTurboSettings { static let isEnabled = true; static let rate = 2.0 }
// INSERT_TURBO

private enum SPPlaybackDiagnostics {
    enum Event { case snapshot, state, control, seek, sourceWait, close }
    enum Control { case toggle, play, pause, autoPauseScroll, autoResumeScroll, autoPauseBurst, autoResumeBurst }
}
@MainActor private final class Core {
    enum State { case idle, opening, ready, playing, paused, ended, failed }
    var state: State
    var position = 10.0, duration = 100.0, playbackRate = 1.0
    var calls: [String] = []
    var isPlaying: Bool { state == .playing }
    init(_ state: State) { self.state = state }
    func play() { calls.append("play"); state = .playing }
    func pause() { calls.append("pause"); state = .paused }
    func togglePlayPause() { isPlaying ? pause() : play() }
}
private enum Presentation { case timelineChanged(position: Double, duration: Double, rate: Double) }
@MainActor private final class Controller {
    var core: Core?
    var hasVideoSession = true
    var foregroundYields = 0
    var feedback: [Bool] = []
    var controlsShown = 0
    var pendingSeekCalls = 0
    var scrollSeekTarget: Double?
    var scrollSeekWasPlaying = false
    var scrollGestureTimeout: Timer?
    var gestureSeekTimer: Timer?
    var gestureSeek = SPPlaybackGestureSeek()
    var scrollGesture = SPPlaybackScrollGesture()
    var isScrubbing = false
    var repeatTimer: Timer?
    var repeatAction: (() -> Void)?
    var repeatNextInterval: (() -> Double)?
    var repeatOwnerKeyCode: UInt16?
    var seekStepInFlight = false
    var burstStepCount = 0
    var burstTarget = 0.0
    var burstWasPlaying = false
    var lastRelSeekTarget = -1.0
    var lastRelSeekAt = 0.0
    var turbo = SPTurboGesture()
    init(_ state: Core.State) { core = Core(state) }
    func cancelVideoClick() {}
    func yieldDirectoryScanToForegroundIO() { foregroundYields += 1 }
    func showPlaybackFeedback(isPlaying: Bool) { feedback.append(isPlaying) }
    func transitionPresentation(_ presentation: Presentation) {}
    func showControlsTemporarily() { controlsShown += 1 }
    func issuePlaybackGestureSeek(_ delta: Double) { pendingSeekCalls += 1 }
    func recordPlaybackDiagnostic(_ event: SPPlaybackDiagnostics.Event,
                                  control: SPPlaybackDiagnostics.Control? = nil,
                                  seekTarget: Double? = nil, commandValue: Double? = nil) {}
    func applyTurbo(_ effects: [SPTurboGesture.Effect], reason: String) {
        for effect in effects { if effect == .togglePlayback { togglePlaybackNow() } }
    }
    func clickPlay() { perform(.togglePlayback) }
    func releaseScroll() { cancelPlaybackScroll() }
    func releaseBurst() { stopRepeat() }
    func pressSpace() { turboSpaceDown() }
    func releaseSpace() { applyTurbo(turbo.keyUp(), reason: "fixture") }
    func seedScroll(wasPlaying: Bool = true) {
        scrollSeekTarget = 10; scrollSeekWasPlaying = wasPlaying; isScrubbing = true
        gestureSeek.submit(3)
    }
    func seedBurst(wasPlaying: Bool = true) {
        repeatOwnerKeyCode = 124; burstStepCount = 2; burstTarget = 20; burstWasPlaying = wasPlaying
    }
    // INSERT_METHODS
}

@main @MainActor private struct PlaybackControlIntentChecks {
    static var count = 0
    static func check(_ condition: Bool, _ text: String) {
        precondition(condition, text)
        count += 1; print("PASS \(count): \(text)")
    }
    static func main() {
        let scroll = Controller(.paused); scroll.seedScroll(); scroll.clickPlay()
        check(scroll.core!.state == .playing && scroll.core!.calls == ["play"],
              "Click Play during an auto-paused scroll seek plays exactly once")
        check(scroll.scrollSeekTarget == nil && !scroll.scrollSeekWasPlaying && !scroll.isScrubbing,
              "Explicit Play revokes the scroll's delayed resume ownership")
        check(scroll.pendingSeekCalls == 1, "Scroll cleanup still drains unissued seek movement")
        scroll.releaseScroll()
        check(scroll.core!.calls == ["play"], "A later gesture-end cannot resume again")
        let burst = Controller(.paused); burst.seedBurst(); burst.clickPlay()
        check(burst.core!.state == .playing && burst.core!.calls == ["play"],
              "Click Play during a held-arrow pause plays exactly once")
        check(burst.repeatOwnerKeyCode == nil && !burst.burstWasPlaying && burst.burstStepCount == 0,
              "Explicit Play revokes held-key resume ownership")
        burst.releaseBurst()
        check(burst.core!.calls == ["play"], "A later key-up cannot resume again")
        let playing = Controller(.playing); playing.clickPlay()
        check(playing.core!.state == .paused && playing.core!.calls == ["pause"] && playing.feedback == [false],
              "Click Pause keeps the explicitly observed playing intent")
        let paused = Controller(.paused); paused.clickPlay()
        check(paused.core!.calls == ["play"] && paused.feedback == [true], "Ordinary Play keeps its feedback")
        let ended = Controller(.ended); ended.clickPlay()
        check(ended.core!.calls == ["play"] && ended.foregroundYields == 1, "Replay still yields storage before the implicit zero seek")
        let release = Controller(.paused); release.seedScroll(); release.releaseScroll()
        check(release.core!.calls == ["play"], "Ordinary scroll release retains automatic resume")
        let wasPaused = Controller(.paused); wasPaused.seedScroll(wasPlaying: false); wasPaused.releaseScroll()
        check(wasPaused.core!.calls.isEmpty && wasPaused.core!.state == .paused,
              "A scroll begun while paused never auto-resumes")
        let burstRelease = Controller(.paused); burstRelease.seedBurst(); burstRelease.releaseBurst()
        check(burstRelease.core!.calls == ["play"] && burstRelease.lastRelSeekTarget == 20,
              "Ordinary held-key release resumes and preserves the sticky seek target")
        let spaceScroll = Controller(.paused); spaceScroll.seedScroll(); spaceScroll.pressSpace()
        check(spaceScroll.core!.calls.isEmpty, "Space down cancels scroll without an automatic playback bounce")
        spaceScroll.releaseSpace()
        check(spaceScroll.core!.calls == ["play"] && spaceScroll.core!.state == .playing,
              "Space release preserves Play intent after an auto-paused scroll")
        let spaceBurst = Controller(.paused); spaceBurst.seedBurst(); spaceBurst.pressSpace(); spaceBurst.releaseSpace()
        check(spaceBurst.core!.calls == ["play"] && spaceBurst.repeatOwnerKeyCode == nil,
              "Space preserves Play intent after a held-arrow pause")
        let noCore = Controller(.paused); noCore.core = nil; noCore.clickPlay()
        check(noCore.feedback.isEmpty, "A missing Core cannot emit misleading playback feedback")
        let notReady = Controller(.opening); notReady.clickPlay()
        check(notReady.core!.calls.isEmpty && notReady.feedback.isEmpty,
              "An opening Core cannot receive an accidental playback command")
        print("\(count) actual-controller playback intent checks passed")
    }
}

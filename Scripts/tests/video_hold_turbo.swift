import AppKit
import Foundation

// Only physical input, settings, media engine and HUD are controlled. The test
// script inserts the current production controller's exact owner methods here.
@MainActor private enum SPHoldFixtureInput {
    static var pointer = CGPoint(x: 300, y: 300)
    static var buttons = 1
    static var enabled = true
    static var configuredRate: Double = 2
}
private enum SPHoldState { case playing, paused, ended, opening }
@MainActor private final class SPHoldCore {
    var state: SPHoldState = .playing
    var playbackRate: Double = 1.25
    var rates: [Double] = []
    var toggles = 0
    func setPlaybackRate(_ rate: Double) { playbackRate = rate; rates.append(rate) }
    func play() { state = .playing; toggles += 1 }
    func pause() { state = .paused; toggles += 1 }
}
@MainActor private final class SPHoldChrome {
    var phase: SPTurboGesture.Phase = .idle
    func setTurboPhase(_ phase: SPTurboGesture.Phase) { self.phase = phase }
    func playVolumeBoostInvitation() {}
}
@MainActor private final class SPHoldHUD {
    var visible = false
    var active = false
    func beginCharge(targetRate: Double) { visible = true; active = false }
    func cancelCharge() { visible = false; active = false }
    func engage(baseRate: Double, rate: Double) { visible = true; active = true }
    func dismiss() { visible = false; active = false }
}
private enum SPHoldCommand { case togglePlayback }
private enum SPHoldPresentation { case playbackRateChanged(Double) }
private enum SPHoldDiagnostic { case control }
private enum SPHoldControl { case toggle }
@MainActor private final class SPHoldWindow: NSWindow {
    var fixtureKey = true
    override var isKeyWindow: Bool { fixtureKey }
}

@MainActor private final class SPHoldPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { true }
}

@MainActor private final class SPHoldOwner {
    static let dbg = false
    static let turboSpaceKeyCode: UInt16 = 49
    static let compareKeyCode: UInt16 = 8
    let playerView = PlayerView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    var core: SPHoldCore? = SPHoldCore()
    var chrome: SPHoldChrome? = SPHoldChrome()
    var turboHUD: SPHoldHUD? = SPHoldHUD()
    var turbo = SPTurboGesture()
    var turboTimer: Timer?
    var videoHoldTimer: Timer?
    var hasMediaSession = true
    var hasVideoSession = true
    var isSettingsPanelShown = false
    var isPlaylistShown = false
    var repeatOwnerKeyCode: UInt16?
    var compareActive = false
    var volumeBoostPrompted = false
    var volumeBoostUnlocked = false
    var openPanelQuietPrewarmWork: DispatchWorkItem?
    var view: NSView { playerView }
    var feedback: [Bool] = []
    init() {
        playerView.onMouseDown = { [weak self] in self?.noteVideoMouseDown($0) }
        playerView.onMouseUp = { [weak self] in self?.resolveClickCandidate($0) }
        playerView.onKeyDown = { [weak self] event in
            guard let self, !event.isARepeat,
                  !self.turbo.blocksPlaybackControls || Self.turboAllowedKey(event) else { return }
            if event.keyCode == Self.turboSpaceKeyCode { self.turboSpaceDown() }
        }
        playerView.onKeyUp = { [weak self] in self?.handleKeyUp($0) }
        playerView.onResignFirstResponder = { [weak self] in self?.endTurbo(reason: "focusLost") }
    }
    func shutdown() {
        endTurbo(reason: "fixtureTeardown")
        if let clickUpMonitor { NSEvent.removeMonitor(clickUpMonitor); self.clickUpMonitor = nil }
    }
    func cancelPlaybackScroll(resumePlayback: Bool = true) {}
    func perform(_ command: SPHoldCommand) { togglePlaybackNow() }
    func stopRepeat(resumePlayback: Bool = true) { repeatOwnerKeyCode = nil }
    func yieldDirectoryScanToForegroundIO() {}
    func setMotionCompare(_ on: Bool) { compareActive = on }
    func recordPlaybackDiagnostic(_ event: SPHoldDiagnostic, control: SPHoldControl, commandValue: Double) {}
    func transitionPresentation(_ event: SPHoldPresentation) {}
    func refreshMotionSmoothingControl() {}
    func turboHUDView() -> SPHoldHUD { turboHUD! }
    func showPlaybackFeedback(isPlaying: Bool) { feedback.append(isPlaying) }
    func drag() { cancelClickCandidateIfDragged() }
    func poll() { validateVideoHold() }
    func cancel() { cancelVideoClick() }
    func lifecycleEnd() { endTurbo(reason: "settingsOrSession") }
    // INSERT_PRODUCTION_METHODS
}

@main private struct SPVideoHoldChecks {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { print("FAIL: \(name)"); exit(1) }
            checks += 1
        }
        func wait(_ seconds: TimeInterval) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
        }
        func fixture() -> (SPHoldOwner, SPHoldWindow) {
            SPHoldFixtureInput.pointer = CGPoint(x: 300, y: 300)
            SPHoldFixtureInput.buttons = 1
            SPHoldFixtureInput.enabled = true
            let owner = SPHoldOwner()
            let window = SPHoldWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 400),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = owner.playerView
            return (owner, window)
        }
        func mouse(_ owner: SPHoldOwner, _ window: NSWindow, down: Bool, count: Int = 1,
                   flags: NSEvent.ModifierFlags = []) {
            let event = NSEvent.mouseEvent(with: down ? .leftMouseDown : .leftMouseUp,
                location: CGPoint(x: 100, y: 100), modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: count, pressure: down ? 1 : 0)!
            if down { owner.playerView.mouseDown(with: event) }
            else { SPHoldFixtureInput.buttons = 0; owner.playerView.mouseUp(with: event) }
        }
        func space(_ owner: SPHoldOwner, down: Bool, repeatKey: Bool = false) {
            let event = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: owner.playerView.window!.windowNumber, context: nil,
                characters: " ", charactersIgnoringModifiers: " ", isARepeat: repeatKey, keyCode: 49)!
            if down { owner.playerView.keyDown(with: event) } else { owner.playerView.keyUp(with: event) }
        }
        do {
            let (owner, window) = fixture(); defer { owner.shutdown() }
            mouse(owner, window, down: true)
            check(owner.core?.toggles == 0 && owner.core?.playbackRate == 1.25, "mouse down preserves playback and original rate")
            check(owner.turbo.phase == .charging && owner.turboHUD?.visible == true, "mouse press uses existing charging HUD")
            mouse(owner, window, down: false)
            check(owner.core?.state == .paused && owner.core?.toggles == 1, "short native PlayerView click pauses synchronously on release")
            mouse(owner, window, down: false)
            check(owner.core?.toggles == 1, "duplicate monitor/responder release cannot toggle twice")
            wait(0.30)
            check(owner.core?.rates.isEmpty == true && owner.turboHUD?.visible == false, "short click cancels late threshold and HUD")
        }
        do {
            let (owner, window) = fixture(); defer { owner.shutdown() }
            mouse(owner, window, down: true); wait(0.32)
            check(owner.core?.playbackRate == 2 && owner.turboHUD?.active == true, "real common-mode timer engages mouse turbo and HUD")
            space(owner, down: false)
            check(owner.core?.playbackRate == 2 && owner.turbo.phase == .active, "unrelated Space release cannot restore a mouse hold")
            mouse(owner, window, down: false)
            check(owner.core?.rates == [2, 1.25] && owner.core?.toggles == 0, "long mouse release restores exact base rate without pausing")
            check(owner.turboHUD?.visible == false && owner.chrome?.phase == .idle, "long release clears HUD and chrome phase")
        }
        for mouseFirst in [true, false] {
            let (owner, window) = fixture(); defer { owner.shutdown() }
            if mouseFirst { mouse(owner, window, down: true) } else { space(owner, down: true) }
            wait(0.30)
            if mouseFirst { space(owner, down: true) } else { mouse(owner, window, down: true) }
            check(owner.turbo.owners.count == 2 && owner.core?.rates == [2], "second physical owner joins without multiplying speed")
            if mouseFirst { mouse(owner, window, down: false) } else { space(owner, down: false) }
            check(owner.core?.playbackRate == 2, "first release preserves independently held input")
            if mouseFirst { space(owner, down: false) } else { mouse(owner, window, down: false) }
            check(owner.core?.rates == [2, 1.25] && owner.core?.toggles == 0, "last owner restores original pre-boost rate once")
        }
        do {
            let (owner, window) = fixture(); defer { owner.shutdown() }
            mouse(owner, window, down: true); space(owner, down: true)
            mouse(owner, window, down: false); space(owner, down: false)
            check(owner.core?.toggles == 0 && owner.core?.rates.isEmpty == true, "overlapping short presses do not become accidental pause taps")
        }
        for active in [false, true] {
            let (owner, window) = fixture(); defer { owner.shutdown() }
            mouse(owner, window, down: true)
            if active { wait(0.30) }
            SPHoldFixtureInput.pointer.x += 5; owner.drag()
            SPHoldFixtureInput.pointer.x -= 5
            mouse(owner, window, down: false); wait(0.30)
            check(owner.core?.playbackRate == 1.25 && owner.core?.toggles == 0, "sticky movement cancellation restores and suppresses late tap")
            check(owner.turboHUD?.visible == false, "drag cancellation removes charging/active HUD")
        }
        do {
            let (owner, window) = fixture(); defer { owner.shutdown() }
            mouse(owner, window, down: true)
            SPHoldFixtureInput.pointer.x += 5 // No mouseDragged delivery.
            wait(0.30)
            check(owner.core?.rates.isEmpty == true, "pointer polling rejects movement swallowed by native tracking")
            mouse(owner, window, down: false)
            check(owner.core?.toggles == 0, "polled drag does not turn into a click")
        }
        do {
            let (owner, window) = fixture(); defer { owner.shutdown() }
            mouse(owner, window, down: true); wait(0.30)
            SPHoldFixtureInput.buttons = 0; wait(0.08)
            check(owner.core?.rates == [2, 1.25] && owner.turboHUD?.visible == false, "lost outside-app release is recovered without a global monitor")
            mouse(owner, window, down: false)
            check(owner.core?.toggles == 0, "late release after watchdog cleanup never pauses")
        }
        do {
            let (owner, window) = fixture(); defer { owner.shutdown() }
            mouse(owner, window, down: true); wait(0.30)
            window.fixtureKey = false; owner.poll()
            check(owner.core?.playbackRate == 1.25 && owner.turboHUD?.visible == false, "key-window loss restores mouse hold immediately")
            mouse(owner, window, down: false)
            check(owner.core?.toggles == 0, "focus-loss release is discarded")
        }
        do {
            let (owner, window) = fixture(); defer { owner.shutdown() }
            mouse(owner, window, down: true); wait(0.30)
            owner.lifecycleEnd()
            check(owner.core?.playbackRate == 1.25 && owner.turbo.owners.isEmpty, "settings/session cleanup restores speed and all ownership")
            mouse(owner, window, down: false)
            check(owner.core?.toggles == 0, "session cleanup suppresses trailing mouse tap")
        }
        do {
            let (owner, window) = fixture(); defer { owner.shutdown() }
            mouse(owner, window, down: true); wait(0.30)
            let original = window.frame.origin
            window.setFrameOrigin(CGPoint(x: original.x + 1, y: original.y)); owner.poll()
            window.setFrameOrigin(original)
            mouse(owner, window, down: false)
            check(owner.core?.rates == [2, 1.25] && owner.core?.toggles == 0,
                  "window movement cancels even after returning to its original origin")
        }
        do {
            let (owner, window) = fixture(); defer { owner.shutdown() }
            mouse(owner, window, down: true)
            SPHoldFixtureInput.pointer.x += 4
            wait(0.30)
            check(owner.core?.playbackRate == 2, "four-pixel jitter remains inside hold tolerance")
            let elsewhere = SPHoldWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            mouse(owner, elsewhere, down: false)
            check(owner.core?.rates == [2, 1.25] && owner.core?.toggles == 0,
                  "release in another window restores without turning into a tap")
        }
        for closeSource in [false, true] {
            let (owner, window) = fixture(); defer { owner.shutdown() }
            mouse(owner, window, down: true); wait(0.30)
            if closeSource { owner.hasMediaSession = false } else { owner.isSettingsPanelShown = true }
            owner.poll(); mouse(owner, window, down: false)
            check(owner.core?.rates == [2, 1.25] && owner.core?.toggles == 0,
                  "mid-hold panel/source invalidation restores and consumes release")
        }
        do {
            let (owner, window) = fixture(); defer { owner.shutdown() }
            let panel = SPHoldPanel(contentRect: NSRect(x: 10, y: 10, width: 480, height: 270),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.fixtureKey = false
            panel.contentView = owner.playerView
            mouse(owner, panel, down: true); wait(0.30)
            check(owner.core?.playbackRate == 2, "PiP hold uses the actual keyable panel rather than the main window")
            mouse(owner, panel, down: false)
            check(owner.core?.rates == [2, 1.25], "PiP-panel release restores original speed")
        }
        do {
            let (owner, window) = fixture(); defer { owner.shutdown() }
            owner.core?.state = .paused
            mouse(owner, window, down: true); wait(0.30)
            check(owner.core?.state == .paused && owner.core?.rates.isEmpty == true, "holding paused video never auto-starts or boosts")
            mouse(owner, window, down: false)
            check(owner.core?.state == .playing && owner.core?.toggles == 1, "paused hold release retains existing Space resume behavior")
        }
        for blocked in ["settings", "playlist", "double", "noMedia", "disabled"] {
            let (owner, window) = fixture(); defer { owner.shutdown() }
            owner.isSettingsPanelShown = blocked == "settings"
            owner.isPlaylistShown = blocked == "playlist"
            owner.hasMediaSession = blocked != "noMedia"
            SPHoldFixtureInput.enabled = blocked != "disabled"
            mouse(owner, window, down: true, count: blocked == "double" ? 2 : 1)
            wait(0.30)
            check(owner.core?.rates.isEmpty == true, "ineligible/disabled surface does not accelerate: \(blocked)")
            mouse(owner, window, down: false)
            check(owner.core?.toggles == (blocked == "disabled" ? 1 : 0), "ordinary/ineligible release behavior: \(blocked)")
        }
        print("Video hold controller routing checks passed (\(checks) assertions).")
    }
}

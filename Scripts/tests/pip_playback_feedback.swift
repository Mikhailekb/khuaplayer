import AppKit
import QuartzCore

@MainActor private final class PiPFeedbackOwner {
    let mainWindow: NSWindow
    let view: NSView
    let playerView: NSView
    let floatingVideo = SPFloatingVideoController()
    var playbackFeedback: SPPlaybackFeedbackView?
    var seekFeedback: SPPlaybackFeedbackView?
    var volumeFeedback: SPPlaybackFeedbackView?
    var playbackNotice: NSView?
    var volumeFeedbackBounds: CGRect { playerView.frame }
    var playing = false
    var toggles = 0

    init() {
        mainWindow = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 640, height: 360),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        mainWindow.isReleasedWhenClosed = false
        view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        playerView = NSView(frame: view.bounds)
        playerView.wantsLayer = true
        playerView.layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.2, blue: 0.24, alpha: 1).cgColor
        mainWindow.contentView = view
        view.addSubview(playerView)
        floatingVideo.onLayoutChange = { [weak self] in self?.relocateVideoOverlays() }
        floatingVideo.onTogglePlayback = { [weak self] in
            guard let self else { return }
            playing.toggle(); toggles += 1
            floatingVideo.update(isPlaying: playing)
            showPlaybackFeedback(isPlaying: playing)
        }
    }
    func layoutPlaybackNotice() {}
    func show(_ playing: Bool) { showPlaybackFeedback(isPlaying: playing) }
    func relocate() { relocateVideoOverlays() }
    func enter() -> Bool {
        // The exact production entry method is source-checked to dismiss the
        // existing feedback before presenting the shared video view.
        playbackFeedback?.dismiss()
        return floatingVideo.present(videoView: playerView, aspectRatio: 16 / 9,
                                     sourceWindow: mainWindow, showWindow: false)
    }
    func close() { floatingVideo.restore(); playbackFeedback?.dismiss(); mainWindow.close() }
    // INSERT_PRODUCTION_METHODS
}

@main @MainActor private enum PiPPlaybackFeedbackChecks {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { print("FAIL: \(message)"); exit(1) }
    }
    static func wait(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func feedbackAnimations(_ feedback: SPPlaybackFeedbackView) -> [String] {
        let bezel = feedback.layer!.sublayers!.first { $0.name == "sp.playback.feedback.bezel" }!
        return (bezel.animationKeys() ?? []) + (bezel.sublayers?.first?.animationKeys() ?? [])
    }
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        setbuf(stdout, nil)
        let owner = PiPFeedbackOwner()
        defer { owner.close() }
        check(owner.enter(), "owned video can enter PiP")
        owner.show(true); owner.show(false)
        check(owner.playbackFeedback == nil, "PiP playback does not allocate a main-player feedback overlay")
        let panel = owner.floatingVideo.window!
        let content = panel.contentView!
        let controls = descendants(content).first { $0.accessibilityIdentifier() == "sp.floatingVideo.controls" }!
        let play = descendants(content).first { $0.accessibilityIdentifier() == "sp.floatingVideo.playPause" }! as! NSButton
        check(controls.alphaValue == 0, "PiP controls remain hidden before hover")
        let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        content.mouseEntered(with: event); wait(0.2)
        play.performClick(nil)
        check(owner.toggles == 1 && owner.playing, "PiP keeps its own working play/pause button")
        check(owner.playbackFeedback == nil && controls.alphaValue == 1,
              "PiP button updates do not produce a second transient icon")
        check(!owner.mainWindow.isVisible && !panel.isVisible, "tests never order windows onto the user screen")
        owner.floatingVideo.restore()
        owner.show(false)
        let feedback = owner.playbackFeedback!
        check(!feedback.isHidden && feedback.superview === owner.view,
              "leaving PiP restores ordinary main-player feedback")
        check(!feedbackAnimations(feedback).isEmpty, "main feedback still animates normally")
        check(owner.enter(), "PiP can enter while main feedback animation is active")
        check(feedback.isHidden && feedback.displayedPlaying == nil && feedbackAnimations(feedback).isEmpty,
              "entering PiP dismisses main feedback and cancels animation and pending cleanup")
        check(feedback.superview === owner.view, "main feedback is not relocated into PiP")
        owner.show(true); owner.show(false)
        check(feedback.isHidden && feedbackAnimations(feedback).isEmpty,
              "repeated PiP playback changes cannot reactivate an existing main feedback view")
        // Defensive layout path: a stale view must be dismissed, never moved to
        // the PiP hierarchy when its viewport changes.
        feedback.show(isPlaying: true)
        owner.relocate()
        check(feedback.isHidden && feedback.superview === owner.view,
              "PiP layout dismisses stale feedback without adding it above PiP controls")
        wait(0.8)
        check(feedback.isHidden && feedback.displayedPlaying == nil,
              "old cleanup cannot resurrect feedback while PiP is active")
        owner.floatingVideo.restore()
        owner.show(true)
        check(!feedback.isHidden && feedback.displayedPlaying == true && feedback.superview === owner.view,
              "after restore the same feedback view works again in the main player")
        print("PiP playback feedback checks passed (\(checks) assertions; owned hidden windows and production controller methods).")
    }
}

import AppKit
import QuartzCore

@main @MainActor
struct PlaybackFeedbackChecks {
    static var checks = 0

    static func check(_ condition: Bool, _ message: String) {
        guard condition else { print("FAIL: \(message)"); exit(1) }
        checks += 1
    }

    static func runLoop(_ seconds: TimeInterval) {
        #if SP_FEEDBACK_REAL_SCHEDULER
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        #else
        SPFeedbackTestClock.advance(by: seconds)
        #endif
    }

    static func bezel(_ view: SPPlaybackFeedbackView) -> CALayer {
        view.layer!.sublayers!.first { $0.name == "sp.playback.feedback.bezel" }!
    }

    static func glyph(_ view: SPPlaybackFeedbackView) -> CAShapeLayer {
        bezel(view).sublayers!.first { $0.name == "sp.playback.feedback.glyph" }! as! CAShapeLayer
    }

    static func isLinear(_ animation: CAAnimation) -> Bool {
        guard let timing = animation.timingFunction else { return false }
        var point: [Float] = [0, 0]
        for index in [1, 2] {
            timing.getControlPoint(at: index, values: &point)
            if abs(point[0] - point[1]) > 0.001 { return false }
        }
        return true
    }

    static func render(_ view: SPPlaybackFeedbackView, to path: String) {
        // Render only our detached component, never the user's windows/screen.
        let size = CGSize(width: 320, height: 240)
        let context = CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: 2, y: 2)
        context.setFillColor(NSColor(calibratedRed: 0.22, green: 0.32, blue: 0.38, alpha: 1).cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        context.translateBy(x: view.frame.minX, y: view.frame.minY)
        view.layer!.render(in: context)
        let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }

    static func renderSample(_ view: SPPlaybackFeedbackView, fraction: Double, to path: String) {
        // Sample the detached component's linear animation values; no display,
        // player window or screen capture is involved.
        let disk = bezel(view)
        let icon = glyph(view)
        let fade = disk.animation(forKey: "playbackFade") as! CAKeyframeAnimation
        let grow = icon.animation(forKey: "playbackGlyphGrow") as! CABasicAnimation
        let from = (grow.fromValue as! NSNumber).doubleValue
        let to = (grow.toValue as! NSNumber).doubleValue
        let scale = from + (to - from) * fraction
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let holdFraction = fade.keyTimes![1].doubleValue
        disk.opacity = Float(fraction <= holdFraction ? 1 : (1 - fraction) / (1 - holdFraction))
        icon.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
        check(CATransform3DIsIdentity(disk.transform), "The sampled backdrop never expands")
        check(icon.position == CGPoint(x: disk.bounds.midX, y: disk.bounds.midY),
              "The sampled glyph stays centered during interpolation")
        check(fade.values?.first as? Int == 1 && fade.values?.last as? Int == 0,
              "The sampled opacity holds before fading to transparency")
        render(view, to: path)
        disk.opacity = 1
        icon.transform = CATransform3DIdentity
    }

    static func main() {
        #if SP_FEEDBACK_REAL_SCHEDULER
        realSchedulerChecks()
        #else
        let view = SPPlaybackFeedbackView(frame: .zero, reducedMotion: { false })
        check(view.isHidden, "Feedback starts hidden")
        view.place(in: CGRect(x: 10, y: 20, width: 640, height: 360))
        check(view.frame.midX == 330 && view.frame.midY == 200, "Offset video coordinates determine the center")
        check(view.hitTest(view.bounds.center) == nil, "Feedback never intercepts video clicks")

        view.show(isPlaying: true)
        check(!view.isHidden && view.displayedPlaying == true, "Resume shows the play glyph")
        let play = glyph(view).path!
        check(play.contains(CGPoint(x: 39, y: 48)), "Play triangle has a solid left interior")
        check(!play.contains(CGPoint(x: 66, y: 67.5)), "Play triangle leaves its upper-right exterior clear")
        check(bezel(view).cornerRadius * 2 == bezel(view).bounds.width, "Backdrop remains circular")
        check(abs(bezel(view).backgroundColor!.alpha - 0.55) < 0.001, "Backdrop remains translucent")
        check(bezel(view).animationKeys() == ["playbackFade"], "The circular backdrop never grows or pulses")
        check(bezel(view).animation(forKey: "playbackFade")?.duration == 0.75, "Feedback remains readable for three quarters of a second")
        check(bezel(view).bounds.width == 96, "The fixed backdrop is larger")
        check(glyph(view).path!.boundingBoxOfPath.height >= 48, "The play symbol is at least fifty percent larger")
        let fade = bezel(view).animation(forKey: "playbackFade") as! CAKeyframeAnimation
        check(fade.values?.last as? Int == 0 && fade.fillMode == .forwards && !fade.isRemovedOnCompletion,
              "The terminal transparent frame persists even when cleanup is delayed")
        check(fade.values?.prefix(2).allSatisfy { ($0 as? Int) == 1 } == true &&
              abs(fade.keyTimes![1].doubleValue * fade.duration - 0.3) < 0.001,
              "The icon holds full opacity before its smooth fade")
        let grow = glyph(view).animation(forKey: "playbackGlyphGrow") as! CABasicAnimation
        check(grow.fromValue as? Double == 1 && grow.toValue as? Double == 1.12 && isLinear(grow),
              "Only the white glyph has a subtle linear growth")
        check(glyph(view).anchorPoint == CGPoint(x: 0.5, y: 0.5) &&
              glyph(view).position == CGPoint(x: bezel(view).bounds.midX, y: bezel(view).bounds.midY),
              "Glyph interpolation stays anchored at the backdrop center")

        runLoop(0.3)
        view.show(isPlaying: false)
        let pause = glyph(view).path!
        check(pause.contains(CGPoint(x: 36, y: 48)) && pause.contains(CGPoint(x: 60, y: 48)), "Pause has two solid bars")
        check(!pause.contains(CGPoint(x: 48, y: 48)), "Pause keeps the gap between bars")
        // Cross the old play cleanup at 0.75 while the replacement pause is
        // still valid until 1.05. Cancelled callbacks deliberately execute.
        runLoop(0.5)
        check(!view.isHidden && view.displayedPlaying == false, "An obsolete hide cannot erase the latest click")
        check(SPFeedbackTestClock.cancelledCallbacksExecuted == 1,
              "The obsolete callback actually ran after cancellation")
        view.place(in: CGRect(x: 2, y: 4, width: 320, height: 180))
        check(view.frame.midX == 162 && view.frame.midY == 94, "A resize keeps feedback centered")
        runLoop(0.26)
        check(view.isHidden && view.displayedPlaying == nil, "The latest animation hides after completion")
        check(bezel(view).animationKeys()?.isEmpty ?? true, "Finished feedback leaves no animations running")
        check(glyph(view).animationKeys()?.isEmpty ?? true, "Finished feedback clears its glyph animation")

        view.show(isPlaying: true)
        view.dismiss()
        runLoop(0.1)
        view.show(isPlaying: false)
        runLoop(0.66)
        check(!view.isHidden && view.displayedPlaying == false,
              "A dismissed session cannot hide the next session's feedback")
        check(SPFeedbackTestClock.cancelledCallbacksExecuted == 2,
              "The dismissed session's cancelled cleanup actually ran")
        runLoop(0.1)
        check(view.isHidden && view.displayedPlaying == nil,
              "The next session still performs its own eventual cleanup")
        view.show(isPlaying: false)
        view.dismiss()
        check(view.isHidden && view.displayedPlaying == nil, "Dismiss clears presentation state")
        check(bezel(view).animationKeys()?.isEmpty ?? true, "Dismiss removes animations")
        check(glyph(view).animationKeys()?.isEmpty ?? true, "Dismiss clears glyph motion")

        let reduced = SPPlaybackFeedbackView(frame: .zero, reducedMotion: { true })
        reduced.place(in: CGRect(x: 0, y: 0, width: 320, height: 240))
        reduced.show(isPlaying: true)
        check(bezel(reduced).animationKeys() == ["playbackFade"] && (glyph(reduced).animationKeys()?.isEmpty ?? true),
              "Reduced Motion never scales the backdrop or icon")
        check(abs((bezel(reduced).animation(forKey: "playbackFade")?.duration ?? 0) - 0.65) < 0.001, "Reduced Motion retains the readable hold without scaling")
        runLoop(0.7)
        check(reduced.isHidden, "Reduced Motion also completes without a timer loop")

        if CommandLine.arguments.count == 2 {
            let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            view.place(in: CGRect(x: 0, y: 0, width: 320, height: 240))
            view.show(isPlaying: true)
            render(view, to: output.appendingPathComponent("playback-resume.png").path)
            view.show(isPlaying: false)
            render(view, to: output.appendingPathComponent("playback-pause.png").path)
            renderSample(view, fraction: 0.5,
                         to: output.appendingPathComponent("playback-pause-mid.png").path)
            renderSample(view, fraction: 0.8,
                         to: output.appendingPathComponent("playback-pause-late.png").path)
            view.dismiss()
            print("Rendered detached component states: \(output.path)")
        }
        print("Playback feedback checks passed (\(checks) assertions).")
        #endif
    }

    #if SP_FEEDBACK_REAL_SCHEDULER
    static func realSchedulerChecks() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        // This build compiles the unmodified production view, using its real
        // DispatchWorkItem/main queue. Only eventual completion is wall-clock
        // based; visibility near an expiry deadline belongs to the fake clock.
        for reducedMotion in [false, true] {
            let view = SPPlaybackFeedbackView(frame: .zero, reducedMotion: { reducedMotion })
            view.place(in: CGRect(x: 0, y: 0, width: 320, height: 240))
            view.show(isPlaying: true)
            check(!view.isHidden && view.displayedPlaying == true,
                  "Real scheduling immediately presents feedback")
            let deadline = ProcessInfo.processInfo.systemUptime + 2.5
            while !view.isHidden && ProcessInfo.processInfo.systemUptime < deadline {
                runLoop(0.02)
            }
            check(view.isHidden && view.displayedPlaying == nil,
                  "Real main-queue scheduling eventually completes feedback; reducedMotion=\(reducedMotion)")
            check((bezel(view).animationKeys()?.isEmpty ?? true) &&
                  (glyph(view).animationKeys()?.isEmpty ?? true),
                  "Real completion removes both animations")
            view.dismiss()
        }
        print("Unmodified playback feedback real-scheduler checks passed (\(checks) assertions).")
    }
    #endif
}

#if !SP_FEEDBACK_REAL_SCHEDULER
// Substitute only the asynchronous scheduling boundary. A cancelled item still
// runs its exact production closure, modeling an already-dispatched callback
// and requiring the production generation guard to protect newer feedback.
@MainActor
final class SPFeedbackTestWorkItem {
    private let body: () -> Void
    private(set) var isCancelled = false
    init(block: @escaping () -> Void) { body = block }
    func cancel() { isCancelled = true }
    func performEvenIfCancelled() { body() }
}

@MainActor
enum SPFeedbackTestClock {
    private struct Pending {
        let deadline: TimeInterval
        let item: SPFeedbackTestWorkItem
    }
    private static var now: TimeInterval = 0
    private static var pending: [Pending] = []
    private(set) static var cancelledCallbacksExecuted = 0

    static func schedule(after delay: TimeInterval, execute item: SPFeedbackTestWorkItem) {
        precondition(delay.isFinite && delay >= 0)
        pending.append(Pending(deadline: now + delay, item: item))
        pending.sort { $0.deadline < $1.deadline }
    }

    static func advance(by interval: TimeInterval) {
        precondition(interval.isFinite && interval >= 0)
        let target = now + interval
        while let next = pending.first, next.deadline <= target {
            pending.removeFirst()
            now = next.deadline
            if next.item.isCancelled { cancelledCallbacksExecuted += 1 }
            next.item.performEvenIfCancelled()
        }
        now = target
    }
}
#endif

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

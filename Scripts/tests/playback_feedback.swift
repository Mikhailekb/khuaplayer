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
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func bezel(_ view: SPPlaybackFeedbackView) -> CALayer {
        view.layer!.sublayers!.first { $0.name == "sp.playback.feedback.bezel" }!
    }

    static func glyph(_ view: SPPlaybackFeedbackView) -> CAShapeLayer {
        bezel(view).sublayers!.first { $0.name == "sp.playback.feedback.glyph" }! as! CAShapeLayer
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

    static func main() {
        let view = SPPlaybackFeedbackView(frame: .zero, reducedMotion: { false })
        check(view.isHidden, "Feedback starts hidden")
        view.place(in: CGRect(x: 10, y: 20, width: 640, height: 360))
        check(view.frame.midX == 330 && view.frame.midY == 200, "Offset video coordinates determine the center")
        check(view.hitTest(view.bounds.center) == nil, "Feedback never intercepts video clicks")

        view.show(isPlaying: true)
        check(!view.isHidden && view.displayedPlaying == true, "Resume shows the play glyph")
        let play = glyph(view).path!
        check(play.contains(CGPoint(x: 30, y: 36)), "Play triangle has a solid left interior")
        check(!play.contains(CGPoint(x: 48, y: 49)), "Play triangle leaves its upper-right exterior clear")
        check(bezel(view).cornerRadius * 2 == bezel(view).bounds.width, "Backdrop remains circular")
        check(abs(bezel(view).backgroundColor!.alpha - 0.55) < 0.001, "Backdrop remains translucent")
        check(bezel(view).animation(forKey: "playbackGrow") != nil, "Normal motion grows the bezel")
        check(bezel(view).animation(forKey: "playbackFade")?.duration == 0.5, "Feedback has one short fade")
        let fade = bezel(view).animation(forKey: "playbackFade") as! CAKeyframeAnimation
        check(fade.values?.last as? Int == 0 && fade.fillMode == .forwards && !fade.isRemovedOnCompletion,
              "The terminal transparent frame persists even when cleanup is delayed")

        runLoop(0.3)
        view.show(isPlaying: false)
        let pause = glyph(view).path!
        check(pause.contains(CGPoint(x: 28, y: 36)) && pause.contains(CGPoint(x: 44, y: 36)), "Pause has two solid bars")
        check(!pause.contains(CGPoint(x: 36, y: 36)), "Pause keeps the gap between bars")
        runLoop(0.25)
        check(!view.isHidden && view.displayedPlaying == false, "An obsolete hide cannot erase the latest click")
        view.place(in: CGRect(x: 2, y: 4, width: 320, height: 180))
        check(view.frame.midX == 162 && view.frame.midY == 94, "A resize keeps feedback centered")
        runLoop(0.3)
        check(view.isHidden && view.displayedPlaying == nil, "The latest animation hides after completion")
        check(bezel(view).animationKeys()?.isEmpty ?? true, "Finished feedback leaves no animations running")

        view.show(isPlaying: true)
        view.dismiss()
        runLoop(0.1)
        view.show(isPlaying: false)
        runLoop(0.42)
        check(!view.isHidden, "A dismissed session cannot hide the next session's feedback")
        view.dismiss()
        check(view.isHidden && view.displayedPlaying == nil, "Dismiss clears presentation state")
        check(bezel(view).animationKeys()?.isEmpty ?? true, "Dismiss removes animations")

        let reduced = SPPlaybackFeedbackView(frame: .zero, reducedMotion: { true })
        reduced.place(in: CGRect(x: 0, y: 0, width: 320, height: 240))
        reduced.show(isPlaying: true)
        check(bezel(reduced).animation(forKey: "playbackGrow") == nil, "Reduced Motion never scales the icon")
        check(bezel(reduced).animation(forKey: "playbackFade")?.duration == 0.25, "Reduced Motion uses a short fade")
        runLoop(0.3)
        check(reduced.isHidden, "Reduced Motion also completes without a timer loop")

        if CommandLine.arguments.count == 2 {
            let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            view.place(in: CGRect(x: 0, y: 0, width: 320, height: 240))
            view.show(isPlaying: true)
            render(view, to: output.appendingPathComponent("playback-resume.png").path)
            view.show(isPlaying: false)
            render(view, to: output.appendingPathComponent("playback-pause.png").path)
            view.dismiss()
            print("Rendered detached component states: \(output.path)")
        }
        print("Playback feedback checks passed (\(checks) assertions).")
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

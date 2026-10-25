import AppKit
import QuartzCore

// INSERT_PRODUCTION_TOKENS
// INSERT_PRODUCTION_NORMALIZATION

struct SPDamageBand: Equatable {
    static let partial: Int32 = 1, none: Int32 = 2, pending: Int32 = 3
    let cls: Int32
    let from: Double
    let until: Double
}
enum SPDamage {
    static let partialColor = NSColor.orange
    static let noneColor = NSColor.red
    static let pendingColor = NSColor.black
}
struct SPThumbDustSnapshot {}
enum SPTimelineStyleSettings {
    enum Style { case classic, tide, dust }
    static let style = Style.classic
}
// Peripheral Dust dependency is deterministic. The real progress view still
// exercises its dynamic layer insertion, style changes and interaction paths.
final class SPDustHost {
    static let enabled = false
    let layer = CALayer()
    func attach(to view: NSView) { layer.name = "test.dust" }
    func detach() {}
    func setGeometry(bounds: CGRect, scale: CGFloat) { layer.frame = bounds }
    func setSnapshot(_ snapshot: SPThumbDustSnapshot?, duration: Double) {}
    func setDamage(bands: [SPDamageBand], duration: Double) {}
    func setSplit(_ split: CGFloat) {}
    func setVisible(_ visible: Bool) {}
    func pointerEntered(x: CGFloat) {}
    func pointerMoved(x: CGFloat) {}
    func pointerExited() {}
    func pressed(x: CGFloat) {}
    func released(hovering: Bool) {}
}

// INSERT_PRODUCTION_PROGRESS

@main @MainActor
struct BufferedTimelineChecks {
    static var checks = 0
    static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        checks += 1
        print("PASS \(checks): \(message)")
    }
    static func shape(_ view: NSView, _ suffix: String) -> CAShapeLayer {
        view.layer!.sublayers!.first { $0.name == "sp.timeline.buffered." + suffix }! as! CAShapeLayer
    }
    static func pixels(_ view: NSView, scale: Int = 2) -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        CATransaction.flush()
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width) * scale,
            pixelsHigh: Int(view.bounds.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = CGContext(data: image.bitmapData, width: image.pixelsWide, height: image.pixelsHigh,
            bitsPerComponent: 8, bytesPerRow: image.bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: image.pixelsWide, height: image.pixelsHigh))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        view.layer!.render(in: context)
        return image
    }
    static func white(_ image: NSBitmapImageRep, x: Double) -> Double {
        image.colorAt(x: Int(x * Double(image.pixelsWide)), y: image.pixelsHigh / 2)!
            .usingColorSpace(.deviceRGB)!.redComponent
    }
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        setbuf(stdout, nil)
        expect(SPBufferedTimeline.normalized([-0.5...0.2, 0.1...0.3, 0.3...0.4, 0.6...0.7, 0.9...1.4]) ==
            [0...0.4, 0.6...0.7, 0.9...1], "Normalized ranges clip, sort and merge only overlapping or touching intervals")
        expect(SPBufferedTimeline.normalized([(-Double.infinity)...0.5, 0.5...Double.infinity,
                                               0.3...0.3, 1.1...1.2]).isEmpty,
               "Nonfinite, empty and entirely out-of-duration coverage is discarded")
        expect(SPBufferedTimeline.normalized([0.1...0.2, 0.20001...0.3]).count == 2,
               "A real gap is never bridged by a rounding tolerance")
        let view = SPProgressView(frame: NSRect(x: 0, y: 0, width: 400, height: 44))
        view.setBufferedRanges([0.1...0.3, 0.5...0.6, 0.8...0.9], visible: true)
        view.setValue(0.2)
        let initial = pixels(view)
        expect(white(initial, x: 0.1) > 0.95, "Played media remains white above cached coverage")
        expect(white(initial, x: 0.25) > 0.6 && white(initial, x: 0.25) < 0.7,
               "Resident forward media is neutral light gray")
        expect(white(initial, x: 0.4) < 0.25 && white(initial, x: 0.7) < 0.25,
               "Uncached gaps stay visibly dark")
        expect(white(initial, x: 0.55) > 0.6 && white(initial, x: 0.85) > 0.6,
               "Discontinuous cached segments are drawn at their supplied media times")
        view.setBufferedRanges([0.1...0.3, 0.8...0.9], visible: true)
        expect(white(pixels(view), x: 0.55) < 0.25, "Evicted cache immediately removes its previous gray segment")
        view.setBufferedRanges([], visible: true)
        expect(white(pixels(view), x: 0.8) < 0.25 && !shape(view, "base").isHidden,
               "A visible empty torrent cache keeps an honest unloaded rail")
        view.setBufferedRanges([0.5...0.6], visible: false)
        expect(shape(view, "base").isHidden && shape(view, "ranges").isHidden,
               "Leaving cache mode hides all cache layers and clears stale coverage")
        view.setBufferedRanges([0.5...0.6], visible: true)
        view.setFrameSize(NSSize(width: 600, height: 44))
        view.layoutSubtreeIfNeeded()
        expect(shape(view, "ranges").mask!.frame.width == 600,
               "Resize remaps normalized coverage to the new timeline width")
        let mask = shape(view, "ranges").mask as! CAShapeLayer
        expect(mask.path!.contains(CGPoint(x: 330, y: 22)) &&
               !mask.path!.contains(CGPoint(x: 410, y: 22)),
               "Resized masks retain segment bounds and gaps")
        view.pointerEntered(atX: 330)
        expect(abs(shape(view, "base").path!.boundingBox.height - 7) < 0.01,
               "Hover expands the same cache rail from four to seven points")
        var began: [Double] = [], scrubbed: [Double] = [], ended: [(Double, Bool)] = []
        view.onBegan = { began.append($0) }
        view.onScrub = { scrubbed.append($0) }
        view.onEnded = { ended.append(($0, $1)) }
        view.pointerPressed(atX: 300)
        view.pointerDragged(toX: 480)
        view.pointerReleased(atX: 480)
        expect(began == [0.5] && scrubbed == [0.8] && ended.count == 1 && ended[0].0 == 0.8 && ended[0].1,
               "Cached segments never change seek, drag or commit behavior")
        view.pointerExited()
        expect(abs(shape(view, "base").path!.boundingBox.height - 4) < 0.01,
               "Leaving the timeline restores the resting rail height")
        view.setDustEnabled(true)
        let dust = view.layer!.sublayers!.first { $0.name == "test.dust" }!
        expect(shape(view, "base").zPosition > dust.zPosition && !shape(view, "base").isHidden,
               "Dynamically inserted Dust cannot obscure the cached rail")
        view.setDamage(bands: [.init(cls: SPDamageBand.partial, from: 2, until: 3)], duration: 10)
        let overlays = view.layer!.sublayers!.compactMap { $0 as? CAShapeLayer }
        expect(overlays.contains { $0.zPosition == 15 && !$0.isHidden && $0.path != nil },
               "Damage indicators remain above the cache rail even with Dust enabled")
        view.setBufferedRanges([], visible: false)
        expect(shape(view, "base").isHidden, "Disabling cache mode restores the original particle presentation")
        view.setDustEnabled(false)
        view.setDamage(bands: [], duration: 0)
        view.setValue(0.2)
        view.setBufferedRanges([0.1...0.3, 0.5...0.6, 0.8...0.9], visible: true)
        view.setFrameSize(NSSize(width: 900, height: 64))
        view.layoutSubtreeIfNeeded()
        if CommandLine.arguments.count == 2 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try pixels(view).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("cached-timeline.png"))
        }
        expect(view.window == nil, "Tests render detached layers without opening or inspecting a user window")
        print("Buffered timeline checks passed (\(checks) assertions; deterministic peripheral Dust stub, actual AppKit progress paths).")
    }
}

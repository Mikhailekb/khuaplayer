import AppKit
import QuartzCore

/// A short, noninteractive play/pause indication over the video surface.
final class SPPlaybackFeedbackView: NSView {
    private enum G {
        static let canvas: CGFloat = 160
        static let diameter: CGFloat = 72
        static let duration: TimeInterval = 0.35
        static let reducedDuration: TimeInterval = 0.25
    }

    private let bezel = CALayer()
    private let glyph = CAShapeLayer()
    private var hideWork: DispatchWorkItem?
    private var generation: UInt = 0
    private var reducedMotion: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    private(set) var displayedPlaying: Bool?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let actions: [String: CAAction] = [
            "opacity": NSNull(), "position": NSNull(), "bounds": NSNull(),
            "transform": NSNull(), "path": NSNull(), "cornerRadius": NSNull(),
        ]
        layer?.actions = actions
        bezel.actions = actions
        glyph.actions = actions
        bezel.name = "sp.playback.feedback.bezel"
        bezel.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        glyph.name = "sp.playback.feedback.glyph"
        glyph.fillColor = NSColor.white.cgColor
        layer?.addSublayer(bezel)
        bezel.addSublayer(glyph)
        isHidden = true
        setAccessibilityIdentifier("sp.playbackFeedback")
        // Playback controls already expose the state; this is a decorative echo.
        setAccessibilityElement(false)
    }

    convenience init(frame: NSRect, reducedMotion: @escaping () -> Bool) {
        self.init(frame: frame)
        self.reducedMotion = reducedMotion
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for item in [layer, bezel, glyph] { item?.contentsScale = scale }
    }

    func place(in bounds: CGRect) {
        let side = min(G.canvas, max(0, min(bounds.width, bounds.height) - 16))
        frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                       width: side, height: side)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        // The backdrop stays fixed; only the white glyph has a subtle motion.
        let diameter = min(G.diameter, min(bounds.width, bounds.height) * 0.45)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bezel.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        bezel.position = CGPoint(x: bounds.midX, y: bounds.midY)
        bezel.cornerRadius = diameter / 2
        glyph.bounds = bezel.bounds
        glyph.position = CGPoint(x: diameter / 2, y: diameter / 2)
        glyph.path = makeGlyph(isPlaying: displayedPlaying ?? true, diameter: diameter)
        CATransaction.commit()
    }

    func show(isPlaying: Bool) {
        cancelPendingHide()
        let currentGeneration = generation
        displayedPlaying = isPlaying
        isHidden = false
        bezel.removeAllAnimations()
        glyph.removeAllAnimations()
        bezel.opacity = 1
        bezel.transform = CATransform3DIdentity
        glyph.transform = CATransform3DIdentity
        needsLayout = true
        layoutSubtreeIfNeeded()

        let reduce = reducedMotion()
        let duration = reduce ? G.reducedDuration : G.duration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .linear)
        // Stay transparent if the main queue is busy when cleanup is due.
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        bezel.add(fade, forKey: "playbackFade")
        if !reduce {
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 1
            grow.toValue = 1.12
            grow.duration = duration
            grow.fillMode = .forwards
            grow.isRemovedOnCompletion = false
            grow.timingFunction = CAMediaTimingFunction(name: .linear)
            glyph.add(grow, forKey: "playbackGlyphGrow")
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.hideWork = nil
            self.bezel.removeAllAnimations()
            self.glyph.removeAllAnimations()
            self.displayedPlaying = nil
            self.isHidden = true
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func dismiss() {
        cancelPendingHide()
        bezel.removeAllAnimations()
        glyph.removeAllAnimations()
        bezel.opacity = 1
        bezel.transform = CATransform3DIdentity
        glyph.transform = CATransform3DIdentity
        displayedPlaying = nil
        isHidden = true
    }

    private func cancelPendingHide() {
        generation &+= 1
        hideWork?.cancel()
        hideWork = nil
    }

    private func makeGlyph(isPlaying: Bool, diameter: CGFloat) -> CGPath {
        let path = CGMutablePath()
        if isPlaying {
            path.move(to: CGPoint(x: 29, y: 20))
            path.addLine(to: CGPoint(x: 49, y: 33.5))
            path.addQuadCurve(to: CGPoint(x: 49, y: 38.5), control: CGPoint(x: 52.5, y: 36))
            path.addLine(to: CGPoint(x: 29, y: 52))
            path.addQuadCurve(to: CGPoint(x: 25.5, y: 50), control: CGPoint(x: 25.5, y: 54))
            path.addLine(to: CGPoint(x: 25.5, y: 22))
            path.addQuadCurve(to: CGPoint(x: 29, y: 20), control: CGPoint(x: 25.5, y: 18))
            path.closeSubpath()
        } else {
            for x: CGFloat in [24, 40] {
                path.addRoundedRect(in: CGRect(x: x, y: 19, width: 8, height: 34),
                                    cornerWidth: 1.5, cornerHeight: 1.5)
            }
        }
        var transform = CGAffineTransform(scaleX: diameter / G.diameter,
                                         y: diameter / G.diameter)
        return path.copy(using: &transform) ?? path
    }
}

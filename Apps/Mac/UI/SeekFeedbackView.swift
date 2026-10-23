import AppKit
import QuartzCore

/// Consecutive keyboard seeks share one readout until their direction changes.
struct SPSeekFeedback {
    enum Direction: Equatable { case backward, forward }

    static let groupingInterval: TimeInterval = 0.8

    private(set) var direction: Direction?
    private(set) var accumulatedDelta: Double = 0
    private var lastInputTime: TimeInterval?

    @discardableResult
    mutating func record(delta: Double,
                         now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard delta.isFinite, delta != 0, now.isFinite else { return false }
        let nextDirection: Direction = delta < 0 ? .backward : .forward
        let elapsed = lastInputTime.map { now - $0 }
        let continuesGroup = direction == nextDirection &&
            elapsed.map { $0 >= 0 && $0 <= Self.groupingInterval } == true
        let total = continuesGroup ? accumulatedDelta + delta : delta
        accumulatedDelta = total.isFinite ? total : delta
        direction = nextDirection
        lastInputTime = now
        return true
    }

    mutating func reset() {
        direction = nil
        accumulatedDelta = 0
        lastInputTime = nil
    }
}

/// A lightweight, noninteractive indication placed over the video, not its controls.
final class SPSeekFeedbackView: NSView {
    private enum G {
        static let width: CGFloat = 120
        static let height: CGFloat = 48
        static let hold: TimeInterval = 0.6
        static let fade: TimeInterval = 0.15
        static let chevronWidth: CGFloat = 11
        static let chevronHeight: CGFloat = 22
        static let gap: CGFloat = 18
    }

    private let arrow = CAShapeLayer()
    private let text = NSTextField(labelWithString: "")
    private var feedback = SPSeekFeedback()
    private var videoBounds: CGRect = .zero
    private var fadeWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var generation: UInt = 0

    var direction: SPSeekFeedback.Direction? { feedback.direction }
    var accumulatedDelta: Double { feedback.accumulatedDelta }
    var displayedText: String { text.stringValue }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.actions = ["opacity": NSNull(), "position": NSNull(), "bounds": NSNull()]
        arrow.name = "sp.seek.chevron"
        arrow.fillColor = nil
        arrow.strokeColor = NSColor.white.cgColor
        arrow.lineWidth = 2.75
        arrow.lineCap = .round
        arrow.lineJoin = .round
        arrow.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull(),
                         "opacity": NSNull(), "transform": NSNull()]
        layer?.addSublayer(arrow)

        text.font = .monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
        text.textColor = .white
        text.alignment = .right
        text.isSelectable = false
        text.lineBreakMode = .byClipping
        text.wantsLayer = true
        text.layer?.name = "sp.seek.value"
        text.setAccessibilityElement(false)
        addSubview(text)
        isHidden = true
        setAccessibilityIdentifier("sp.keyboardSeekFeedback")
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        arrow.contentsScale = scale
        text.layer?.contentsScale = scale
    }

    func place(in bounds: CGRect) {
        videoBounds = bounds
        guard !bounds.isEmpty else { return }
        let width = min(G.width, max(0, bounds.width - 16))
        let height = min(G.height, max(0, bounds.height - 16))
        let fraction: CGFloat = direction == .backward ? 0.25 : 0.75
        let centerX = min(bounds.maxX - width / 2 - 8,
                          max(bounds.minX + width / 2 + 8, bounds.minX + bounds.width * fraction))
        frame = CGRect(x: centerX - width / 2, y: bounds.midY - height / 2,
                       width: width, height: height).integral
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let textWidth = min(max(0, bounds.width - G.chevronWidth - G.gap),
                            max(72, ceil(text.intrinsicContentSize.width)))
        let contentWidth = textWidth + G.gap + G.chevronWidth
        let start = (bounds.width - contentWidth) / 2
        let backward = direction == .backward
        text.alignment = backward ? .left : .right
        text.frame = CGRect(x: backward ? start + G.chevronWidth + G.gap : start,
                            y: (bounds.height - 32) / 2,
                            width: textWidth, height: 32)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arrow.frame = CGRect(x: backward ? start : start + textWidth + G.gap,
                             y: (bounds.height - G.chevronHeight) / 2,
                             width: G.chevronWidth, height: G.chevronHeight)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: backward ? G.chevronWidth : 0, y: 0))
        path.addLine(to: CGPoint(x: backward ? 0 : G.chevronWidth, y: G.chevronHeight / 2))
        path.addLine(to: CGPoint(x: backward ? G.chevronWidth : 0, y: G.chevronHeight))
        arrow.path = path
        CATransaction.commit()
    }

    func show(delta: Double) {
        let wasHidden = isHidden
        let previousDirection = direction
        guard feedback.record(delta: delta) else { return }
        cancelPendingFade()
        let currentGeneration = generation
        layer?.removeAllAnimations()
        arrow.removeAllAnimations()
        text.layer?.removeAllAnimations()
        alphaValue = 1
        isHidden = false
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 0
        let magnitude = formatter.string(from: NSNumber(value: abs(accumulatedDelta))) ??
            String(format: "%.0f", abs(accumulatedDelta))
        let sign = delta < 0 ? "−" : "+"
        let visualValue = sign + " " + magnitude
        let shouldAnimateNumber = !wasHidden && previousDirection == direction &&
            text.stringValue != visualValue
        text.stringValue = visualValue
        setAccessibilityValue(L("playback.seekFeedback.seconds", sign + magnitude))
        place(in: videoBounds)
        layoutSubtreeIfNeeded()

        if !reduceMotion {
            if wasHidden {
                let entry = CABasicAnimation(keyPath: "opacity")
                entry.fromValue = 0
                entry.toValue = 1
                entry.duration = 0.1
                layer?.add(entry, forKey: "seekEntry")
            }
            if shouldAnimateNumber {
                let change = CATransition()
                change.type = .fade
                change.duration = 0.12
                text.layer?.add(change, forKey: "seekNumberChange")
            }
            animateChevron()
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.beginFade(generation: currentGeneration)
        }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + G.hold, execute: work)
    }

    func dismiss() {
        cancelPendingFade()
        feedback.reset()
        layer?.removeAllAnimations()
        arrow.removeAllAnimations()
        text.layer?.removeAllAnimations()
        isHidden = true
        alphaValue = 1
        text.stringValue = ""
        setAccessibilityValue("")
    }

    private func animateChevron() {
        let nudge = CAKeyframeAnimation(keyPath: "transform.translation.x")
        nudge.values = [0, direction == .backward ? -6 : 6, 0]
        nudge.keyTimes = [0, 0.55, 1]
        nudge.duration = 0.18
        nudge.timingFunctions = [.init(name: .easeOut), .init(name: .easeInEaseOut)]
        arrow.add(nudge, forKey: "seekNudge")

        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [0.35, 1, 1]
        pulse.keyTimes = [0, 0.55, 1]
        pulse.duration = 0.18
        arrow.add(pulse, forKey: "seekPulse")
    }

    private func cancelPendingFade() {
        generation &+= 1
        fadeWork?.cancel()
        hideWork?.cancel()
        fadeWork = nil
        hideWork = nil
    }

    private func beginFade(generation expectedGeneration: UInt) {
        if reduceMotion {
            isHidden = true
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = G.fade
            self.animator().alphaValue = 0
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            self.isHidden = true
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + G.fade, execute: work)
    }
}

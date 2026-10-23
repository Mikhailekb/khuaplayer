import AppKit
import QuartzCore

/// Compact custom slider for the -100...100 percent adjustments.
///
/// A CALayer track with a neutral marker and a warm adjustment fill.
/// The control supports pointer, keyboard and accessibility interaction. Clicking jumps to the position, dragging
/// moves continuously, and a double-click resets to the default.
final class SPColorSlider: NSControl {
    var onValueChange: ((Double) -> Void)?
    var onDoubleClick: (() -> Void)?

    private enum Metric {
        static let trackHeight: CGFloat = 3.5
        static let knobSize: CGFloat = 15
        static let neutralHeight: CGFloat = 13
    }

    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private let knobLayer = CAGradientLayer()
    private let neutralLayer = CALayer()
    private let focusLayer = CALayer()
    private var dragging = false
    private(set) var percent: Double = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        trackLayer.cornerRadius = Metric.trackHeight / 2
        trackLayer.backgroundColor = NSColor(srgbRed: 0.35, green: 0.35, blue: 0.35, alpha: 1).cgColor
        fillLayer.cornerRadius = Metric.trackHeight / 2
        fillLayer.backgroundColor = NSColor(srgbRed: 1, green: 193.0 / 255, blue: 102.0 / 255, alpha: 1).cgColor
        neutralLayer.backgroundColor = NSColor.white.withAlphaComponent(0.30).cgColor
        focusLayer.borderColor = NSColor(srgbRed: 1, green: 193.0 / 255, blue: 102.0 / 255, alpha: 0.8).cgColor
        focusLayer.borderWidth = 2
        focusLayer.cornerRadius = Metric.knobSize / 2 + 3
        focusLayer.isHidden = true
        knobLayer.cornerRadius = Metric.knobSize / 2
        knobLayer.colors = [
            NSColor(srgbRed: 0.99, green: 0.99, blue: 0.97, alpha: 1).cgColor,
            NSColor(srgbRed: 0.94, green: 0.94, blue: 0.92, alpha: 1).cgColor,
            NSColor(srgbRed: 0.85, green: 0.85, blue: 0.83, alpha: 1).cgColor
        ]
        knobLayer.locations = [0, 0.55, 1]
        knobLayer.startPoint = CGPoint(x: 0.5, y: 1)
        knobLayer.endPoint = CGPoint(x: 0.5, y: 0)
        knobLayer.borderColor = NSColor.black.withAlphaComponent(0.6).cgColor
        knobLayer.borderWidth = 0.5
        knobLayer.shadowColor = NSColor.black.cgColor
        knobLayer.shadowOpacity = 0.5
        knobLayer.shadowRadius = 1.5
        knobLayer.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(neutralLayer)
        layer?.addSublayer(fillLayer)
        layer?.addSublayer(knobLayer)
        layer?.addSublayer(focusLayer)
        focusRingType = .none

        setAccessibilityRole(.slider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SPColorSlider: no coder path") }

    /// Update the displayed position without notifying observers.
    func setPercentSilently(_ value: Double) {
        percent = SPColorAdjust.clamp(value)
        needsLayout = true
        setAccessibilityValue(NSNumber(value: percent))
    }

    override var acceptsFirstResponder: Bool { isEnabled }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var trackFrame: NSRect {
        NSRect(x: Metric.knobSize / 2,
               y: (bounds.height - Metric.trackHeight) / 2,
               width: bounds.width - Metric.knobSize,
               height: Metric.trackHeight)
    }

    private func fraction(for percent: Double) -> CGFloat {
        CGFloat((SPColorAdjust.clamp(percent) + 100) / 200)
    }

    override func layout() {
        let track = trackFrame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = track
        neutralLayer.frame = NSRect(x: track.midX - 0.5,
                                   y: track.midY - Metric.neutralHeight / 2,
                                   width: 1,
                                   height: Metric.neutralHeight)
        let t = fraction(for: percent)
        fillLayer.frame = NSRect(x: track.minX + min(t, 0.5) * track.width,
                                 y: track.minY,
                                 width: abs(t - 0.5) * track.width,
                                 height: track.height)
        fillLayer.isHidden = abs(t - 0.5) < 0.001
        knobLayer.frame = NSRect(x: track.minX + t * track.width - Metric.knobSize / 2,
                                 y: (bounds.height - Metric.knobSize) / 2,
                                 width: Metric.knobSize,
                                 height: Metric.knobSize)
        knobLayer.shadowPath = CGPath(ellipseIn: knobLayer.bounds, transform: nil)
        focusLayer.frame = knobLayer.frame.insetBy(dx: -3, dy: -3)
        focusLayer.isHidden = window?.firstResponder !== self
        layer?.opacity = isEnabled ? 1 : 0.35
        CATransaction.commit()
    }

    override func becomeFirstResponder() -> Bool {
        needsLayout = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsLayout = true
        return super.resignFirstResponder()
    }

    override func accessibilityMinValue() -> Any? { NSNumber(value: -100) }
    override func accessibilityMaxValue() -> Any? { NSNumber(value: 100) }
    override func accessibilityPerformIncrement() -> Bool {
        guard isEnabled else { return false }; changeValue(by: 1); return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        guard isEnabled else { return false }; changeValue(by: -1); return true
    }

    private func changeValue(by delta: Double) {
        let next = SPColorAdjust.clamp(percent + delta)
        guard next != percent else { return }
        setPercentSilently(next)
        onValueChange?(next)
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        let step: Double = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123, 125: changeValue(by: -step)
        case 124, 126: changeValue(by: step)
        case 115: changeValue(by: -100 - percent)
        case 119: changeValue(by: 100 - percent)
        case 36, 76: onDoubleClick?()
        default: super.keyDown(with: event)
        }
    }

    private func percent(at point: NSPoint) -> Double {
        let track = trackFrame
        guard track.width > 0 else { return 0 }
        let t = min(1, max(0, (point.x - track.minX) / track.width))
        return Double(t) * 200 - 100
    }

    private func applyMouseEvent(_ event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let next = percent(at: local)
        if next != percent {
            setPercentSilently(next)
            onValueChange?(next)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.clickCount >= 2 {
            onDoubleClick?()
            return
        }
        dragging = true
        window?.makeFirstResponder(self)
        applyMouseEvent(event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging, isEnabled else { return }
        applyMouseEvent(event)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
    }
}

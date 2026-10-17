import AppKit
import QuartzCore

/// Compact custom slider for the -100...100 percent adjustments.
///
/// A CALayer track with a white knob, matching the chrome's hand-drawn control
/// style instead of a themed NSSlider. Clicking jumps to the position, dragging
/// moves continuously, and a double-click resets to the default.
final class SPColorSlider: NSControl {
    var onValueChange: ((Double) -> Void)?
    var onDoubleClick: (() -> Void)?

    private enum Metric {
        static let trackHeight: CGFloat = 4
        static let knobSize: CGFloat = 12
    }

    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private let knobLayer = CALayer()
    private var dragging = false
    private(set) var percent: Double = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        trackLayer.cornerRadius = Metric.trackHeight / 2
        trackLayer.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        fillLayer.cornerRadius = Metric.trackHeight / 2
        fillLayer.backgroundColor = NSColor.white.cgColor
        knobLayer.cornerRadius = Metric.knobSize / 2
        knobLayer.backgroundColor = NSColor.white.cgColor
        knobLayer.shadowColor = NSColor.black.cgColor
        knobLayer.shadowOpacity = 0.35
        knobLayer.shadowRadius = 2
        knobLayer.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(fillLayer)
        layer?.addSublayer(knobLayer)

        setAccessibilityRole(.slider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SPColorSlider: no coder path") }

    /// Update the displayed position without notifying observers.
    func setPercentSilently(_ value: Double) {
        percent = SPColorAdjust.clamp(value)
        needsLayout = true
        setAccessibilityValue("\(Int(percent))")
    }

    override var acceptsFirstResponder: Bool { true }
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
        CATransaction.commit()
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
        if event.clickCount >= 2 {
            onDoubleClick?()
            return
        }
        dragging = true
        window?.makeFirstResponder(self)
        applyMouseEvent(event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        applyMouseEvent(event)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
    }
}

/// Floating dark card with one slider row per picture adjustment.
///
/// Mirrors the playback notice's overlay pattern: a lazily created subview
/// placed above the video, faded in and out, laid out by the owning controller.
final class SPColorPanelView: NSView {
    private enum Metric {
        static let width: CGFloat = 336
        static let sidePadding: CGFloat = 16
        static let rowHeight: CGFloat = 30
        static let rowGap: CGFloat = 4
        static let labelWidth: CGFloat = 98
        static let valueWidth: CGFloat = 44
        static let resetSize: CGFloat = 24
        static let sliderGap: CGFloat = 10
        static let footerHeight: CGFloat = 30
        static let fade: CFTimeInterval = 0.15
    }

    private struct Row {
        let field: SPColorAdjust.Field
        let label: NSTextField
        let slider: SPColorSlider
        let value: NSTextField
        let reset: NSButton
    }

    var onChange: ((_ field: SPColorAdjust.Field, _ percent: Double) -> Void)?
    var onResetField: ((_ field: SPColorAdjust.Field) -> Void)?
    var onResetAll: (() -> Void)?

    private var rows: [Row] = []
    private let resetAllButton = NSButton(title: "", target: nil, action: nil)
    // Local swap-builds link the UI against a prebuilt framework that may
    // predate the hue setter; the row is hidden instead of crashing there.
    private var hueAvailable = true

    private var visibleRows: [Row] {
        rows.filter { $0.field != .hue || hueAvailable }
    }

    private var panelHeight: CGFloat {
        let count = visibleRows.count
        return CGFloat(count) * Metric.rowHeight
            + CGFloat(max(count - 1, 0)) * Metric.rowGap + Metric.footerHeight
    }

    func setHueAvailable(_ available: Bool) {
        guard hueAvailable != available else { return }
        hueAvailable = available
        if let row = rows.first(where: { $0.field == .hue }) {
            row.label.isHidden = !available
            row.slider.isHidden = !available
            row.value.isHidden = !available
            row.reset.isHidden = !available
        }
        setFrameSize(NSSize(width: Metric.width, height: panelHeight))
        needsLayout = true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.4
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -4)

        let entries: [SPColorAdjust.Field] = [.brightness, .contrast, .saturation, .gamma, .hue]
        for field in entries {
            let labelText: String
            switch field {
            case .brightness: labelText = L("color.brightness")
            case .contrast: labelText = L("color.contrast")
            case .saturation: labelText = L("color.saturation")
            case .gamma: labelText = L("color.gamma")
            case .hue: labelText = L("color.hue")
            }
            let label = NSTextField(labelWithString: labelText)
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = .white

            let slider = SPColorSlider(frame: .zero)
            slider.setAccessibilityLabel(labelText)
            slider.onValueChange = { [weak self] value in
                self?.onChange?(field, value)
            }
            slider.onDoubleClick = { [weak self] in
                self?.onResetField?(field)
            }

            let value = NSTextField(labelWithString: "")
            value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            value.textColor = NSColor.white.withAlphaComponent(0.6)
            value.alignment = .right

            let reset = NSButton(title: "", target: self,
                                 action: #selector(resetFieldAction(_:)))
            if let resetImage = NSImage(systemSymbolName: "arrow.counterclockwise",
                                        accessibilityDescription: L("color.reset")) {
                reset.image = resetImage
            }
            reset.isBordered = false
            reset.tag = field.rawValue

            addSubview(label)
            addSubview(slider)
            addSubview(value)
            addSubview(reset)
            rows.append(Row(field: field, label: label, slider: slider,
                            value: value, reset: reset))
        }

        resetAllButton.title = L("color.resetAll")
        resetAllButton.target = self
        resetAllButton.action = #selector(resetAllAction(_:))
        resetAllButton.isBordered = false
        resetAllButton.font = .systemFont(ofSize: 11, weight: .medium)
        resetAllButton.contentTintColor = NSColor.white.withAlphaComponent(0.7)
        addSubview(resetAllButton)

        isHidden = true
        alphaValue = 0
        needsLayout = true
        configure(with: SPColorAdjust())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SPColorPanelView: no coder path") }

    @objc private func resetFieldAction(_ sender: NSButton) {
        guard let field = SPColorAdjust.Field(rawValue: sender.tag) else { return }
        onResetField?(field)
    }

    @objc private func resetAllAction(_ sender: NSButton) {
        onResetAll?()
    }

    /// Sync every control from the model without emitting change callbacks.
    func configure(with value: SPColorAdjust) {
        for row in rows {
            let percent = value[row.field]
            row.slider.setPercentSilently(percent)
            row.value.stringValue = row.field == .hue
                ? String(format: "%+d°", Int(percent * 1.8))
                : String(format: "%+d", Int(percent))
            row.reset.contentTintColor = abs(percent) > 0.001
                ? NSColor.white.withAlphaComponent(0.85)
                : NSColor.white.withAlphaComponent(0.3)
        }
        resetAllButton.isEnabled = !value.isDefault
        needsLayout = true
    }

    override func layout() {
        let contentTop = bounds.height - Metric.footerHeight
        for (index, row) in visibleRows.enumerated() {
            let y = contentTop - Metric.rowHeight
                - CGFloat(index) * (Metric.rowHeight + Metric.rowGap)
            let sliderX = Metric.sidePadding + Metric.labelWidth + Metric.sliderGap
            let sliderW = bounds.width - sliderX - Metric.valueWidth
                - Metric.resetSize - Metric.sliderGap * 2 - Metric.sidePadding
            row.label.frame = NSRect(x: Metric.sidePadding, y: y + 6,
                                     width: Metric.labelWidth, height: 18)
            row.slider.frame = NSRect(x: sliderX, y: y + 3,
                                      width: sliderW, height: Metric.rowHeight - 6)
            row.value.frame = NSRect(x: sliderX + sliderW + Metric.sliderGap, y: y + 7,
                                     width: Metric.valueWidth, height: 16)
            row.reset.frame = NSRect(x: bounds.width - Metric.sidePadding - Metric.resetSize,
                                     y: y + 3, width: Metric.resetSize, height: Metric.resetSize)
        }
        let buttonSize = resetAllButton.intrinsicContentSize
        resetAllButton.frame = NSRect(
            x: (bounds.width - buttonSize.width) / 2,
            y: (Metric.footerHeight - buttonSize.height) / 2,
            width: buttonSize.width, height: buttonSize.height)
    }

    /// Position the card at the right edge of the playback area, vertically
    /// centered, matching the visual weight of the on-screen chrome.
    func place(in bounds: NSRect) {
        let height = panelHeight
        let side: CGFloat = bounds.width > Metric.width * 2 ? 24 : 12
        frame = NSRect(x: bounds.maxX - Metric.width - side,
                       y: max(bounds.midY - height / 2, 12),
                       width: Metric.width,
                       height: height)
    }

    func setVisible(_ visible: Bool) {
        if visible {
            isHidden = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Metric.fade
                animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Metric.fade
                animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.alphaValue == 0 else { return }
                    self.isHidden = true
                }
            })
        }
    }
}

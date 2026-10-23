import AppKit
import QuartzCore

private enum SPSettingsPalette {
    static let background = NSColor(white: 0.035, alpha: 0.88)
    static let primary = NSColor.white
    static let secondary = NSColor(white: 0.75, alpha: 1)
    static let line = NSColor.white.withAlphaComponent(0.13)
}

private class SPSettingsFlippedView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

@MainActor private func SPSettingsLabel(_ text: String, size: CGFloat = 14,
                                      secondary: Bool = false) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: size)
    label.textColor = secondary ? SPSettingsPalette.secondary : SPSettingsPalette.primary
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    return label
}

/// Each row is a single accessible button, including its current value.
private final class SPSettingsMenuRow: NSButton {
    enum Accessory { case chevron, checkmark, toggle, none }
    var onPress: (() -> Void)?
    var onNavigate: ((NSEvent) -> Bool)?
    var valueText = "" { didSet { refreshAccessibility(); needsDisplay = true } }
    var selected = false { didSet { refreshAccessibility(); needsDisplay = true } }
    var accessory: Accessory
    private let caption: String
    private let symbol: String?
    private var hovered = false
    private var tracking: NSTrackingArea?
    private let isBack: Bool

    init(_ title: String, symbol: String? = nil, accessory: Accessory = .chevron,
         identifier: String, back: Bool = false) {
        caption = title
        self.symbol = symbol
        self.accessory = accessory
        isBack = back
        super.init(frame: .zero)
        self.title = ""
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        target = self
        action = #selector(pressed)
        isBordered = false
        focusRingType = .none
        toolTip = title
        setAccessibilityLabel(title)
        if accessory == .toggle { setAccessibilityRole(.checkBox) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SPSettingsMenuRow: no coder path") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var mouseDownCanMoveWindow: Bool { false }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    @objc private func pressed() { if isEnabled { onPress?() } }
    private func refreshAccessibility() {
        setAccessibilityValue(accessory == .toggle || accessory == .checkmark ? selected as Any : valueText)
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(next)
        tracking = next
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 124 && accessory == .chevron { pressed(); return }
        if onNavigate?(event) == true { return }
        if event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 49 { pressed() }
        else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { guard isEnabled else { return false }; pressed(); return true }

    private func drawText(_ text: String, in rect: NSRect, color: NSColor, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = alignment
        (text as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: 14),
                                                          .foregroundColor: color, .paragraphStyle: paragraph])
    }
    override func draw(_ dirtyRect: NSRect) {
        let focused = window?.firstResponder === self
        if (hovered || focused || isHighlighted) && isEnabled {
            NSColor.white.withAlphaComponent(isHighlighted ? 0.17 : 0.10).setFill()
            bounds.fill()
        }
        let color = SPSettingsPalette.primary.withAlphaComponent(isEnabled ? 1 : 0.38)
        let valueColor = SPSettingsPalette.secondary.withAlphaComponent(isEnabled ? 1 : 0.4)
        let iconX: CGFloat = 17
        let textX: CGFloat = symbol == nil ? 48 : 52
        if let symbol, let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: isBack ? 16 : 19, weight: .regular)) {
            icon.lockFocus()
            color.set()
            NSRect(origin: .zero, size: icon.size).fill(using: .sourceAtop)
            icon.unlockFocus()
            icon.draw(in: NSRect(x: iconX, y: bounds.midY - 10, width: 20, height: 20))
        }
        let accessoryWidth: CGFloat = accessory == .toggle ? 58 : (accessory == .chevron ? 36 : 20)
        let valueWidth = valueText.isEmpty ? 0 : min(bounds.width * 0.42, CGFloat((valueText as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14)]).width) + 4)
        let titleWidth = max(0, bounds.width - textX - accessoryWidth - (valueWidth > 0 ? valueWidth + 12 : 0))
        drawText(caption, in: NSRect(x: textX, y: bounds.midY - 9, width: titleWidth, height: 20), color: color)
        if valueWidth > 0 {
            drawText(valueText, in: NSRect(x: bounds.width - accessoryWidth - valueWidth, y: bounds.midY - 9,
                                          width: valueWidth, height: 20), color: valueColor, alignment: .right)
        }
        if accessory == .chevron {
            let path = NSBezierPath()
            let x = bounds.width - 23
            path.move(to: NSPoint(x: x, y: bounds.midY - 5))
            path.line(to: NSPoint(x: x + 5, y: bounds.midY))
            path.line(to: NSPoint(x: x, y: bounds.midY + 5))
            path.lineWidth = 1.4
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            valueColor.setStroke()
            path.stroke()
        } else if accessory == .checkmark && selected {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 20, y: bounds.midY))
            path.line(to: NSPoint(x: 24, y: bounds.midY + 4))
            path.line(to: NSPoint(x: 31, y: bounds.midY - 4))
            path.lineWidth = 2
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            color.setStroke()
            path.stroke()
        } else if accessory == .toggle {
            let rect = NSRect(x: bounds.width - 54, y: bounds.midY - 10, width: 36, height: 20)
            NSColor.white.withAlphaComponent(selected ? 0.42 : 0.18).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.minX + (selected ? 18 : 2), y: rect.minY + 2, width: 16, height: 16)).fill()
        }
    }
}

/// A neutral slider keeps picture adjustments consistent with the pop-up menu.
private final class SPSettingsSlider: NSControl {
    var onChange: ((Double) -> Void)?
    var onReset: (() -> Void)?
    var minimum = -100.0
    var maximum = 100.0
    var step = 1.0
    var snapsToStep = false
    private(set) var current = 0.0
    private var dragging = false
    var neutral: Double? = 0
    override var acceptsFirstResponder: Bool { isEnabled }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        focusRingType = .none
        setAccessibilityRole(.slider)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SPSettingsSlider: no coder path") }
    func configure(_ value: Double, enabled: Bool) {
        if !dragging { current = min(maximum, max(minimum, value)) }
        isEnabled = enabled
        setAccessibilityValue(current)
        needsDisplay = true
    }
    private func commit(_ value: Double) {
        let snapped = snapsToStep && step > 0 ? (value / step).rounded() * step : value
        let next = min(maximum, max(minimum, snapped))
        guard next != current else { return }
        current = next
        needsDisplay = true
        setAccessibilityValue(current)
        onChange?(current)
    }
    private func apply(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let fraction = min(1, max(0, (point.x - 7) / max(1, bounds.width - 14)))
        commit(minimum + Double(fraction) * (maximum - minimum))
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        if event.clickCount >= 2 { onReset?(); return }
        dragging = true
        apply(event)
    }
    override func mouseDragged(with event: NSEvent) { if dragging { apply(event) } }
    override func mouseUp(with event: NSEvent) { if dragging { apply(event); dragging = false } }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { dragging = false; needsDisplay = true; return super.resignFirstResponder() }
    override func keyDown(with event: NSEvent) {
        let increment = step * (event.modifierFlags.contains(.shift) ? 10 : 1)
        switch event.keyCode {
        case 123, 125: commit(current - increment)
        case 124, 126: commit(current + increment)
        case 115: commit(minimum)
        case 119: commit(maximum)
        case 36, 76: onReset?()
        default: super.keyDown(with: event)
        }
    }
    override func accessibilityMinValue() -> Any? { minimum }
    override func accessibilityMaxValue() -> Any? { maximum }
    override func accessibilityPerformIncrement() -> Bool { guard isEnabled else { return false }; commit(current + step); return true }
    override func accessibilityPerformDecrement() -> Bool { guard isEnabled else { return false }; commit(current - step); return true }
    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 7, y: bounds.midY - 1.5, width: max(1, bounds.width - 14), height: 3)
        NSColor.white.withAlphaComponent(isEnabled ? 0.25 : 0.10).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
        let fraction = CGFloat((current - minimum) / max(1, maximum - minimum))
        let x = track.minX + fraction * track.width
        let start = neutral.map { track.minX + CGFloat(($0 - minimum) / max(1, maximum - minimum)) * track.width } ?? track.minX
        NSColor.white.withAlphaComponent(isEnabled ? 0.95 : 0.3).setFill()
        NSBezierPath(roundedRect: NSRect(x: min(start, x), y: track.minY, width: abs(x - start), height: 3), xRadius: 1.5, yRadius: 1.5).fill()
        if neutral != nil {
            NSColor.white.withAlphaComponent(0.35).setFill()
            NSRect(x: start - 0.5, y: bounds.midY - 5, width: 1, height: 10).fill()
        }
        NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.35).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - 6, y: bounds.midY - 6, width: 12, height: 12)).fill()
        if window?.firstResponder === self {
            NSColor.white.withAlphaComponent(0.6).setStroke()
            NSBezierPath(ovalIn: NSRect(x: x - 9, y: bounds.midY - 9, width: 18, height: 18)).stroke()
        }
    }
}

private final class SPSettingsValueRow: SPSettingsFlippedView, NSTextFieldDelegate {
    let slider = SPSettingsSlider(frame: .zero)
    let value = NSTextField()
    private let label: NSTextField
    private let reset: NSButton
    var onChange: ((Double) -> Void)?
    var onReset: (() -> Void)?
    var formatValue: (Double) -> String = { String(format: "%+.0f", $0) }
    var parseValue: (Double) -> Double = { $0 }
    private var current = 0.0

    init(_ title: String, identifier: String, resettable: Bool = true) {
        label = SPSettingsLabel(title)
        reset = NSButton(image: NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: L("color.reset"))!, target: nil, action: nil)
        super.init(frame: .zero)
        addSubview(label)
        slider.identifier = NSUserInterfaceItemIdentifier(identifier + ".slider")
        slider.setAccessibilityLabel(title)
        slider.onChange = { [weak self] next in
            guard let self else { return }
            self.current = next
            self.refreshText()
            self.onChange?(next)
        }
        slider.onReset = { [weak self] in self?.onReset?() }
        addSubview(slider)
        value.isBordered = false
        value.drawsBackground = false
        value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        value.textColor = .white
        value.alignment = .right
        value.focusRingType = .none
        value.delegate = self
        value.identifier = NSUserInterfaceItemIdentifier(identifier + ".value")
        value.setAccessibilityLabel(title)
        addSubview(value)
        reset.isBordered = false
        reset.contentTintColor = .white
        reset.target = self
        reset.action = #selector(resetPressed)
        reset.identifier = NSUserInterfaceItemIdentifier(identifier + ".reset")
        reset.toolTip = L("color.reset")
        reset.setAccessibilityLabel(L("color.reset") + ": " + title)
        reset.isHidden = !resettable
        addSubview(reset)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SPSettingsValueRow: no coder path") }
    @objc private func resetPressed() { onReset?() }
    private func refreshText() { if value.currentEditor() == nil { value.stringValue = formatValue(current) } }
    func configure(_ next: Double, enabled: Bool, help: String? = nil) {
        current = next
        slider.configure(next, enabled: enabled)
        value.isEnabled = enabled
        reset.isEnabled = enabled
        label.alphaValue = enabled ? 1 : 0.4
        toolTip = help
        slider.toolTip = help
        value.toolTip = help
        refreshText()
    }
    override func layout() {
        label.frame = NSRect(x: 18, y: 7, width: max(0, bounds.width - 116), height: 20)
        value.frame = NSRect(x: bounds.width - 95, y: 7, width: 48, height: 20)
        reset.frame = NSRect(x: bounds.width - 42, y: 5, width: 25, height: 24)
        slider.frame = NSRect(x: 18, y: 28, width: max(0, bounds.width - 36), height: 28)
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        let text = value.stringValue.replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "°", with: "").replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Double(text), number.isFinite {
            current = min(slider.maximum, max(slider.minimum, parseValue(number)))
            slider.configure(current, enabled: slider.isEnabled)
            value.stringValue = formatValue(current)
            onChange?(current)
        } else { value.stringValue = formatValue(current) }
    }
}

private final class SPSettingsStepperRow: SPSettingsFlippedView, NSTextFieldDelegate {
    let value = NSTextField()
    private let minus = NSButton()
    private let plus = NSButton()
    private let label: NSTextField
    private var current = 1.0
    private let minimum: Double
    private let maximum: Double
    private let step: Double
    private let percent: Bool
    var onChange: ((Double) -> Void)?

    init(_ title: String, identifier: String, minimum: Double, maximum: Double, step: Double, percent: Bool = false) {
        label = SPSettingsLabel(title)
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
        self.percent = percent
        super.init(frame: .zero)
        addSubview(label)
        for (button, symbol, suffix, description) in [(minus, "minus", ".minus", L("settings.decrease")), (plus, "plus", ".plus", L("settings.increase"))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
            button.title = ""
            button.isBordered = false
            button.contentTintColor = .white
            button.target = self
            button.action = button === minus ? #selector(decrease) : #selector(increase)
            button.identifier = NSUserInterfaceItemIdentifier(identifier + suffix)
            button.setAccessibilityLabel(description + ": " + title)
            addSubview(button)
        }
        value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        value.alignment = .center
        value.isBordered = false
        value.drawsBackground = false
        value.textColor = .white
        value.delegate = self
        value.identifier = NSUserInterfaceItemIdentifier(identifier)
        value.setAccessibilityLabel(title)
        addSubview(value)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SPSettingsStepperRow: no coder path") }
    @objc private func decrease() { commit(current - step) }
    @objc private func increase() { commit(current + step) }
    private func formatted() -> String { percent ? String(format: "%.0f%%", current * 100) : String(format: "%.2f×", current) }
    func configure(_ next: Double, enabled: Bool) {
        current = min(maximum, max(minimum, next))
        if value.currentEditor() == nil { value.stringValue = formatted() }
        minus.isEnabled = enabled && current > minimum + 0.0001
        plus.isEnabled = enabled && current < maximum - 0.0001
        value.isEnabled = enabled
        label.alphaValue = enabled ? 1 : 0.4
    }
    private func commit(_ next: Double) {
        current = min(maximum, max(minimum, next))
        value.stringValue = formatted()
        onChange?(current)
    }
    override func layout() {
        label.frame = NSRect(x: 18, y: bounds.midY - 9, width: max(0, bounds.width - 182), height: 20)
        minus.frame = NSRect(x: bounds.width - 164, y: bounds.midY - 15, width: 34, height: 30)
        value.frame = NSRect(x: bounds.width - 130, y: bounds.midY - 10, width: 70, height: 22)
        plus.frame = NSRect(x: bounds.width - 57, y: bounds.midY - 15, width: 34, height: 30)
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        let text = value.stringValue.replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "×", with: "").replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Double(text), number.isFinite { commit(percent ? number / 100 : number) }
        else { value.stringValue = formatted() }
    }
}

@MainActor private func SPSettingsRateText(_ value: Double, fixedPrecision: Bool = false) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = fixedPrecision ? 2 : 0
    formatter.maximumFractionDigits = 2
    formatter.usesGroupingSeparator = false
    return (formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)) + "×"
}

/// Custom speed stays on the same page as the presets, matching the menu's
/// immediate controls while keeping decoder changes in the controller.
private final class SPSettingsSpeedRow: SPSettingsFlippedView {
    let slider = SPSettingsSlider(frame: .zero)
    private let currentLabel = SPSettingsLabel("")
    private let minus = NSButton()
    private let plus = NSButton()
    private var current = 1.0
    private var enabled = false
    var onChange: ((Double) -> Void)?
    private let minimum = 0.25
    private let maximum = 5.0
    private let step = 0.05

    override init(frame: NSRect) {
        super.init(frame: frame)
        currentLabel.font = .monospacedDigitSystemFont(ofSize: 16, weight: .medium)
        currentLabel.alignment = .center
        currentLabel.identifier = NSUserInterfaceItemIdentifier("settings.playback.rate.value")
        currentLabel.setAccessibilityLabel(L("chrome.rate.tooltip"))
        addSubview(currentLabel)
        for (button, symbol, suffix, description) in [(minus, "minus", ".minus", L("settings.decrease")),
                                                       (plus, "plus", ".plus", L("settings.increase"))] {
            button.title = ""
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
            button.isBordered = false
            button.contentTintColor = .white
            button.wantsLayer = true
            button.layer?.cornerRadius = 16
            button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
            button.target = self
            button.action = button === minus ? #selector(decrease) : #selector(increase)
            button.identifier = NSUserInterfaceItemIdentifier("settings.playback.rate" + suffix)
            button.setAccessibilityLabel(description + ": " + L("chrome.rate.tooltip"))
            button.toolTip = description
            addSubview(button)
        }
        slider.minimum = minimum
        slider.maximum = maximum
        slider.step = step
        slider.snapsToStep = true
        slider.neutral = nil
        slider.identifier = NSUserInterfaceItemIdentifier("settings.playback.rate.slider")
        slider.setAccessibilityLabel(L("chrome.rate.tooltip"))
        slider.onChange = { [weak self] in self?.commit($0) }
        slider.onReset = { [weak self] in self?.commit(1) }
        addSubview(slider)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SPSettingsSpeedRow: no coder path") }
    @objc private func decrease() { commit(current - step) }
    @objc private func increase() { commit(current + step) }
    func configure(_ next: Double, enabled: Bool) {
        current = min(maximum, max(minimum, next))
        self.enabled = enabled
        currentLabel.stringValue = SPSettingsRateText(current, fixedPrecision: true)
        currentLabel.alphaValue = enabled ? 1 : 0.4
        slider.configure(current, enabled: enabled)
        minus.isEnabled = enabled && current > minimum + 0.0001
        plus.isEnabled = enabled && current < maximum - 0.0001
        minus.alphaValue = minus.isEnabled ? 1 : 0.35
        plus.alphaValue = plus.isEnabled ? 1 : 0.35
    }
    private func commit(_ value: Double) {
        guard enabled else { return }
        let next = min(maximum, max(minimum, (value / step).rounded() * step))
        guard abs(next - current) > 0.000001 else { return }
        configure(next, enabled: enabled)
        onChange?(next)
    }
    override func layout() {
        currentLabel.frame = NSRect(x: 18, y: 10, width: max(0, bounds.width - 36), height: 24)
        minus.frame = NSRect(x: 18, y: 44, width: 32, height: 32)
        plus.frame = NSRect(x: bounds.width - 50, y: 44, width: 32, height: 32)
        slider.frame = NSRect(x: 62, y: 44, width: max(1, bounds.width - 124), height: 32)
    }
    override func draw(_ dirtyRect: NSRect) {
        SPSettingsPalette.line.setFill()
        NSRect(x: 0, y: bounds.height - 0.5, width: bounds.width, height: 0.5).fill()
    }
}

private final class SPSettingsNoteRow: SPSettingsFlippedView {
    private let label = SPSettingsLabel("", size: 12, secondary: true)
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        addSubview(label)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SPSettingsNoteRow: no coder path") }
    func configure(_ text: String) {
        label.stringValue = text
        label.toolTip = text
        isHidden = text.isEmpty
        needsLayout = true
    }
    func preferredHeight(for width: CGFloat) -> CGFloat {
        guard !label.stringValue.isEmpty else { return 0 }
        let size = (label.stringValue as NSString).boundingRect(with: NSSize(width: max(40, width - 36), height: 1000),
                                                               options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                               attributes: [.font: NSFont.systemFont(ofSize: 12)])
        return ceil(size.height) + 16
    }
    override func layout() {
        label.frame = NSRect(x: 18, y: 6, width: max(0, bounds.width - 36), height: max(0, bounds.height - 12))
    }
}

private final class SPSettingsMenuPage: SPSettingsFlippedView {
    var rows: [(NSView, CGFloat)] = []
    func append(_ view: NSView, height: CGFloat = 44) { rows.append((view, height)); addSubview(view) }
    var preferredHeight: CGFloat { preferredHeight(for: bounds.width > 0 ? bounds.width : 380) }
    func preferredHeight(for width: CGFloat) -> CGFloat {
        rows.reduce(CGFloat(0)) { total, item in
            total + (item.0.isHidden ? 0 : ((item.0 as? SPSettingsNoteRow)?.preferredHeight(for: width) ?? item.1))
        }
    }
    override func layout() {
        var y: CGFloat = 0
        for (row, height) in rows {
            let actualHeight = row.isHidden ? 0 : ((row as? SPSettingsNoteRow)?.preferredHeight(for: bounds.width) ?? height)
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: actualHeight)
            y += actualHeight
        }
    }
}

/// An in-window settings menu; every player mutation remains an action.
final class SPPlaybackSettingsView: NSView {
    private enum Page: Equatable {
        case root, audioTracks, subtitles, speed, picture, video, audio, layout
        case aspect, crop, rotation, mirror, timeline, pinch, sensitivity
    }
    var onAction: ((SPSettingsAction) -> Void)?
    var onClose: (() -> Void)?
    var onPreferredSizeChanged: (() -> Void)?
    private(set) var selectedTab: SPSettingsTab = .video
    private var snapshot = SPSettingsSnapshot()
    private var navigation: [Page] = [.root]
    private var currentPage: Page { navigation.last ?? .root }
    private let scrollView = NSScrollView()
    private var page = SPSettingsMenuPage()
    private var backRow: SPSettingsMenuRow?
    private var updates: [(SPSettingsSnapshot) -> Void] = []
    private var rowButtons: [SPSettingsMenuRow] = []
    private var trackSignature: [SPSettingsTrack] = []
    var preferredMenuSize: NSSize { NSSize(width: currentPage == .root ? 420 : 380, height: page.preferredHeight + (currentPage == .root ? 16 : 60)) }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = SPSettingsPalette.background.cgColor
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        identifier = NSUserInterfaceItemIdentifier("settings.popup")
        setAccessibilityRole(.group)
        setAccessibilityLabel(L("settings.title"))
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.contentView.drawsBackground = false
        addSubview(scrollView)
        buildPage(animated: false, backwards: false)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SPPlaybackSettingsView: no coder path") }

    func resetNavigation() {
        window?.makeFirstResponder(self)
        navigation = [.root]
        buildPage(animated: false, backwards: true)
    }
    func showSpeedSettings() {
        window?.makeFirstResponder(self)
        navigation = [.root, .speed]
        buildPage(animated: false, backwards: false)
    }
    func selectTab(_ tab: SPSettingsTab) {
        selectedTab = tab
        let destination: Page
        switch tab { case .layout: destination = .layout; case .video: destination = .video; case .audio: destination = .audio; case .subtitles: destination = .subtitles }
        navigation = [.root, destination]
        buildPage(animated: false, backwards: false)
    }
    private func navigate(to destination: Page) {
        window?.makeFirstResponder(self)
        navigation.append(destination)
        buildPage(animated: true, backwards: false)
    }
    private func goBack() {
        guard navigation.count > 1 else { onClose?(); return }
        window?.makeFirstResponder(self)
        navigation.removeLast()
        buildPage(animated: true, backwards: true)
    }
    private func title(for destination: Page) -> String {
        switch destination {
        case .root: return L("settings.title")
        case .audioTracks: return L("menu.audioTracks")
        case .subtitles: return L("settings.subtitles")
        case .speed: return L("chrome.rate.tooltip")
        case .picture: return L("settings.picture")
        case .video: return L("settings.video")
        case .audio: return L("settings.audio")
        case .layout: return L("settings.layout")
        case .aspect: return L("settings.aspect")
        case .crop: return L("menu.crop")
        case .rotation: return L("menu.rotation")
        case .mirror: return L("menu.mirror")
        case .timeline: return L("settings.timeline")
        case .pinch: return L("settings.pinch")
        case .sensitivity: return L("settings.sensitivity")
        }
    }
    private func menuRow(_ title: String, symbol: String? = nil, identifier: String,
                         accessory: SPSettingsMenuRow.Accessory = .chevron,
                         action: @escaping () -> Void) -> SPSettingsMenuRow {
        let row = SPSettingsMenuRow(title, symbol: symbol, accessory: accessory, identifier: identifier)
        row.onPress = action
        row.onNavigate = { [weak self] in self?.handleNavigation($0) ?? false }
        rowButtons.append(row)
        page.append(row)
        return row
    }
    private func link(_ destination: Page, symbol: String, identifier: String,
                      enabled: @escaping (SPSettingsSnapshot) -> Bool = { _ in true },
                      value: @escaping (SPSettingsSnapshot) -> String = { _ in "" }) {
        let row = menuRow(title(for: destination), symbol: symbol, identifier: identifier) { [weak self] in self?.navigate(to: destination) }
        updates.append { snapshot in row.valueText = value(snapshot); row.isEnabled = enabled(snapshot) }
    }
    private func choice(_ title: String, identifier: String,
                        selected: @escaping (SPSettingsSnapshot) -> Bool,
                        enabled: @escaping (SPSettingsSnapshot) -> Bool = { $0.hasMedia },
                        action: @escaping () -> Void) {
        let row = menuRow(title, identifier: identifier, accessory: .checkmark, action: action)
        updates.append { snapshot in row.selected = selected(snapshot); row.isEnabled = enabled(snapshot) }
    }
    @discardableResult
    private func toggle(_ title: String, symbol: String, identifier: String,
                        value: @escaping (SPSettingsSnapshot) -> Bool,
                        enabled: @escaping (SPSettingsSnapshot) -> Bool = { _ in true },
                        action: @escaping (Bool) -> Void) -> SPSettingsMenuRow {
        let row = menuRow(title, symbol: symbol, identifier: identifier, accessory: .toggle) { [weak self] in
            guard let self else { return }; action(!value(self.snapshot))
        }
        updates.append { snapshot in row.selected = value(snapshot); row.isEnabled = enabled(snapshot) }
        return row
    }
    private func perform(_ action: SPSettingsAction, back: Bool = false) {
        onAction?(action)
        if back { goBack() }
    }
    private static let ratios: [(String, Int)] = [("1:1", 1000), ("5:4", 1250), ("4:3", 1333), ("3:2", 1500), ("16:10", 1600),
                                                  ("16:9", 1778), ("1.85:1", 1850), ("2.21:1", 2210), ("2.35:1", 2350), ("2.39:1", 2390), ("2.76:1", 2760)]
    private func ratioName(_ value: Int, crop: Bool = false) -> String {
        value == 0 ? (crop ? L("menu.crop.none") : L("settings.sourceAspect")) : Self.ratios.first(where: { $0.1 == value })?.0 ?? "—"
    }
    private func buildPage(animated: Bool, backwards: Bool) {
        let prior = page
        page = SPSettingsMenuPage()
        updates = []
        rowButtons = []
        backRow?.removeFromSuperview()
        backRow = nil
        if currentPage != .root {
            let back = SPSettingsMenuRow(title(for: currentPage), symbol: "chevron.left", accessory: .none,
                                         identifier: "settings.back", back: true)
            back.setAccessibilityLabel(L("settings.back") + ": " + title(for: currentPage))
            back.onPress = { [weak self] in self?.goBack() }
            back.onNavigate = { [weak self] in self?.handleNavigation($0) ?? false }
            addSubview(back)
            backRow = back
        }
        buildRows()
        updates.forEach { $0(snapshot) }
        scrollView.documentView = page
        scrollView.contentView.scroll(to: .zero)
        needsLayout = true
        layoutSubtreeIfNeeded()
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let motion = CABasicAnimation(keyPath: "transform.translation.x")
            motion.fromValue = backwards ? -12 : 12
            motion.toValue = 0
            motion.duration = 0.12
            motion.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.4
            fade.toValue = 1
            fade.duration = 0.12
            page.wantsLayer = true
            page.layer?.add(motion, forKey: "settings.navigation.motion")
            page.layer?.add(fade, forKey: "settings.navigation.fade")
        }
        prior.removeFromSuperview()
        // Navigation already changed the page kind before this rebuild. Notify
        // even when row counts match, so root/submenu width changes are applied.
        onPreferredSizeChanged?()
    }
    private func buildRows() {
        switch currentPage {
        case .root:
            link(.audioTracks, symbol: "person.wave.2", identifier: "settings.root.audioTrack", enabled: { $0.hasMedia }, value: { snapshot in
                snapshot.audioTracks.first(where: { $0.id == snapshot.selectedAudio })?.title ?? L("settings.noAudio")
            })
            link(.subtitles, symbol: "captions.bubble", identifier: "settings.root.subtitles", enabled: { $0.hasMedia }, value: { snapshot in
                snapshot.selectedSubtitle == "off" ? L("settings.off") : snapshot.subtitleTracks.first(where: { $0.id == snapshot.selectedSubtitle })?.title ?? L("settings.off")
            })
            link(.speed, symbol: "speedometer", identifier: "settings.root.speed", enabled: { $0.hasMedia }, value: { $0.rate == 1 ? L("settings.speed.normal") : SPSettingsRateText($0.rate) })
            link(.picture, symbol: "sun.max", identifier: "settings.root.picture", enabled: { $0.hasVideo })
            link(.video, symbol: "rectangle", identifier: "settings.root.video", enabled: { $0.hasVideo }, value: { $0.resolutionBadge })
            link(.audio, symbol: "speaker.wave.2", identifier: "settings.root.audio", enabled: { $0.hasMedia }, value: { $0.muted ? L("settings.mute") : String(format: "%.0f%%", $0.volume) })
            link(.layout, symbol: "slider.horizontal.3", identifier: "settings.root.layout")
            _ = menuRow(L("torrent.settings.title"), symbol: "arrow.down.circle", identifier: "settings.root.torrent", accessory: .none) { [weak self] in
                self?.perform(.torrentSettings)
            }
            let info = menuRow(L("settings.information"), symbol: "info.circle", identifier: "settings.video.information", accessory: .none) { [weak self] in self?.perform(.mediaInfo) }
            updates.append { info.isEnabled = $0.hasMedia }
        case .audioTracks:
            trackSignature = snapshot.audioTracks
            if snapshot.audioTracks.isEmpty { addSummary(L("settings.noAudio")) }
            for track in snapshot.audioTracks {
                choice(track.title, identifier: "settings.track.\(track.id)", selected: { $0.selectedAudio == track.id }) { [weak self] in self?.perform(.audioTrack(track.id), back: true) }
            }
        case .subtitles:
            trackSignature = snapshot.subtitleTracks
            var tracks = snapshot.subtitleTracks
            if !tracks.contains(where: { $0.id == "off" }) { tracks.insert(SPSettingsTrack(id: "off", title: L("settings.off")), at: 0) }
            for track in tracks {
                choice(track.title, identifier: "settings.track.\(track.id)", selected: { $0.selectedSubtitle == track.id }) { [weak self] in self?.perform(.subtitleTrack(track.id), back: true) }
            }
            let load = menuRow(L("menu.loadSubtitle"), symbol: "plus", identifier: "settings.subtitles.load", accessory: .none) { [weak self] in self?.perform(.loadSubtitle) }
            updates.append { load.isEnabled = $0.hasMedia }
            let scale = SPSettingsStepperRow(L("settings.subtitleScale"), identifier: "settings.subtitles.scale", minimum: 0.25, maximum: 3, step: 0.1, percent: true)
            scale.onChange = { [weak self] in self?.perform(.subtitleScale($0)) }
            page.append(scale, height: 48)
            updates.append { scale.configure($0.subtitleScale, enabled: $0.hasMedia) }
        case .speed:
            let rate = SPSettingsSpeedRow(frame: .zero)
            rate.onChange = { [weak self] in self?.perform(.rate($0)) }
            page.append(rate, height: 94)
            updates.append { rate.configure($0.rate, enabled: $0.hasMedia) }
            for speed in [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0] {
                choice(speed == 1 ? L("settings.speed.normal") : SPSettingsRateText(speed), identifier: "settings.speed.\(speed)", selected: { abs($0.rate - speed) < 0.001 }) { [weak self] in self?.perform(.rate(speed), back: true) }
            }
        case .picture:
            let brightRoom = toggle(L("color.hdrBrightRoom"), symbol: "sun.max", identifier: "settings.picture.hdrBrightRoom",
                                    value: { $0.hdrBrightRoomEnabled }, enabled: { $0.hasVideo && $0.hdrBrightRoomAvailable }) { [weak self] in
                self?.perform(.hdrBrightRoom($0))
            }
            brightRoom.toolTip = L("color.hdrBrightRoom.help")
            brightRoom.setAccessibilityHelp(L("color.hdrBrightRoom.help"))
            updates.append { brightRoom.isHidden = !$0.hdrBrightRoomAvailable }
            let brightRoomNote = SPSettingsNoteRow(frame: .zero)
            brightRoomNote.identifier = NSUserInterfaceItemIdentifier("settings.picture.hdrBrightRoom.help")
            page.append(brightRoomNote, height: 0)
            updates.append { brightRoomNote.configure($0.hdrBrightRoomAvailable ? L("color.hdrBrightRoom.help") : "") }
            let xdr = toggle("Brightness+", symbol: "sun.max.fill", identifier: "settings.picture.xdr", value: { $0.xdrEnabled },
                             enabled: { $0.hasVideo && $0.xdrAvailable }) { [weak self] in self?.perform(.xdr($0)) }
            xdr.setAccessibilityLabel(L("chrome.xdr.a11y.label"))
            updates.append { snapshot in
                let help = snapshot.xdrAvailable
                    ? (snapshot.xdrEnabled ? L("chrome.xdr.tooltip.on") : L("chrome.xdr.tooltip.off"))
                    : snapshot.xdrReason
                xdr.toolTip = help
                xdr.setAccessibilityHelp(help)
            }
            let xdrNote = SPSettingsNoteRow(frame: .zero)
            xdrNote.identifier = NSUserInterfaceItemIdentifier("settings.picture.xdr.reason")
            page.append(xdrNote, height: 0)
            updates.append { xdrNote.configure($0.xdrAvailable ? "" : $0.xdrReason) }
            let fields: [(SPColorAdjust.Field, String, String)] = [(.brightness, "brightness", L("color.brightness")), (.contrast, "contrast", L("color.contrast")),
                                                                  (.saturation, "saturation", L("color.saturation")), (.gamma, "gamma", L("color.gamma")), (.hue, "hue", L("color.hue"))]
            for (field, name, title) in fields {
                let row = SPSettingsValueRow(title, identifier: "settings.picture.\(name)")
                row.onChange = { [weak self] in self?.perform(.picture(field, $0)) }
                row.onReset = { [weak self] in self?.perform(.resetPicture(field)) }
                row.formatValue = { percent in
                    if field == .gamma { return String(format: "%.2f", pow(2, percent / 100)) }
                    if field == .hue { return String(format: "%.0f°", percent * 1.8) }
                    return percent == 0 ? "0" : String(format: "%+.0f", percent)
                }
                row.parseValue = { field == .gamma ? ($0 > 0 ? log2($0) * 100 : -100) : (field == .hue ? $0 / 1.8 : $0) }
                page.append(row, height: 60)
                updates.append { snapshot in
                    let supported = field != .hue || snapshot.hueAvailable
                    row.configure(snapshot.picture[field], enabled: snapshot.hasVideo && supported, help: supported ? nil : L("settings.hueUnavailable"))
                }
            }
            let reset = menuRow(L("color.resetAll"), symbol: "arrow.counterclockwise", identifier: "settings.picture.resetAll", accessory: .none) { [weak self] in self?.perform(.resetAllPicture) }
            updates.append { reset.isEnabled = $0.hasVideo }
        case .video:
            addSummary(snapshot.hasMedia ? snapshot.videoSummary : L("settings.noMedia"))
            link(.aspect, symbol: "aspectratio", identifier: "settings.video.aspect", enabled: { $0.hasVideo }, value: { [weak self] in self?.ratioName($0.forcedAspect) ?? "" })
            link(.crop, symbol: "crop", identifier: "settings.video.crop", enabled: { $0.hasVideo }, value: { [weak self] in self?.ratioName($0.crop, crop: true) ?? "" })
            link(.rotation, symbol: "rotate.right", identifier: "settings.video.rotation", enabled: { $0.hasVideo }, value: { "\($0.rotation)°" })
            link(.mirror, symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", identifier: "settings.video.mirror", enabled: { $0.hasVideo }, value: { $0.mirror == 1 ? L("menu.mirror.horizontal") : ($0.mirror == 2 ? L("menu.mirror.vertical") : L("menu.mirror.none")) })
            addInfo(L("settings.decoder"), value: { $0.decoder })
            addInfo(L("settings.output"), value: { $0.dynamicRange })
        case .audio:
            let volume = SPSettingsValueRow(L("settings.volume"), identifier: "settings.audio.volume", resettable: false)
            volume.slider.minimum = 0
            volume.slider.maximum = 100
            volume.slider.neutral = nil
            volume.formatValue = { String(format: "%.0f%%", $0) }
            volume.onChange = { [weak self] in self?.perform(.volume($0)) }
            page.append(volume, height: 64)
            updates.append { volume.configure($0.volume, enabled: $0.hasMedia) }
            toggle(L("settings.mute"), symbol: "speaker.slash", identifier: "settings.audio.mute", value: { $0.muted }, enabled: { $0.hasMedia }) { [weak self] in self?.perform(.muted($0)) }
            link(.audioTracks, symbol: "person.wave.2", identifier: "settings.audio.track", enabled: { $0.hasMedia })
        case .layout:
            link(.timeline, symbol: "waveform.path", identifier: "settings.layout.timeline", value: { [L("menu.timelineStyle.starTrail"), L("menu.timelineStyle.tide"), L("menu.timelineStyle.classic")][min(2, max(0, $0.timeline))] })
            toggle(L("menu.gestures.horizontalSeek"), symbol: "arrow.left.and.right", identifier: "settings.layout.horizontalSeek", value: { $0.horizontalSeek }) { [weak self] in self?.perform(.horizontalSeek($0)) }
            toggle(L("menu.gestures.verticalVolume"), symbol: "arrow.up.and.down", identifier: "settings.layout.verticalVolume", value: { $0.verticalVolume }) { [weak self] in self?.perform(.verticalVolume($0)) }
            link(.pinch, symbol: "arrow.up.left.and.arrow.down.right", identifier: "settings.layout.pinch", value: { [L("menu.gestures.pinch.resizeWindow"), L("menu.gestures.pinch.fullscreen"), L("menu.gestures.pinch.disabled")][min(2, max(0, $0.pinch))] })
            link(.sensitivity, symbol: "hand.draw", identifier: "settings.layout.sensitivity", value: { $0.seekSensitivity < 0.75 ? L("menu.gestures.sensitivity.low") : ($0.seekSensitivity > 1.5 ? L("menu.gestures.sensitivity.high") : L("menu.gestures.sensitivity.normal")) })
            toggle(L("menu.gestures.pinch.fullscreen"), symbol: "arrow.up.left.and.arrow.down.right", identifier: "settings.layout.fullscreen", value: { $0.fullscreen }) { [weak self] _ in self?.perform(.fullscreen) }
            let fit = menuRow(L("settings.fitWindow"), symbol: "macwindow", identifier: "settings.layout.fitWindow", accessory: .none) { [weak self] in self?.perform(.fitWindow) }
            updates.append { fit.isEnabled = $0.hasVideo && !$0.fullscreen }
        case .aspect, .crop:
            let cropping = currentPage == .crop
            for (name, number) in [((cropping ? L("menu.crop.none") : L("settings.sourceAspect")), 0)] + Self.ratios {
                choice(name, identifier: "settings.choice.\(number)", selected: { (cropping ? $0.crop : $0.forcedAspect) == number }, enabled: { $0.hasVideo }) { [weak self] in self?.perform(cropping ? .crop(number) : .forcedAspect(number), back: true) }
            }
        case .rotation:
            for angle in [0, 90, 180, 270] {
                choice("\(angle)°", identifier: "settings.rotation.\(angle)", selected: { $0.rotation == angle }, enabled: { $0.hasVideo }) { [weak self] in self?.perform(.rotation(angle), back: true) }
            }
        case .mirror:
            for (index, name) in [L("menu.mirror.none"), L("menu.mirror.horizontal"), L("menu.mirror.vertical")].enumerated() {
                choice(name, identifier: "settings.mirror.\(index)", selected: { $0.mirror == index }, enabled: { $0.hasVideo }) { [weak self] in self?.perform(.mirror(index), back: true) }
            }
        case .timeline:
            for (index, name) in [L("menu.timelineStyle.starTrail"), L("menu.timelineStyle.tide"), L("menu.timelineStyle.classic")].enumerated() {
                choice(name, identifier: "settings.timeline.\(index)", selected: { $0.timeline == index }, enabled: { _ in true }) { [weak self] in self?.perform(.timeline(index), back: true) }
            }
        case .pinch:
            for (index, name) in [L("menu.gestures.pinch.resizeWindow"), L("menu.gestures.pinch.fullscreen"), L("menu.gestures.pinch.disabled")].enumerated() {
                choice(name, identifier: "settings.pinch.\(index)", selected: { $0.pinch == index }, enabled: { _ in true }) { [weak self] in self?.perform(.pinch(index), back: true) }
            }
        case .sensitivity:
            for (number, name) in [(0.5, L("menu.gestures.sensitivity.low")), (1.0, L("menu.gestures.sensitivity.normal")), (2.0, L("menu.gestures.sensitivity.high"))] {
                choice(name, identifier: "settings.sensitivity.\(number)", selected: { abs($0.seekSensitivity - number) < 0.01 }, enabled: { _ in true }) { [weak self] in self?.perform(.seekSensitivity(number), back: true) }
            }
        }
    }
    private func addSummary(_ text: String) {
        let label = SPSettingsLabel(text, size: 12, secondary: true)
        label.toolTip = text
        let wrapper = SPSettingsFlippedView()
        wrapper.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 18),
                                     label.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -18),
                                     label.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor)])
        page.append(wrapper, height: 38)
    }
    private func addInfo(_ title: String, value: @escaping (SPSettingsSnapshot) -> String) {
        let row = menuRow(title, identifier: "settings.info.\(rowButtons.count)", accessory: .none) {}
        row.isEnabled = false
        updates.append { row.valueText = value($0).isEmpty ? "—" : value($0) }
    }
    func configure(_ next: SPSettingsSnapshot) {
        guard snapshot != next else { return }
        snapshot = next
        let tracksChanged = currentPage == .audioTracks ? trackSignature != next.audioTracks : (currentPage == .subtitles && trackSignature != next.subtitleTracks)
        if tracksChanged { buildPage(animated: false, backwards: false) }
        else {
            let previousSize = preferredMenuSize
            updates.forEach { $0(next) }
            needsLayout = true
            if preferredMenuSize != previousSize { onPreferredSizeChanged?() }
        }
    }
    override func layout() {
        super.layout()
        let header: CGFloat = currentPage == .root ? 8 : 52
        backRow?.frame = NSRect(x: 0, y: 4, width: bounds.width, height: 44)
        scrollView.frame = NSRect(x: 0, y: header, width: bounds.width, height: max(0, bounds.height - header - 8))
        page.frame = NSRect(x: 0, y: 0, width: scrollView.contentSize.width, height: max(scrollView.contentSize.height, page.preferredHeight(for: scrollView.contentSize.width)))
        page.needsLayout = true
    }
    override func draw(_ dirtyRect: NSRect) {
        if currentPage != .root {
            SPSettingsPalette.line.setFill()
            NSRect(x: 0, y: 50, width: bounds.width, height: 0.5).fill()
        }
    }
    private func handleNavigation(_ event: NSEvent) -> Bool {
        let buttons = ([backRow].compactMap { $0 } + rowButtons).filter { $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor }
        switch event.keyCode {
        case 53: goBack(); return true
        case 123: if navigation.count > 1 { goBack(); return true }; return false
        case 125, 126:
            guard !buttons.isEmpty else { return true }
            let current = buttons.firstIndex(where: { window?.firstResponder === $0 })
            let delta = event.keyCode == 125 ? 1 : -1
            let next = current.map { ($0 + delta + buttons.count) % buttons.count } ?? (delta == 1 ? 0 : buttons.count - 1)
            window?.makeFirstResponder(buttons[next])
            buttons[next].scrollToVisible(buttons[next].bounds)
            return true
        default: return false
        }
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) {
        if !handleNavigation(event) { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { goBack() }
}

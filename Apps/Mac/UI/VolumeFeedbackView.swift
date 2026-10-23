import AppKit
import QuartzCore

/// Noninteractive feedback for volume changes made while the controls are hidden.
final class SPVolumeFeedbackView: NSView {
    private enum G {
        static let width: CGFloat = 212
        static let height: CGFloat = 44
        static let topGap: CGFloat = 24
        static let hold: TimeInterval = 0.85
        static let fade: TimeInterval = 0.15
    }

    private let background = CALayer()
    private let track = CALayer()
    private let fill = CALayer()
    private let speaker = NSImageView()
    private let value = NSTextField(labelWithString: "")
    private let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        formatter.minimumFractionDigits = 0
        return formatter
    }()
    private var fadeWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var generation: UInt = 0
    private(set) var displayedPercent: Double = 0
    private(set) var displayedMuted = false
    private(set) var displayedSpeakerSymbol = ""

    var displayedText: String { value.stringValue }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let actions: [String: CAAction] = [
            "opacity": NSNull(), "position": NSNull(), "bounds": NSNull(),
            "backgroundColor": NSNull(), "cornerRadius": NSNull(),
        ]
        layer?.actions = actions
        for item in [background, track, fill] { item.actions = actions }
        background.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        background.cornerRadius = 10
        track.name = "sp.volume.feedback.track"
        track.backgroundColor = NSColor.white.withAlphaComponent(0.24).cgColor
        track.cornerRadius = 2
        fill.name = "sp.volume.feedback.fill"
        fill.backgroundColor = NSColor.white.cgColor
        fill.cornerRadius = 2
        layer?.addSublayer(background)
        background.addSublayer(track)
        track.addSublayer(fill)

        speaker.imageScaling = .scaleProportionallyDown
        speaker.contentTintColor = .white
        speaker.setAccessibilityElement(false)
        value.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        value.textColor = .white
        value.alignment = .right
        value.isSelectable = false
        value.lineBreakMode = .byClipping
        value.setAccessibilityElement(false)
        addSubview(speaker)
        addSubview(value)
        isHidden = true
        setAccessibilityIdentifier("sp.volumeFeedback")
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(L("settings.volume"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for item in [layer, background, track, fill] { item?.contentsScale = scale }
    }

    func place(in bounds: CGRect) {
        guard !bounds.isEmpty else { return }
        let width = min(G.width, max(0, bounds.width - 16))
        let height = min(G.height, max(0, bounds.height - 16))
        let topGap = min(G.topGap, max(8, (bounds.height - height) / 2))
        frame = CGRect(x: bounds.midX - width / 2,
                       y: bounds.maxY - height - topGap,
                       width: width, height: height).integral
        needsLayout = true
    }

    override func layout() {
        super.layout()
        speaker.frame = CGRect(x: 13, y: (bounds.height - 22) / 2, width: 22, height: 22)
        let labelWidth = max(39, ceil(value.intrinsicContentSize.width))
        value.frame = CGRect(x: bounds.maxX - 13 - labelWidth,
                             y: (bounds.height - 20) / 2,
                             width: labelWidth, height: 20)
        let trackX: CGFloat = 47
        let trackWidth = max(0, value.frame.minX - 11 - trackX)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.frame = bounds
        track.frame = CGRect(x: trackX, y: (bounds.height - 4) / 2,
                             width: trackWidth, height: 4)
        fill.frame = CGRect(x: 0, y: 0,
                            width: trackWidth * CGFloat(min(displayedPercent, 100) / 100),
                            height: 4)
        fill.isHidden = displayedPercent <= 0 || trackWidth <= 0
        CATransaction.commit()
    }

    func show(percent: Double, muted: Bool) {
        guard percent.isFinite else { return }
        let wasHidden = isHidden
        cancelPendingFade()
        let currentGeneration = generation
        displayedPercent = min(500, max(0, percent))
        displayedMuted = muted
        value.stringValue = percentFormatter.string(from: NSNumber(value: displayedPercent / 100)) ??
            String(format: "%.0f%%", displayedPercent)
        let symbol: String
        if muted || displayedPercent == 0 {
            symbol = "speaker.slash.fill"
        } else if displayedPercent < 34 {
            symbol = "speaker.wave.1.fill"
        } else if displayedPercent < 67 {
            symbol = "speaker.wave.2.fill"
        } else {
            symbol = "speaker.wave.3.fill"
        }
        if displayedSpeakerSymbol != symbol {
            displayedSpeakerSymbol = symbol
            speaker.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 18, weight: .medium))
        }
        layer?.removeAllAnimations()
        alphaValue = 1
        isHidden = false
        setAccessibilityValue(value.stringValue)
        needsLayout = true
        layoutSubtreeIfNeeded()

        if wasHidden && !reduceMotion {
            let entry = CABasicAnimation(keyPath: "opacity")
            entry.fromValue = 0
            entry.toValue = 1
            entry.duration = 0.08
            layer?.add(entry, forKey: "volumeEntry")
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
        layer?.removeAllAnimations()
        isHidden = true
        alphaValue = 1
        displayedPercent = 0
        displayedMuted = false
        value.stringValue = ""
        setAccessibilityValue("")
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

import AppKit
import QuartzCore

@MainActor
protocol PlayerChromePresenting: AnyObject {
    func render(_ presentation: ChromePresentation)
    func show()
    func hide()
    func layout(in parentBounds: NSRect)
    func cancelTransientInteraction()
}

enum SPT {

    static let scrimStops: [(CGFloat, CGFloat)] = [(0.84, 0.0), (0.76, 0.40), (0.62, 0.68), (0.26, 0.86), (0.0, 1.0)]
    static func w(_ white: CGFloat, _ a: CGFloat) -> NSColor { NSColor(white: white, alpha: a) }
    static let fgPrimary   = w(1, 1.00)

    static let turboAccentColor = NSColor(srgbRed: 1.0, green: 0xB6 / 255, blue: 0x5C / 255, alpha: 1)
    static let fgIcon      = w(1, 0.95)
    static let fgSecondary = w(1, 0.72)
    static let fillHover   = w(1, 0.16)
    static let trackRemain = w(1, 0.28)
    static let surfaceChip = w(0, 0.72)
    static let strokeChip  = w(1, 0.14)
    static let chipFill    = w(1, 0.15)
}

// Compact geometry keeps controls near the bottom and limits the scrim to
// roughly one fifth of a 720p window while fading its upper edge early.
private enum SPM {
    static let side: CGFloat = 20, bot: CGFloat = 16
    static let btnRow: CGFloat = 44, gapRT: CGFloat = 10, trackRow: CGFloat = 22
    static let btnMain: CGFloat = 44, btnAux: CGFloat = 32
    static let symAux: CGFloat = 17
    static let gapIn: CGFloat = 8, gapBtw: CGFloat = 24, gapTT: CGFloat = 12
    static let trackIdle: CGFloat = 4, trackHover: CGFloat = 7, knobD: CGFloat = 15
    static let scrimH: CGFloat = 150, maxW: CGFloat = 1120, timeW: CGFloat = 64
    static let flexibleChipMinW: CGFloat = 116, flexibleChipMaxW: CGFloat = 240
}

@inline(__always) private func noAnim(_ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    body()
    CATransaction.commit()
}

struct SPDamageBand: Equatable {
    static let partial: Int32 = 1
    static let none: Int32 = 2
    static let pending: Int32 = 3
    let cls: Int32
    let from: Double
    let until: Double
}
enum SPDamage {
    static let partialColor = NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.22, alpha: 0.62)
    static let noneColor = NSColor(calibratedRed: 1.0, green: 0.34, blue: 0.30, alpha: 0.42)

    static let pendingColor = NSColor(calibratedWhite: 0.0, alpha: 0.5)

    static func uiClass(bridge cls: Int32) -> Int32 {
        switch cls {
        case 2: return SPDamageBand.partial
        case 3: return SPDamageBand.none
        default: return 0
        }
    }
    static func bands(from snap: SPDamageSnapshot?) -> [SPDamageBand] {
        guard let snap else { return [] }
        var out: [SPDamageBand] = []
        snap.main.withUnsafeBytes { raw in
            for r in raw.bindMemory(to: SPDamageSpanRecord.self) {
                let ui = uiClass(bridge: r.cls)
                if ui == 0 { continue }
                out.append(SPDamageBand(cls: ui, from: Double(r.fromUs) / 1e6, until: Double(r.untilUs) / 1e6))
            }
        }
        snap.pending.withUnsafeBytes { raw in
            for r in raw.bindMemory(to: SPDamageSpanRecord.self) {
                out.append(SPDamageBand(cls: SPDamageBand.pending, from: Double(r.fromUs) / 1e6, until: Double(r.untilUs) / 1e6))
            }
        }
        return out
    }
    static func state(at seconds: Double, in bands: [SPDamageBand]) -> Int32 {
        for b in bands where seconds >= b.from && seconds < b.until { return b.cls }
        return 0
    }
}

final class SPIconButton: NSButton {
    private var hoverArea: NSTrackingArea?
    private var hovering = false
    private var keyboardFocused = false
    private var accessibilityFocused = false
    var showsSelection = false { didSet { refreshTint() } }
    var hasInteractionFocus: Bool { keyboardFocused || accessibilityFocused }
    // When nil, the button manages its own hover highlight.
    var onHoverChanged: ((NSButton, Bool) -> Void)?
    var onFocusChanged: ((Bool) -> Void)?
    var preservesKeyboardFocusOnClick = false

    init(symbol: String, pointSize: CGFloat, size: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        refusesFirstResponder = true
        setSymbol(symbol, pointSize: pointSize)
        contentTintColor = SPT.fgIcon
        wantsLayer = true
        layer?.cornerRadius = size / 2
    }
    required init?(coder: NSCoder) { fatalError() }

    private var symbolKey: (name: String, pointSize: CGFloat)?
    func setSymbol(_ name: String, pointSize: CGFloat) {

        if let k = symbolKey, k.name == name, k.pointSize == pointSize { return }
        symbolKey = (name, pointSize)
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        image = NSImage(systemSymbolName: name, accessibilityDescription: name)?
            .withSymbolConfiguration(cfg)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = hoverArea { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: .zero,
                               options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
                               owner: self)
        addTrackingArea(a)
        hoverArea = a
    }
    override func mouseEntered(with event: NSEvent) {
        hovering = true
        if let onHoverChanged { onHoverChanged(self, true) }
        else { noAnim { layer?.backgroundColor = SPT.fillHover.cgColor } }
        refreshTint()
    }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        if let onHoverChanged { onHoverChanged(self, false) }
        else { noAnim { layer?.backgroundColor = nil } }
        refreshTint()
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        keyboardFocused = true
        onFocusChanged?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        keyboardFocused = false
        onFocusChanged?(accessibilityFocused)
        return true
    }

    override func setAccessibilityFocused(_ focused: Bool) {
        super.setAccessibilityFocused(focused)
        accessibilityFocused = focused
        onFocusChanged?(focused || keyboardFocused)
    }

    override func mouseDown(with event: NSEvent) {
        guard preservesKeyboardFocusOnClick else {
            super.mouseDown(with: event)
            return
        }
        let previousResponder = window?.firstResponder
        let previouslyRefusedFocus = refusesFirstResponder
        refusesFirstResponder = true
        defer {
            refusesFirstResponder = previouslyRefusedFocus
            if previousResponder !== self, window?.firstResponder === self {
                window?.makeFirstResponder(previousResponder)
            }
        }
        super.mouseDown(with: event)
    }

    private func refreshTint() {
        contentTintColor = showsSelection || hovering ? SPT.fgPrimary : SPT.fgIcon
    }

}

final class SPPlaybackTimeButton: NSButton {
    var onWidthChanged: (() -> Void)?
    private(set) var showsRemaining = false
    private(set) var preferredWidth: CGFloat = 90
    private var elapsedSeconds = -1
    private var totalSeconds = -1
    private var keyboardFocused = false
    private var accessibilityFocused = false

    var hasInteractionFocus: Bool { keyboardFocused || accessibilityFocused }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .regularSquare
        alignment = .left
        imagePosition = .noImage
        refusesFirstResponder = false
        focusRingType = .exterior
        cell?.wraps = false
        cell?.usesSingleLineMode = true
        cell?.lineBreakMode = .byTruncatingMiddle
        target = self
        action = #selector(toggleTimeMode)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        configure(position: 0, duration: 0)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { !refusesFirstResponder }
    override var mouseDownCanMoveWindow: Bool { false }

    // Bounds keep malformed engine values away from Int conversions and the
    // clock formatter while covering media durations up to 68 years.
    static func normalizedSeconds(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return min(Double(Int32.max), max(0, seconds))
    }

    func configure(position: Double, duration: Double) {
        let total = Int(Self.normalizedSeconds(duration))
        let elapsed = total > 0 ? min(total, Int(Self.normalizedSeconds(position)))
            : Int(Self.normalizedSeconds(position))
        guard elapsed != elapsedSeconds || total != totalSeconds else { return }
        elapsedSeconds = elapsed
        totalSeconds = total
        updateTimeTitle()
    }

    @objc private func toggleTimeMode() {
        showsRemaining.toggle()
        updateTimeTitle()
    }

    private func updateTimeTitle() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let total = SPTimeText.clock(Double(max(0, totalSeconds)))
        let current = showsRemaining
            ? "−" + SPTimeText.clock(Double(max(0, totalSeconds - elapsedSeconds)))
            : SPTimeText.clock(Double(max(0, elapsedSeconds)))
        let title = NSMutableAttributedString(string: current, attributes: [
            .font: font, .foregroundColor: SPT.fgPrimary,
        ])
        title.append(NSAttributedString(string: " / " + total, attributes: [
            .font: font, .foregroundColor: SPT.fgSecondary,
        ]))
        attributedTitle = title
        let hint = showsRemaining ? L("chrome.time.showElapsed") : L("chrome.time.showRemaining")
        toolTip = title.string + "\n" + hint
        setAccessibilityLabel(hint)
        setAccessibilityValue(title.string)
        setAccessibilityHelp(hint)
        // Reserve the duration's digit count for both modes, so ordinary ticks
        // and the elapsed/remaining toggle do not shift adjacent controls.
        let widestCurrent = totalSeconds > 0 ? total : SPTimeText.clock(Double(max(0, elapsedSeconds)))
        let widestTitle = NSAttributedString(string: "−" + widestCurrent + " / " + total,
                                              attributes: [.font: font])
        let width = ceil(widestTitle.size().width) + 8
        if width != preferredWidth {
            preferredWidth = width
            onWidthChanged?()
        }
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        keyboardFocused = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        keyboardFocused = false
        return true
    }

    override func setAccessibilityFocused(_ focused: Bool) {
        super.setAccessibilityFocused(focused)
        accessibilityFocused = focused
    }

    override func mouseDown(with event: NSEvent) {
        let previousResponder = window?.firstResponder
        refusesFirstResponder = true
        defer {
            refusesFirstResponder = false
            if previousResponder !== self, window?.firstResponder === self {
                window?.makeFirstResponder(previousResponder)
            }
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if [UInt16(49), 36, 76].contains(event.keyCode),
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            if !event.isARepeat { performClick(nil) }
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if [UInt16(49), 36, 76].contains(event.keyCode) { return }
        super.keyUp(with: event)
    }
}

enum SPTurboPhase { case idle, charging, active }

final class SPPlayPauseButton: NSButton {
    private var hoverArea: NSTrackingArea?
    var onHoverChanged: ((NSButton, Bool) -> Void)? // Matches SPIconButton.
    private let iconContainer = CALayer()
    private let leftHalf = CAShapeLayer()
    private let rightHalf = CAShapeLayer()
    private var showsPause = false

    private var turboPhase: SPTurboPhase = .idle
    private var showsTurbo: Bool { turboPhase == .active }
    private var baseColor: NSColor = SPT.fgIcon
    private static let turboColor = SPT.turboAccentColor
    private enum Shape { case play, pause, turbo }

    // Local icon geometry aligned with the 22-point SF Symbol.
    private enum G {
        static let w: CGFloat = 16, h: CGFloat = 19 // Play-state bounds.
        static let barTh: CGFloat = 5.4             // Pause-bar thickness.
        static let stroke: CGFloat = 2.4            // Rounded outline width.
        static let mid: CGFloat = 7.4               // Triangle split position.
        static let dur: CFTimeInterval = 0.22
    }

    init(size: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        refusesFirstResponder = true
        wantsLayer = true
        layer?.cornerRadius = 8

        iconContainer.bounds = CGRect(x: 0, y: 0, width: G.w, height: G.h)
        iconContainer.position = CGPoint(x: size / 2, y: size / 2)
        iconContainer.actions = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull()]
        for l in [leftHalf, rightHalf] {
            l.frame = iconContainer.bounds
            l.lineWidth = G.stroke
            l.lineJoin = .round
            l.actions = ["path": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull()]
            iconContainer.addSublayer(l)
        }
        let (lc, rc) = Self.corners(.play)
        leftHalf.path = Self.quadPath(lc)
        rightHalf.path = Self.quadPath(rc)
        setIconColor(SPT.fgIcon)
        layer?.addSublayer(iconContainer)
        setAccessibilityLabel(L("menu.play"))
    }
    required init?(coder: NSCoder) { fatalError() }

    // Keep shape layers sharp when the backing scale changes.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let s = window?.backingScaleFactor ?? 2
        for l in [leftHalf, rightHalf] { l.contentsScale = s }
    }

    private func setIconColor(_ c: NSColor) {
        baseColor = c
        let applied = turboPhase == .idle ? c : Self.turboColor
        noAnim {
            for l in [leftHalf, rightHalf] {
                l.fillColor = applied.cgColor
                l.strokeColor = applied.cgColor
            }
        }
    }

    private func animateColor(to c: NSColor, duration: CFTimeInterval) {
        let target = c.cgColor
        for l in [leftHalf, rightHalf] {
            for key in ["fillColor", "strokeColor"] {
                let a = CABasicAnimation(keyPath: key)
                a.fromValue = (l.presentation() ?? l).value(forKeyPath: key)
                a.toValue = target
                a.duration = duration
                a.timingFunction = CAMediaTimingFunction(name: .easeIn)
                l.add(a, forKey: key)
            }
            noAnim {
                l.fillColor = target
                l.strokeColor = target
            }
        }
    }

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // All shapes use four points per half. Pause bars are horizontal in path
    // space and become vertical after the container rotation. Turbo is two
    // side-by-side triangles (each a quad with a collapsed tip), unrotated.
    private static func corners(_ shape: Shape) -> ([CGPoint], [CGPoint]) {
        let w = G.w, h = G.h
        if shape == .turbo {
            let th: CGFloat = 6.0            // Half-height of each chevron.
            let tipL = w / 2 + 1, tipR = w + 1 // Slight overlap keeps them one glyph.
            return ([CGPoint(x: 0, y: h / 2 - th), CGPoint(x: 0, y: h / 2 + th),
                     CGPoint(x: tipL, y: h / 2), CGPoint(x: tipL, y: h / 2)],
                    [CGPoint(x: w / 2, y: h / 2 - th), CGPoint(x: w / 2, y: h / 2 + th),
                     CGPoint(x: tipR, y: h / 2), CGPoint(x: tipR, y: h / 2)])
        }
        if shape == .pause {
            let cx = w / 2, cy = h / 2
            let x0 = cx - h / 2, x1 = cx + h / 2 // Bar length after rotation.
            let b = G.barTh
            let yBot = cy - w / 2, yTop = cy + w / 2 // Combined rotated width.
            return ([CGPoint(x: x0, y: yBot), CGPoint(x: x0, y: yBot + b),
                     CGPoint(x: x1, y: yBot + b), CGPoint(x: x1, y: yBot)],
                    [CGPoint(x: x0, y: yTop - b), CGPoint(x: x0, y: yTop),
                     CGPoint(x: x1, y: yTop), CGPoint(x: x1, y: yTop - b)])
        }
        let m = G.mid
        let half = (h / 2) * (1 - m / w) // Triangle half-height at the split.
        return ([CGPoint(x: 0, y: 0), CGPoint(x: 0, y: h),
                 CGPoint(x: m, y: h / 2 + half), CGPoint(x: m, y: h / 2 - half)],
                [CGPoint(x: m, y: h / 2 - half), CGPoint(x: m, y: h / 2 + half),
                 CGPoint(x: w, y: h / 2), CGPoint(x: w, y: h / 2)])
    }

    private static func quadPath(_ c: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        p.move(to: c[0])
        for q in c.dropFirst() { p.addLine(to: q) }
        p.closeSubpath()
        return p
    }

    func setPlaying(_ playing: Bool, animated: Bool) {
        guard playing != showsPause else { return }
        showsPause = playing
        setAccessibilityLabel(L(playing ? "menu.play.pause" : "menu.play"))

        guard turboPhase == .idle else { return }
        morph(animated: animated)
    }

    func setTurboPhase(_ phase: SPTurboPhase, chargeDuration: CFTimeInterval = 0.25) {
        guard phase != turboPhase else { return }
        let previous = turboPhase
        turboPhase = phase
        let motion = !Self.reduceMotion
        let c = iconContainer
        switch phase {
        case .charging:

            animateColor(to: Self.turboColor, duration: chargeDuration)
            guard motion else { return }
            let coil = CABasicAnimation(keyPath: "transform.scale")
            coil.fromValue = 1.0
            coil.toValue = 0.7
            coil.duration = chargeDuration
            coil.timingFunction = CAMediaTimingFunction(name: .easeIn)
            coil.fillMode = .forwards
            coil.isRemovedOnCompletion = false
            c.add(coil, forKey: "turboCoil")
            let tremble = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            tremble.values = [0, 0.04, -0.06, 0.08, -0.10, 0.13, -0.15, 0.17, -0.17, 0]
            tremble.duration = chargeDuration
            tremble.isAdditive = true
            tremble.calculationMode = .linear
            tremble.fillMode = .forwards
            tremble.isRemovedOnCompletion = false
            c.add(tremble, forKey: "turboTremble")
        case .active:
            c.removeAnimation(forKey: "turboCoil")
            c.removeAnimation(forKey: "turboTremble")
            morph(animated: true)
            setIconColor(baseColor)
            guard motion else { return }

            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 0.7
            spring.toValue = 1.0
            spring.mass = 1
            spring.stiffness = 260
            spring.damping = 8
            spring.initialVelocity = 14
            spring.duration = spring.settlingDuration
            c.add(spring, forKey: "turboSpring")

            let whip = CAKeyframeAnimation(keyPath: "transform.translation.x")
            whip.values = [-4, 5, -2, 0]
            whip.keyTimes = [0, 0.35, 0.7, 1]
            whip.duration = 0.4
            whip.isAdditive = true
            whip.timingFunctions = [CAMediaTimingFunction(name: .easeOut),
                                    CAMediaTimingFunction(name: .easeInEaseOut),
                                    CAMediaTimingFunction(name: .easeOut)]
            c.add(whip, forKey: "turboWhip")
        case .idle:
            c.removeAnimation(forKey: "turboCoil")
            c.removeAnimation(forKey: "turboTremble")
            animateColor(to: baseColor, duration: 0.15)
            morph(animated: true)
            guard motion else { return }

            let relax = CASpringAnimation(keyPath: "transform.scale")
            relax.fromValue = previous == .charging ? 0.7 : 1.12
            relax.toValue = 1.0
            relax.mass = 1
            relax.stiffness = 240
            relax.damping = 11
            relax.initialVelocity = previous == .charging ? 8 : 0
            relax.duration = relax.settlingDuration
            c.add(relax, forKey: "turboSpring")
        }
    }

    private func morph(animated: Bool) {
        let shape: Shape = showsTurbo ? .turbo : (showsPause ? .pause : .play)
        let (lc, rc) = Self.corners(shape)
        let lTo = Self.quadPath(lc)
        let rTo = Self.quadPath(rc)
        let targetAngle: CGFloat = shape == .pause ? -.pi / 2 : 0 // Rotate into pause.
        // Continue from presentation values during rapid toggles.
        let fromL = leftHalf.presentation()?.path ?? leftHalf.path
        let fromR = rightHalf.presentation()?.path ?? rightHalf.path
        let fromAngle: CGFloat = {
            let src = iconContainer.presentation() ?? iconContainer
            return (src.value(forKeyPath: "transform.rotation.z") as? NSNumber)
                .map { CGFloat($0.doubleValue) } ?? 0
        }()
        noAnim {
            leftHalf.path = lTo
            rightHalf.path = rTo
            iconContainer.transform = CATransform3DMakeRotation(targetAngle, 0, 0, 1)
        }
        guard animated else { return }
        let curve = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
        for (l, from, to): (CAShapeLayer, CGPath?, CGPath) in [(leftHalf, fromL, lTo),
                                                               (rightHalf, fromR, rTo)] {
            guard let from else { continue }
            let a = CABasicAnimation(keyPath: "path")
            a.fromValue = from
            a.toValue = to
            a.duration = G.dur
            a.timingFunction = curve
            a.isRemovedOnCompletion = true
            l.add(a, forKey: "morph")
        }
        // Settle an eight-percent rotational overshoot with the morph.
        let spin = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        let over = targetAngle + (targetAngle - fromAngle) * 0.08
        spin.values = [fromAngle, over, targetAngle]
        spin.keyTimes = [0, 0.72, 1]
        spin.timingFunctions = [CAMediaTimingFunction(name: .easeOut),
                                CAMediaTimingFunction(name: .easeInEaseOut)]
        spin.duration = G.dur
        spin.isRemovedOnCompletion = true
        iconContainer.add(spin, forKey: "spin")
    }

    // Match SPIconButton hover behavior.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = hoverArea { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: .zero,
                               options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
                               owner: self)
        addTrackingArea(a)
        hoverArea = a
    }
    override func mouseEntered(with event: NSEvent) {
        if let onHoverChanged { onHoverChanged(self, true) }
        else { noAnim { layer?.backgroundColor = SPT.fillHover.cgColor } }
        setIconColor(SPT.fgPrimary)
    }
    override func mouseExited(with event: NSEvent) {
        if let onHoverChanged { onHoverChanged(self, false) }
        else { noAnim { layer?.backgroundColor = nil } }
        setIconColor(SPT.fgIcon)
    }
}

// Skip button whose symbol spins once in the seek direction. Additive rotations
// let rapid clicks stack without changing the model transform.
final class SPSpinIconButton: NSButton {
    private var hoverArea: NSTrackingArea?
    var onHoverChanged: ((NSButton, Bool) -> Void)? // Matches SPIconButton.
    private let iconLayer = CALayer()
    private let symbolName: String
    private let symbolSize: CGFloat
    private var hovered = false

    init(symbol: String, accessibilityLabel: String,
         pointSize: CGFloat, size: CGFloat) {
        symbolName = symbol
        symbolSize = pointSize
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        refusesFirstResponder = true
        wantsLayer = true
        layer?.cornerRadius = 8
        iconLayer.actions = ["contents": NSNull(), "transform": NSNull(),
                             "position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(iconLayer)
        setAccessibilityLabel(accessibilityLabel)
        updateIcon()
    }
    required init?(coder: NSCoder) { fatalError() }

    // Pre-tint the symbol because layer contents ignore contentTintColor.
    private static func tinted(_ name: String, pointSize: CGFloat,
                               color: NSColor, scale: CGFloat) -> (CGImage, CGSize)? {
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        // The containing button owns the localized accessibility label.
        guard let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return nil }
        let sizePt = sym.size
        var rect = CGRect(origin: .zero, size: sizePt)
        let xform = NSAffineTransform()
        xform.scale(by: scale)
        guard let cg = sym.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: xform])
        else { return nil }
        return (cg, sizePt)
    }

    private func updateIcon() {
        let scale = window?.backingScaleFactor ?? 2
        let color = hovered ? SPT.fgPrimary : SPT.fgIcon
        guard let (img, sizePt) = Self.tinted(symbolName, pointSize: symbolSize,
                                              color: color, scale: scale) else { return }
        noAnim {
            iconLayer.contents = img
            iconLayer.contentsScale = scale
            iconLayer.bounds = CGRect(origin: .zero, size: sizePt)
            iconLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateIcon()
    }

    // A nil key keeps each additive rotation independent.
    func spin(clockwise: Bool) {
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.isAdditive = true
        a.fromValue = 0
        // Positive angles appear clockwise in this flipped button.
        a.toValue = clockwise ? 2 * CGFloat.pi : -2 * CGFloat.pi
        a.duration = 0.35
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        a.isRemovedOnCompletion = true
        iconLayer.add(a, forKey: nil)
    }

    // Match SPIconButton hover behavior.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = hoverArea { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: .zero,
                               options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
                               owner: self)
        addTrackingArea(a)
        hoverArea = a
    }
    override func mouseEntered(with event: NSEvent) {
        if let onHoverChanged { onHoverChanged(self, true) }
        else { noAnim { layer?.backgroundColor = SPT.fillHover.cgColor } }
        hovered = true
        updateIcon()
    }
    override func mouseExited(with event: NSEvent) {
        if let onHoverChanged { onHoverChanged(self, false) }
        else { noAnim { layer?.backgroundColor = nil } }
        hovered = false
        updateIcon()
    }
}

private final class SPChipButtonCell: NSButtonCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        super.titleRect(forBounds: rect.insetBy(dx: 8, dy: 0))
    }
    // A disabled button has AppKit recolour every run of the title before this
    // call, which would reveal the clear lamp slot, readout digits and padding
    // and leave the rolling digits brighter than the text. Draw the title with
    // its own colours; the disabled look comes from the chip's colours and alpha.
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect,
                            in controlView: NSView) -> NSRect {
        super.drawTitle(attributedTitle, withFrame: frame, in: controlView)
    }
    // AppKit highlights while the button is held and clears it when the
    // pointer leaves before release, which is exactly the press feedback.
    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            (controlView as? SPChipButton)?.pressChanged(isHighlighted)
        }
    }
}

final class SPChipButton: NSButton {
    private var lastText = ""
    private var textColor: NSColor = .white
    private struct AttributedTitleVariants {
        let full: NSAttributedString
        let compact: NSAttributedString
        let fullWidth: CGFloat
        let compactWidth: CGFloat
    }
    private var attributedTitleVariants: AttributedTitleVariants?
    private var usingCompactAttributedTitle: Bool?
    /// Cached title width. The row may reserve less space and truncate the
    /// visible title; its tooltip and accessibility description stay complete.
    private(set) var measuredTextWidth: CGFloat = 0

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 20))
        cell = SPChipButtonCell(textCell: "")
        isBordered = false
        bezelStyle = .regularSquare
        cell?.wraps = false
        cell?.usesSingleLineMode = true
        cell?.lineBreakMode = .byTruncatingTail
        refusesFirstResponder = true
        wantsLayer = true
        layer?.backgroundColor = SPT.chipFill.cgColor
        layer?.cornerRadius = 5
    }
    required init?(coder: NSCoder) { fatalError() }

    // ── Lamp ──────────────────────────────────────────────────────────
    // The title starts with an invisible slot of the same width as the old
    // status dot run, so text position and chip width are unchanged; the lamp
    // is drawn over that slot by its own layer.
    private(set) var lamp: SPChipLampDriver?
    private var lampHoverArea: NSTrackingArea?
    private var pressShade: CALayer?
    private var pressedVisual = false
    // Rolling digits drawn over a clear run of the title (same font, same
    // advance), so a changing number rolls instead of re-laying out the chip.
    private var readoutLabel: SPRollingDigitLabel?
    private var readoutText = ""
    private var readoutRange = NSRange(location: NSNotFound, length: 0)
    private static let readoutFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

    /// Leading slot for a lamp chip title: the former status dot, now clear.
    /// Callers follow it with "  " + title in the title font, as before.
    static func lampSlot() -> NSAttributedString {
        NSAttributedString(string: "●", attributes: [
            .font: NSFont.systemFont(ofSize: 8, weight: .regular),
            .foregroundColor: NSColor.clear, .baselineOffset: 1.5,
        ])
    }
    private static let lampDotAdvance: CGFloat =
        ("●" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 8, weight: .regular)]).width

    func installLamp(_ kind: SPChipLampModel.Kind) {
        guard lamp == nil, let layer else { return }
        let driver = SPChipLampDriver(kind: kind, host: self)
        layer.addSublayer(driver.layer)
        lamp = driver
        updateTrackingAreas()
        positionLamp()
    }

    func updateLamp(on: Bool, enabled: Bool, color: NSColor?, visible: Bool, animated: Bool) {
        guard let lamp else { return }
        lamp.update(on: on, enabled: enabled, color: color, visible: visible,
                    animated: animated && !isHiddenOrHasHiddenAncestor && window != nil)
    }

    override var attributedTitle: NSAttributedString {
        didSet { positionLamp(); positionReadout() }
    }

    /// Digits for the clear run at `range` of the full title. `nil` removes them.
    func setReadout(_ text: String?, range: NSRange, color: NSColor, animated: Bool) {
        guard let text, range.location != NSNotFound, let layer else {
            readoutText = ""
            readoutRange = NSRange(location: NSNotFound, length: 0)
            readoutLabel?.isHidden = true
            return
        }
        let label: SPRollingDigitLabel
        if let readoutLabel {
            label = readoutLabel
        } else {
            label = SPRollingDigitLabel(fontSize: 11, weight: .semibold, slots: 4)
            label.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
            label.updateContentsScale(window?.backingScaleFactor ?? 2)
            layer.addSublayer(label)
            readoutLabel = label
        }
        let previous = readoutText
        readoutText = text
        readoutRange = range
        positionReadout()
        let rolls = animated && !previous.isEmpty && previous != text &&
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let increasing = (Double(text) ?? 0) >= (Double(previous) ?? 0)
        label.setText(text, color: color.cgColor, increasing: increasing, animated: rolls)
    }

    /// Place the digits over their clear run; hide them when the displayed
    /// variant (for example the narrow one) does not contain that run.
    private func positionReadout() {
        guard let label = readoutLabel, let cell else { return }
        let title = attributedTitle
        let ns = title.string as NSString
        guard !readoutText.isEmpty, NSMaxRange(readoutRange) <= ns.length,
              ns.substring(with: readoutRange) == readoutText else {
            label.isHidden = true
            return
        }
        let rect = cell.titleRect(forBounds: bounds)
        let width = measuredTextWidth
        let minX = width <= rect.width ? rect.minX + (rect.width - width) / 2 : rect.minX
        let prefix = title.attributedSubstring(from: NSRange(location: 0, length: readoutRange.location)).size().width
        let digits = label.measure(readoutText)
        let height = ceil(Self.readoutFont.ascender - Self.readoutFont.descender)
        label.isHidden = false
        label.frame = CGRect(x: minX + prefix, y: bounds.midY - height / 2,
                             width: digits, height: height)
        label.relayoutSlots()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        positionLamp()
        positionReadout()
        if let pressShade { noAnim { pressShade.frame = bounds } }
    }

    /// Centre the lamp on the clear dot, wherever AppKit centres the title.
    private func positionLamp() {
        guard let lamp, let cell else { return }
        let rect = cell.titleRect(forBounds: bounds)
        let width = measuredTextWidth
        let minX = width <= rect.width ? rect.minX + (rect.width - width) / 2 : rect.minX
        lamp.setCenter(CGPoint(x: minX + Self.lampDotAdvance / 2, y: bounds.midY))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        lamp?.setScale(window?.backingScaleFactor ?? 2)
        readoutLabel?.updateContentsScale(window?.backingScaleFactor ?? 2)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        lamp?.setScale(window?.backingScaleFactor ?? 2)
        if window == nil { lamp?.clearHover() }
    }

    override func viewDidHide() {
        super.viewDidHide()
        lamp?.clearHover()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard lamp != nil else { return }
        if let a = lampHoverArea { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: .zero,
                               options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
                               owner: self)
        addTrackingArea(a)
        lampHoverArea = a
    }

    // Not forwarded: the chrome's own tracking areas never saw chip events.
    override func mouseEntered(with event: NSEvent) {
        guard event.trackingArea === lampHoverArea else { return }
        lamp?.setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea === lampHoverArea else { return }
        lamp?.setHovered(false)
    }

    /// Held: 96% scale and a light shade; release restores in 0.12 s. The
    /// toggle itself happens on release, through the button action.
    fileprivate func pressChanged(_ pressed: Bool) {
        guard lamp != nil, let layer, pressed != pressedVisual else { return }
        pressedVisual = pressed
        let shade: CALayer
        if let pressShade {
            shade = pressShade
        } else {
            shade = CALayer()
            shade.backgroundColor = NSColor.black.cgColor
            shade.cornerRadius = 5
            shade.opacity = 0
            shade.actions = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull()]
            noAnim { shade.frame = bounds }
            layer.addSublayer(shade)
            pressShade = shade
        }
        let duration: CFTimeInterval = pressed ? 0.08 : 0.12
        let curve = CAMediaTimingFunction(name: .easeOut)
        let fromOpacity = shade.presentation()?.opacity ?? shade.opacity
        noAnim { shade.opacity = pressed ? 0.14 : 0 }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fromOpacity
        fade.duration = duration
        fade.timingFunction = curve
        shade.add(fade, forKey: "opacity")
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        // View-backed layers pivot on their anchor point; scale about the centre.
        let s: CGFloat = pressed ? 0.96 : 1
        let px = bounds.width * (0.5 - layer.anchorPoint.x)
        let py = bounds.height * (0.5 - layer.anchorPoint.y)
        var t = CATransform3DMakeTranslation(px, py, 0)
        t = CATransform3DScale(t, s, s, 1)
        t = CATransform3DTranslate(t, -px, -py, 0)
        let fromTransform = layer.presentation()?.transform ?? layer.transform
        noAnim { layer.transform = t }
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = NSValue(caTransform3D: fromTransform)
        scale.duration = duration
        scale.timingFunction = curve
        layer.add(scale, forKey: "press")
    }

    func layoutWidth(min minWidth: CGFloat, max maxWidth: CGFloat = 240) -> CGFloat {
        var textWidth = measuredTextWidth
        if let variants = attributedTitleVariants {
            // Evaluate the complete title against the window's budget, not
            // the currently displayed short variant, so widening restores FPS.
            let budget = NSRect(x: 0, y: 0, width: maxWidth, height: bounds.height)
            let available = floor(cell?.titleRect(forBounds: budget).width ?? 0)
            textWidth = variants.fullWidth <= available ? variants.fullWidth : variants.compactWidth
        }
        return min(max(minWidth, textWidth + 16), maxWidth)
    }

    func setText(_ text: String, color: NSColor = .white) {
        guard text != lastText || color != textColor else { return }
        let textChanged = text != lastText
        attributedTitleVariants = nil
        usingCompactAttributedTitle = nil
        lastText = text
        textColor = color
        let title = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: color,
        ])
        attributedTitle = title
        if textChanged { measuredTextWidth = ceil(title.size().width) }
    }

    func setAttributedText(_ title: NSAttributedString, key: String,
                           compactTitle: NSAttributedString? = nil) {
        guard key != lastText else { return }
        lastText = key
        textColor = .clear
        let fullWidth = ceil(title.size().width)
        attributedTitleVariants = AttributedTitleVariants(
            full: title, compact: compactTitle ?? title, fullWidth: fullWidth,
            compactWidth: compactTitle.map { ceil($0.size().width) } ?? fullWidth)
        usingCompactAttributedTitle = nil
        fitAttributedTitleToWidth()
    }

    /// A readout is an indivisible run: when it does not fit, select the cached
    /// title without it. Only that remaining title may be tail-truncated by
    /// AppKit. Resizing does no title construction or text measurement.
    func fitAttributedTitleToWidth() {
        guard let variants = attributedTitleVariants else { return }
        // Use the same title rect as drawing (including the cell's 8 pt
        // insets), with conservative rounding on both sides of the fit test.
        let availableWidth = floor(cell?.titleRect(forBounds: bounds).width ?? 0)
        let compact = variants.fullWidth > availableWidth
        guard usingCompactAttributedTitle != compact else { return }
        usingCompactAttributedTitle = compact
        attributedTitle = compact ? variants.compact : variants.full
        measuredTextWidth = compact ? variants.compactWidth : variants.fullWidth
    }
}

/// CPU-drawn lamp image. Bounds are larger than the chip is tall so the
/// moon's glow can spill past the chip edge.
final class SPChipLampLayer: CALayer {
    var kind: SPChipLampModel.Kind = .moon
    var state = SPChipLampModel.Frame()
    var ballColor = NSColor(white: 1, alpha: 0.32).cgColor
    var trailColor = NSColor.systemGreen.cgColor
    var enabledLook = true

    override init() {
        super.init()
        actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(),
                   "hidden": NSNull(), "opacity": NSNull()]
    }
    override init(layer: Any) {
        if let l = layer as? SPChipLampLayer {
            kind = l.kind; state = l.state; ballColor = l.ballColor
            trailColor = l.trailColor; enabledLook = l.enabledLook
        }
        super.init(layer: layer)
    }
    required init?(coder: NSCoder) { fatalError() }

    private static let ballRadius: CGFloat = 2.5
    private static let orbitRadius: CGFloat = 3
    private static let moonRadius: CGFloat = 3

    override func draw(in ctx: CGContext) {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        switch kind {
        case .orbit: drawOrbit(ctx, c)
        case .moon: drawMoon(ctx, c)
        }
    }

    private func dot(_ ctx: CGContext, _ p: CGPoint, _ r: CGFloat, _ color: CGColor) {
        guard r > 0.05 else { return }
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    }

    // Screen-clockwise from the top: y grows upward in this context.
    private func point(_ c: CGPoint, _ r: CGFloat, _ angle: Double) -> CGPoint {
        CGPoint(x: c.x + r * CGFloat(cos(angle)), y: c.y - r * CGFloat(sin(angle)))
    }

    private func drawOrbit(_ ctx: CGContext, _ c: CGPoint) {
        let r = Self.orbitRadius * CGFloat(state.radius)
        let glide = state.trail * state.smoothness
        if r > 0.05, glide > 0.01 {
            for k in 1...10 {
                let a = state.theta - Double(k) * 0.018 * SPChipLampModel.orbitSpeed
                dot(ctx, point(c, r, a), Self.ballRadius - CGFloat(k) * 0.2,
                    trailColor.copy(alpha: 0.10 * CGFloat(glide)) ?? trailColor)
            }
        }
        dot(ctx, point(c, r, state.angle), Self.ballRadius, ballColor)
    }

    private func drawMoon(_ ctx: CGContext, _ c: CGPoint) {
        let R = Self.moonRadius
        guard enabledLook else {
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.26).cgColor)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
            dot(ctx, c, 2.2, NSColor(white: 1, alpha: 0.07).cgColor)
            return
        }
        let L = CGFloat(max(0, min(1, state.light)))
        let B = CGFloat(state.bloom)
        let over = CGFloat(1 - pow(1 - Double(max(0, min(1, (L - 0.35) / 0.65))), 3))
        // Glow once past the crescent; grows a little more while hovered and on.
        let glowAlpha = 0.8 * max(0, min(1, (L - 0.45) / 0.55)) * 0.55 * (1 + 0.3 * B)
        if glowAlpha > 0.001 {
            let gr = (3 + 10 * over) * 0.85 * (1 + 0.35 * B)
            let warm = NSColor(srgbRed: 1, green: 248 / 255, blue: 235 / 255, alpha: 1)
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [warm.withAlphaComponent(min(1, glowAlpha)).cgColor,
                                           warm.withAlphaComponent(0).cgColor] as CFArray,
                                  locations: [0, 1]) {
                ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c,
                                       endRadius: gr, options: [])
            }
        }
        // Lit disc, then the shadow disc sliding left: new → crescent → full.
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
        ctx.clip()
        dot(ctx, c, R, NSColor(srgbRed: 1, green: 252 / 255, blue: 244 / 255,
                               alpha: 0.25 + 0.75 * L).cgColor)
        let d = 6.4 * CGFloat(pow(Double(L), 1.2))
        dot(ctx, CGPoint(x: c.x - d, y: c.y), R + 0.15,
            NSColor(srgbRed: 40 / 255, green: 43 / 255, blue: 52 / 255, alpha: 0.92).cgColor)
        ctx.restoreGState()
        let ring = 0.45 * (1 - max(0, min(1, (L - 0.6) / 0.4)))
        if ring > 0.001 {
            ctx.setStrokeColor(NSColor(white: 1, alpha: ring).cgColor)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
        }
    }
}

@MainActor
private final class SPChipLampLinkProxy: NSObject {
    weak var driver: SPChipLampDriver?
    @objc func tick(_ l: CADisplayLink) {
        if let driver { driver.tick(l) } else { l.invalidate() }
    }
}

@MainActor
final class SPChipLampDriver {
    let layer = SPChipLampLayer()
    private var model: SPChipLampModel
    private weak var host: NSView?
    nonisolated(unsafe) private var link: CADisplayLink?
    // Ball colour tween (orbit): gray ↔ status colour, 0.3 s.
    private var colorFrom: [CGFloat] = [1, 1, 1, 0.32]
    private var colorTo: [CGFloat] = [1, 1, 1, 0.32]
    private var colorMix = SPLampTween(1)
    private var lastDrawn: SPChipLampModel.Frame?
    private var lastDrawnColor: [CGFloat] = []

    private static let size: CGFloat = 34
    private static let restColor: [CGFloat] = [1, 1, 1, 0.32]

    init(kind: SPChipLampModel.Kind, host: NSView) {
        model = SPChipLampModel(kind: kind)
        self.host = host
        layer.kind = kind
        layer.bounds = CGRect(x: 0, y: 0, width: Self.size, height: Self.size)
        layer.contentsScale = host.window?.backingScaleFactor ?? 2
        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        render(at: CACurrentMediaTime())
    }

    deinit { link?.invalidate() }

    func setCenter(_ p: CGPoint) {
        guard layer.position != p else { return }
        layer.position = p
    }

    func setScale(_ scale: CGFloat) {
        guard layer.contentsScale != scale else { return }
        layer.contentsScale = scale
        layer.setNeedsDisplay()
    }

    func update(on: Bool, enabled: Bool, color: NSColor?, visible: Bool, animated: Bool) {
        let t = CACurrentMediaTime()
        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        layer.isHidden = !visible
        layer.enabledLook = enabled || model.kind == .orbit
        let target = Self.components(color) ?? Self.restColor
        if target != colorTo {
            colorFrom = currentColor(at: t)
            colorTo = target
            colorMix = SPLampTween(0)
            colorMix.retarget(1, duration: animated && !model.reduceMotion ? 0.3 : 0, at: t)
        }
        model.setState(on: on, enabled: enabled, animated: animated && visible, at: t)
        kick(at: t)
    }

    func setHovered(_ hovered: Bool) {
        let t = CACurrentMediaTime()
        model.setHovered(hovered, at: t)
        kick(at: t)
    }

    func clearHover() {
        let t = CACurrentMediaTime()
        model.clearHover(at: t)
        colorMix.snap()
        link?.isPaused = true
        render(at: t)
    }

    private static func components(_ color: NSColor?) -> [CGFloat]? {
        guard let c = color?.usingColorSpace(.sRGB) else { return nil }
        return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
    }

    private func currentColor(at t: Double) -> [CGFloat] {
        let k = CGFloat(colorMix.value(at: t))
        return zip(colorFrom, colorTo).map { $0 + ($1 - $0) * k }
    }

    private func kick(at t: Double) {
        render(at: t)
        let busy = !model.isSettled(at: t) || !colorMix.isSettled(at: t)
        guard busy, !layer.isHidden, let host, host.window != nil else {
            link?.isPaused = true
            return
        }
        if link == nil {
            let proxy = SPChipLampLinkProxy()
            proxy.driver = self
            let l = host.displayLink(target: proxy, selector: #selector(SPChipLampLinkProxy.tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        link?.isPaused = false
    }

    fileprivate func tick(_ l: CADisplayLink) {
        guard let host, !host.isHiddenOrHasHiddenAncestor, host.window != nil else {
            clearHover()
            return
        }
        // A deactivated app gets no exit event from an active-in-app area.
        if model.isHovered, !NSApp.isActive { model.clearHover(at: CACurrentMediaTime()) }
        let t = CACurrentMediaTime()
        render(at: t)
        if model.isSettled(at: t), colorMix.isSettled(at: t) { l.isPaused = true }
    }

    private func render(at t: Double) {
        let f = model.frame(at: t)
        let rgba = currentColor(at: t)
        guard f != lastDrawn || rgba != lastDrawnColor else { return }
        lastDrawn = f
        lastDrawnColor = rgba
        layer.state = f
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        layer.ballColor = CGColor(colorSpace: space, components: rgba) ?? layer.ballColor
        layer.trailColor = CGColor(colorSpace: space, components: colorTo) ?? layer.trailColor
        layer.setNeedsDisplay()
    }
}

// Opening-state glimmer rendered entirely by Core Animation. The gradient moves
// within its bounds and is removed when opening ends. Reduced Motion keeps the
// static text fallback.
final class SPOpeningGlimmerView: NSView {
    static let preferredSize = NSSize(width: 140, height: 4)
    private let track = CALayer()
    private let sweep = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for l in [track, sweep] {
            l.actions = ["bounds": NSNull(), "position": NSNull(),
                         "opacity": NSNull()]
        }
        track.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        track.cornerRadius = SPOpeningGlimmerView.preferredSize.height / 2
        sweep.startPoint = CGPoint(x: 0, y: 0.5)
        sweep.endPoint = CGPoint(x: 1, y: 0.5)
        sweep.colors = [NSColor.white.withAlphaComponent(0).cgColor,
                        NSColor(srgbRed: 1, green: 0xEF / 255, blue: 0xC9 / 255,
                                alpha: 0.9).cgColor,
                        NSColor.white.withAlphaComponent(0).cgColor]
        sweep.locations = [0, 0.5, 1]
        sweep.cornerRadius = track.cornerRadius
        layer?.addSublayer(track)
        layer?.addSublayer(sweep)
    }
    required init?(coder: NSCoder) { fatalError() }

    // Forward clicks to PlayerView while the glimmer is visible.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        sweep.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sweep.removeAnimation(forKey: "glimmer")
        guard window != nil else { return }
        // Loop in one direction without implying measurable progress.
        let a = CABasicAnimation(keyPath: "locations")
        a.fromValue = [-0.6, -0.3, 0.0]
        a.toValue = [1.0, 1.3, 1.6]
        a.duration = 1.1
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        a.repeatCount = .infinity
        sweep.add(a, forKey: "glimmer")
    }
}

// Segmented volume control with a normal track and a boost extension. Reserve
// the full hit area so state changes do not move layout.

final class SPRollingDigitLabel: CALayer {
    private struct Slot {
        let a = CATextLayer()
        let b = CATextLayer()
        var activeIsA = true
        var char: Character?
        var active: CATextLayer { activeIsA ? a : b }
        var idle: CATextLayer { activeIsA ? b : a }
    }

    private var slots: [Slot] = []
    private var text = ""
    private var widthCache: [Character: CGFloat] = [:]
    private let font: NSFont
    private let fontSize: CGFloat

    init(fontSize: CGFloat = 9.5, weight: NSFont.Weight = .semibold, slots slotCount: Int = 4) {
        self.fontSize = fontSize
        font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: weight)
        super.init()
        for _ in 0..<slotCount {
            let slot = Slot()
            for t in [slot.a, slot.b] {
                t.font = font
                t.fontSize = fontSize
                t.alignmentMode = .center
                t.actions = ["bounds": NSNull(), "position": NSNull(),
                             "transform": NSNull(), "opacity": NSNull(),
                             "foregroundColor": NSNull(), "contents": NSNull()]
                t.opacity = 0
                addSublayer(t)
            }
            slots.append(slot)
        }
    }
    convenience override init() { self.init(fontSize: 9.5, weight: .semibold, slots: 4) }
    override init(layer: Any) {
        let src = layer as? SPRollingDigitLabel
        font = src?.font ?? NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
        fontSize = src?.fontSize ?? 9.5
        super.init(layer: layer)
    }
    required init?(coder: NSCoder) { fatalError() }

    func measure(_ text: String) -> CGFloat { text.reduce(0) { $0 + advance($1) } }

    func updateContentsScale(_ scale: CGFloat) {
        for s in slots { s.a.contentsScale = scale; s.b.contentsScale = scale }
    }

    private func advance(_ ch: Character) -> CGFloat {
        if let w = widthCache[ch] { return w }
        let w = (String(ch) as NSString).size(withAttributes: [.font: font]).width
        widthCache[ch] = w
        return w
    }

    /// `increasing` selects the roll direction. Changed digits cascade from
    /// right to left while unchanged characters remain stationary.
    func setText(_ next: String, color: CGColor, increasing: Bool, animated: Bool) {
        let prev = text
        text = next
        let chars = Array(next)
        let prevChars = Array(prev)
        let widths = chars.map { advance($0) }
        let total = widths.reduce(0, +)
        var x = (bounds.width - total) / 2
        let h = bounds.height
        // Right-align differences against the percent sign.
        let lenDelta = chars.count - prevChars.count
        var changedFromRight: [Int] = [] // Left-based indices, right to left.
        for i in stride(from: chars.count - 1, through: 0, by: -1) {
            let pi = i - lenDelta
            let prevCh: Character? = (pi >= 0 && pi < prevChars.count) ? prevChars[pi] : nil
            if prevCh != chars[i] { changedFromRight.append(i) }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<slots.count {
            guard i < chars.count else {
                // Hide surplus slots immediately when the value loses a digit.
                slots[i].active.opacity = 0
                slots[i].idle.opacity = 0
                slots[i].char = nil
                continue
            }
            let frame = CGRect(x: x, y: 0, width: widths[i], height: h)
            x = frame.maxX
            let ch = chars[i]
            let changed = changedFromRight.contains(i)
            if !changed {
                // Reposition unchanged characters without animation.
                slots[i].active.frame = frame
                slots[i].idle.frame = frame
                slots[i].active.string = String(ch)
                slots[i].active.foregroundColor = color
                slots[i].active.opacity = 1
                slots[i].char = ch
                continue
            }
            let outgoing = slots[i].active
            slots[i].activeIsA.toggle()
            let incoming = slots[i].active
            slots[i].char = ch
            incoming.frame = frame
            outgoing.frame = frame
            incoming.string = String(ch)
            incoming.foregroundColor = color
            incoming.opacity = 1
            outgoing.opacity = 0
            guard animated else { continue }
            // Start the cascade at the least-significant changed digit.
            let order = changedFromRight.firstIndex(of: i) ?? 0
            let delay = CFTimeInterval(order) * 0.025
            let dir: CGFloat = increasing ? 1 : -1
            addRoll(to: incoming, from: -5 * dir, overshoot: 0.9 * dir,
                    fadeIn: true, delay: delay)
            addRoll(to: outgoing, from: 0, exitTo: 5 * dir,
                    fadeIn: false, delay: delay)
        }
        CATransaction.commit()
    }

    func setColor(_ color: CGColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for s in slots where s.char != nil { s.active.foregroundColor = color }
        CATransaction.commit()
    }

    /// Reposition slots without animation after a bounds change.
    func relayoutSlots() {
        let chars = Array(text)
        guard !chars.isEmpty else { return }
        let widths = chars.map { advance($0) }
        var x = (bounds.width - widths.reduce(0, +)) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<min(slots.count, chars.count) {
            let frame = CGRect(x: x, y: 0, width: widths[i], height: bounds.height)
            x = frame.maxX
            slots[i].active.frame = frame
            slots[i].idle.frame = frame
        }
        CATransaction.commit()
    }

    private func addRoll(to l: CALayer, from: CGFloat = 0, overshoot: CGFloat = 0,
                         exitTo: CGFloat = 0, fadeIn: Bool, delay: CFTimeInterval) {
        let move = CAKeyframeAnimation(keyPath: "transform.translation.y")
        if fadeIn {
            move.values = [from, overshoot, 0]
            move.keyTimes = [0, 0.7, 1]
        } else {
            move.values = [0, exitTo]
            move.keyTimes = [0, 1]
        }
        move.duration = 0.16
        move.timingFunction = CAMediaTimingFunction(name: .easeOut)
        move.beginTime = delay > 0 ? CACurrentMediaTime() + delay : 0
        move.fillMode = .backwards
        move.isRemovedOnCompletion = true
        l.add(move, forKey: "roll")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fadeIn ? 0 : 1
        fade.toValue = fadeIn ? 1 : 0
        fade.duration = 0.16
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.beginTime = move.beginTime
        fade.fillMode = .backwards
        fade.isRemovedOnCompletion = true
        l.add(fade, forKey: "rollFade")
    }
}

final class SPVolumeControl: NSControl {
    var onBoostIntent: (() -> Void)?
    var onExpansionChanged: ((_ expanded: Bool, _ animated: Bool) -> Void)?
    var onInteractionChanged: (() -> Void)?

    private enum Metric {
        static let normalWidth: CGFloat = 80
        static let compactNormalWidth: CGFloat = 44
        static let boostWidth: CGFloat = 56
        static let knob: CGFloat = 13
        static let edgeHitPadding: CGFloat = 8
        static let boostExitResistance: CGFloat = 3
        static let height: CGFloat = 28
        static let trackY: CGFloat = 18
        static let collapseDelay: TimeInterval = 0.32
    }

    // Fixed sRGB ramp from white to warm orange. Gamma-space interpolation
    // avoids a gray midpoint and keeps boost color separate from app accents.
    private static let boostRampStops: [(r: CGFloat, g: CGFloat, b: CGFloat)] = [
        (1.0, 1.0, 1.0),                  // #FFFFFF
        (1.0, 0xEF / 255, 0xC9 / 255),    // #FFEFC9
        (1.0, 0xD9 / 255, 0x8E / 255),    // #FFD98E
        (1.0, 0xB6 / 255, 0x5C / 255),    // #FFB65C
        (1.0, 0x94 / 255, 0x40 / 255),    // #FF9440
    ]

    private static func boostColor(_ t: CGFloat) -> NSColor {
        let x = min(0.9999, max(0, t)) * CGFloat(boostRampStops.count - 1)
        let i = Int(x)
        let f = x - CGFloat(i)
        let a = boostRampStops[i], b = boostRampStops[i + 1]
        func mix(_ u: CGFloat, _ v: CGFloat) -> CGFloat {
            pow(pow(u, 2.2) * (1 - f) + pow(v, 2.2) * f, 1 / 2.2)
        }
        return NSColor(srgbRed: mix(a.r, b.r), green: mix(a.g, b.g),
                       blue: mix(a.b, b.b), alpha: 1)
    }

    /// Begin above 100 percent at a visible warm-color floor.
    private static let igniteFloor: CGFloat = 0.45

    private static func temperature(_ boostRatio: CGFloat) -> CGFloat {
        guard boostRatio > 0 else { return 0 }
        return igniteFloor + (1 - igniteFloor) * pow(boostRatio, 0.8)
    }

    /// Sample five stops to approximate a continuous gradient.
    private static func boostRampColors(from lo: CGFloat, to hi: CGFloat,
                                        alpha: CGFloat = 1) -> [CGColor] {
        (0...4).map {
            boostColor(lo + (hi - lo) * CGFloat($0) / 4)
                .withAlphaComponent(alpha).cgColor
        }
    }

    private let normalRemainLayer = CALayer()
    private let normalFillLayer = CALayer()
    private let boostRemainLayer = CAGradientLayer()
    private let boostFillLayer = CAGradientLayer()
    private let boundaryLayer = CALayer()
    private let knobLayer = CAGradientLayer()
    // Fade the percentage label when idle; roll digits for discrete changes.
    private let statusContainer = CALayer()
    private let statusLabel = SPRollingDigitLabel()
    private var statusValue = 100
    private var statusText = ""
    private var statusIdleWorkItem: DispatchWorkItem?
    private var statusTweenWorkItems: [DispatchWorkItem] = []
    private var dragJustStarted = false
    // Separate chevron layers support a staggered boost hint.
    private let hintChevronLow = CAShapeLayer()
    private let hintChevronHigh = CAShapeLayer()
    private let hintSweepLayer = CAGradientLayer()

    private(set) var volumePercent: Double = 100
    private(set) var boostUnlocked = false
    private(set) var isVisuallyExpanded = false
    private var boostPrompted = false
    private var compact = false
    private var hovering = false
    private var dragging = false
    private var accessibilityFocused = false
    private var keyboardFocused = false
    private var boostIntentSentForDrag = false
    private var boostDragAnchorX: CGFloat?
    private var boostDragAnchorValue: Double = 100
    private var boostExitReleaseX: CGFloat?
    private var trackingAreaRef: NSTrackingArea?
    private var collapseWorkItem: DispatchWorkItem?

    var normalVisualWidth: CGFloat {
        compact ? Metric.compactNormalWidth : Metric.normalWidth
    }
    var preferredVisualWidth: CGFloat {
        Metric.edgeHitPadding + normalVisualWidth + Metric.boostWidth
            + Metric.edgeHitPadding
    }
    var visibleVisualWidth: CGFloat {
        Metric.edgeHitPadding + normalVisualWidth + Metric.edgeHitPadding
            + (isVisuallyExpanded || boostPrompted ? Metric.boostWidth : 0)
    }
    var regularVisualWidth: CGFloat {
        Metric.edgeHitPadding + Metric.normalWidth + Metric.boostWidth
            + Metric.edgeHitPadding
    }
    var preferredVisualHeight: CGFloat { Metric.height }
    var trackCenterOffset: CGFloat { Metric.trackY }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        let geometryKeys = ["bounds", "position", "transform", "opacity",
                            "backgroundColor", "borderColor", "borderWidth",
                            "cornerRadius", "colors"]
        for l in [normalRemainLayer, normalFillLayer,
                  boostRemainLayer, boostFillLayer, boundaryLayer, knobLayer,
                  statusContainer, statusLabel,
                  hintChevronLow, hintChevronHigh, hintSweepLayer] {
            l.actions = Dictionary(uniqueKeysWithValues: geometryKeys.map { ($0, NSNull()) })
        }

        normalRemainLayer.backgroundColor = SPT.trackRemain.cgColor
        normalFillLayer.backgroundColor = NSColor.white.cgColor

        for g in [boostRemainLayer, boostFillLayer] {
            g.startPoint = CGPoint(x: 0, y: 0.5)
            g.endPoint = CGPoint(x: 1, y: 0.5)
            g.anchorPoint = CGPoint(x: 0, y: 0.5)
        }
        // Preview the same color ramp used by the active boost track.
        boostRemainLayer.colors = Self.boostRampColors(from: Self.igniteFloor,
                                                       to: 1, alpha: 0.28)
        boostRemainLayer.opacity = 0
        boostFillLayer.opacity = 0

        boundaryLayer.backgroundColor = NSColor.white.withAlphaComponent(0.72).cgColor
        boundaryLayer.opacity = 0

        knobLayer.colors = [NSColor.white.cgColor, NSColor.white.cgColor]
        knobLayer.startPoint = CGPoint(x: 0, y: 0)
        knobLayer.endPoint = CGPoint(x: 1, y: 1)
        knobLayer.cornerRadius = Metric.knob / 2
        knobLayer.borderColor = NSColor.white.withAlphaComponent(0.68).cgColor
        knobLayer.borderWidth = 0.5

        statusContainer.addSublayer(statusLabel)
        statusContainer.opacity = 0

        // Keep the three-stop sweep inside its own bounds without a mask.
        hintSweepLayer.startPoint = CGPoint(x: 0, y: 0.5)
        hintSweepLayer.endPoint = CGPoint(x: 1, y: 0.5)
        hintSweepLayer.colors = [NSColor.white.withAlphaComponent(0).cgColor,
                                 NSColor.white.withAlphaComponent(0.38).cgColor,
                                 NSColor.white.withAlphaComponent(0).cgColor]
        hintSweepLayer.locations = [0, 0.5, 1]
        hintSweepLayer.opacity = 0

        for chevron in [hintChevronLow, hintChevronHigh] {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: 5.5, y: 4.5))
            p.addLine(to: CGPoint(x: 11, y: 0))
            chevron.path = p
            chevron.bounds = CGRect(x: 0, y: 0, width: 11, height: 4.5)
            chevron.strokeColor = Self.boostHintColor.cgColor
            chevron.fillColor = nil
            chevron.lineWidth = 2
            chevron.lineCap = .round
            chevron.lineJoin = .round
            chevron.opacity = 0
        }

        for l in [normalRemainLayer, normalFillLayer,
                  boostRemainLayer, hintSweepLayer, boostFillLayer,
                  boundaryLayer, knobLayer, statusContainer,
                  hintChevronLow, hintChevronHigh] {
            layer?.addSublayer(l)
        }
        refreshHint(animated: false)

        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel(L("chrome.volume.a11y.label"))
        setAccessibilityMinValue(NSNumber(value: 0))
        updateAccessibility()
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    var keepsVolumeVisible: Bool {
        hovering || dragging || hasInteractionFocus
    }

    var hasInteractionFocus: Bool { accessibilityFocused || keyboardFocused }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        keyboardFocused = true
        onInteractionChanged?()
        updateStatusVisibility(animated: true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        keyboardFocused = false
        onInteractionChanged?()
        return true
    }

    override func setAccessibilityFocused(_ focused: Bool) {
        super.setAccessibilityFocused(focused)
        accessibilityFocused = focused
        onInteractionChanged?()
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 123, 125: _ = accessibilityPerformDecrement()
        case 124, 126: _ = accessibilityPerformIncrement()
        case 115: setValue(0, notify: true, directManipulation: true)
        case 119: setValue(maximumValue, notify: true, directManipulation: true)
        case 53: window?.makeFirstResponder(nil)
        default: super.keyDown(with: event)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let s = window?.backingScaleFactor ?? 2
        statusLabel.updateContentsScale(s)
        hintChevronLow.contentsScale = s
        hintChevronHigh.contentsScale = s
    }

    func setCompact(_ compact: Bool) {
        guard compact != self.compact else { return }
        self.compact = compact
        needsLayout = true
    }

    func setBoostUnlocked(_ unlocked: Bool) {
        guard unlocked != boostUnlocked else { return }
        boostUnlocked = unlocked
        if !unlocked, dragging {
            // A drag that returns to 100 percent cannot unlock again.
            boostIntentSentForDrag = true
        }
        if unlocked {
            setBoostPrompted(false)
        } else if volumePercent > 100 {
            setValue(100, notify: false, directManipulation: false)
        }
        refreshHint(animated: true)
        updateAccessibility()
    }

    func setBoostPrompted(_ prompted: Bool) {
        let next = prompted && !boostUnlocked && volumePercent >= 100
        guard next != boostPrompted else { return }
        let emphasize = next && !boostPrompted
        boostPrompted = next
        onExpansionChanged?(isVisuallyExpanded, !reduceMotion)
        refreshHint(animated: true, emphasize: emphasize)
        updateStatusVisibility(animated: true)
        updateAccessibility()
    }

    func setValue(_ pct: Double, animated: Bool = false) {
        setValue(pct, notify: false, directManipulation: !animated)
    }

    private var maximumValue: Double { boostUnlocked ? 500 : 100 }

    private func setValue(_ pct: Double, notify: Bool, directManipulation: Bool) {
        let next = max(0, min(maximumValue, pct.isFinite ? pct : 0))
        guard abs(next - volumePercent) > 0.0001 else { return }
        volumePercent = next
        if next < 100 { setBoostPrompted(false) }
        updateExpansionForValue(directManipulation: directManipulation)
        needsLayout = true
        layoutSubtreeIfNeeded()
        updateColors()
        refreshHint(animated: true)
        updateAccessibility()
        if notify { sendAction(action, to: target) }
    }

    private func updateExpansionForValue(directManipulation: Bool) {
        if volumePercent > 100 {
            collapseWorkItem?.cancel()
            collapseWorkItem = nil
            // Pointer values track directly; only the first expansion animates.
            setExpanded(true, animated: !directManipulation || dragging)
        } else if isVisuallyExpanded {
            if dragging { return }
            scheduleCollapse(delay: directManipulation ? 0.18 : Metric.collapseDelay)
        }
    }

    private func scheduleCollapse(delay: TimeInterval) {
        collapseWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.volumePercent <= 100, !self.dragging else { return }
            self.setExpanded(false, animated: true)
        }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func setExpanded(_ expanded: Bool, animated: Bool) {
        guard expanded != isVisuallyExpanded else { return }
        isVisuallyExpanded = expanded
        if expanded { setBoostPrompted(false) }
        onExpansionChanged?(expanded, animated && !reduceMotion)
        needsLayout = true
        layoutSubtreeIfNeeded()
        updateBoostAppearance(animated: animated)
    }

    override func layout() {
        super.layout()
        let trackX = Metric.edgeHitPadding
        let normalW = normalVisualWidth
        let boundaryX = trackX + normalW
        let trackY = Metric.trackY
        let trackH: CGFloat = dragging ? 7 : (hovering ? 6 : 4)
        let normalRatio = CGFloat(max(0, min(1, volumePercent / 100)))
        let boostRatio = CGFloat(max(0, min(1, (volumePercent - 100) / 400)))
        let knobX = volumePercent <= 100
            ? trackX + normalW * normalRatio
            : boundaryX + Metric.boostWidth * boostRatio

        noAnim {
            normalRemainLayer.frame = CGRect(x: trackX, y: trackY - trackH / 2,
                                             width: normalW, height: trackH)
            normalRemainLayer.cornerRadius = trackH / 2
            normalFillLayer.frame = CGRect(x: trackX, y: trackY - trackH / 2,
                                           width: normalW * normalRatio, height: trackH)
            normalFillLayer.cornerRadius = trackH / 2

            boostRemainLayer.bounds = CGRect(x: 0, y: 0,
                                             width: Metric.boostWidth, height: trackH)
            boostRemainLayer.position = CGPoint(x: boundaryX, y: trackY)
            boostRemainLayer.cornerRadius = trackH / 2
            boostFillLayer.bounds = CGRect(x: 0, y: 0,
                                           width: Metric.boostWidth * boostRatio,
                                           height: trackH)
            boostFillLayer.position = CGPoint(x: boundaryX, y: trackY)
            boostFillLayer.cornerRadius = trackH / 2

            boundaryLayer.frame = CGRect(x: boundaryX - 0.5, y: trackY - 6,
                                         width: 1, height: 12)
            knobLayer.frame = CGRect(x: knobX - Metric.knob / 2,
                                     y: trackY - Metric.knob / 2,
                                     width: Metric.knob, height: Metric.knob)

            statusContainer.frame = CGRect(x: trackX, y: 0, width: normalW, height: 11)
            if !NSEqualRects(statusLabel.frame, statusContainer.bounds) {
                statusLabel.frame = statusContainer.bounds
                statusLabel.relayoutSlots()
            }
            hintSweepLayer.frame = CGRect(x: boundaryX, y: trackY - trackH / 2,
                                          width: Metric.boostWidth, height: trackH)
            hintSweepLayer.cornerRadius = trackH / 2
            let hintCX = boundaryX + Metric.boostWidth / 2
            // Center the stacked upward chevrons on the track.
            hintChevronLow.position = CGPoint(x: hintCX, y: trackY - 2.75)
            hintChevronHigh.position = CGPoint(x: hintCX, y: trackY + 2.75)
        }
    }

    private func updateColors() {
        let boostRatio = CGFloat(max(0, min(1, (volumePercent - 100) / 400)))
        let temp = Self.temperature(boostRatio)
        let current = Self.boostColor(temp)
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        noAnim {
            // Fill from the warm floor to the current boost color.
            boostFillLayer.colors = Self.boostRampColors(from: Self.igniteFloor,
                                                         to: temp)
            knobLayer.colors = volumePercent > 100
                ? [Self.boostColor(max(Self.igniteFloor, temp - 0.2)).cgColor,
                   current.cgColor]
                : [NSColor.white.cgColor, NSColor.white.cgColor]
            knobLayer.borderWidth = highContrast ? 1.5 : 0.5
        }
        let statusColor = volumePercent > 100
            ? current.cgColor
            : NSColor.white.withAlphaComponent(highContrast ? 1 : 0.82).cgColor
        setStatusValue(Int(volumePercent.rounded()), color: statusColor)
        updateStatusVisibility(animated: true, changed: true)
    }

    // Percentage label visibility and digit transitions.

    /// Show while interacting, boosted, or prompted, then fade after 0.9 seconds.
    private var statusShouldShow: Bool {
        keepsVolumeVisible || volumePercent > 100 || boostPrompted
    }

    private func updateStatusVisibility(animated: Bool, changed: Bool = false) {
        // Offscreen assignments do not reveal the label.
        if changed, window != nil, statusContainer.opacity == 0, !statusShouldShow {
            // Reveal keyboard-driven changes before starting the idle timer.
            setOpacity(statusContainer, to: 1, animated: animated)
        } else if statusShouldShow {
            setOpacity(statusContainer, to: 1, animated: animated)
        }
        statusIdleWorkItem?.cancel()
        if statusShouldShow { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.statusShouldShow else { return }
            self.setOpacity(self.statusContainer, to: 0, animated: true)
        }
        statusIdleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    /// Roll discrete changes by digit. Dragging, hidden state, and Reduced Motion
    /// update immediately; a large initial click uses two intermediate values.
    private func setStatusValue(_ value: Int, color: CGColor) {
        let text = "\(value)%"
        guard text != statusText else {
            statusLabel.setColor(color)
            return
        }
        let previous = statusValue
        statusValue = value
        statusText = text
        cancelStatusTween()
        let silent = reduceMotion || statusContainer.opacity == 0
        let bigJumpOnPress = dragJustStarted && abs(value - previous) >= 15
        if silent || (dragging && !bigJumpOnPress) {
            statusLabel.setText(text, color: color,
                                increasing: value > previous, animated: false)
            return
        }
        if bigJumpOnPress {
            rollStatusValue(from: previous, to: value, color: color)
            return
        }
        statusLabel.setText(text, color: color,
                            increasing: value > previous, animated: true)
    }

    /// Animate two ease-out intermediate values at 45-millisecond intervals.
    private func rollStatusValue(from: Int, to: Int, color: CGColor) {
        let steps: [Double] = [0.45, 0.8, 1.0]
        var last = from
        for (i, t) in steps.enumerated() {
            let eased = 1 - (1 - t) * (1 - t)
            let v = from + Int((Double(to - from) * eased).rounded())
            guard v != last else { continue }
            let prev = last
            last = v
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.statusText = "\(v)%"
                self.statusValue = v
                self.statusLabel.setText("\(v)%", color: color,
                                         increasing: v > prev, animated: true)
            }
            statusTweenWorkItems.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.045,
                                          execute: work)
        }
    }

    private func cancelStatusTween() {
        for w in statusTweenWorkItems { w.cancel() }
        statusTweenWorkItems.removeAll()
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // Use the boost ramp's amber stop for hint chevrons.
    private static let boostHintColor = NSColor(srgbRed: 1.0,
                                                 green: 0xB6 / 255,
                                                 blue: 0x5C / 255,
                                                 alpha: 1)

    private func updateBoostAppearance(animated: Bool) {
        // Keep the preview track visible while prompted but collapsed.
        let target: Float = isVisuallyExpanded ? 1 : (boostPrompted ? 0.5 : 0)
        for l in [boostRemainLayer, boundaryLayer] {
            setOpacity(l, to: target, animated: animated)
        }
        setOpacity(boostFillLayer, to: (isVisuallyExpanded && volumePercent > 100) ? 1 : 0,
                   animated: animated)

        guard isVisuallyExpanded, animated, !reduceMotion else { return }
        let reveal = CABasicAnimation(keyPath: "transform.scale.x")
        reveal.fromValue = 0.001
        reveal.toValue = 1
        reveal.duration = 0.20
        reveal.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
        reveal.isRemovedOnCompletion = true
        boostRemainLayer.add(reveal, forKey: "boostReveal")
        boostFillLayer.add(reveal, forKey: "boostReveal")

        let pop = CABasicAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.78
        pop.toValue = 1
        pop.duration = 0.18
        pop.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
        pop.isRemovedOnCompletion = true
        knobLayer.add(pop, forKey: "boostEntry")
    }

    private func setOpacity(_ targetLayer: CALayer, to value: Float, animated: Bool) {
        let from = targetLayer.presentation()?.opacity ?? targetLayer.opacity
        noAnim { targetLayer.opacity = value }
        guard animated, !reduceMotion, abs(from - value) > 0.001 else {
            targetLayer.removeAnimation(forKey: "stateOpacity")
            return
        }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = value
        a.duration = value > from ? 0.17 : 0.12
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        a.isRemovedOnCompletion = true
        targetLayer.add(a, forKey: "stateOpacity")
    }

    private var isAtBoostBoundary: Bool {
        !boostUnlocked && volumePercent >= 100
    }

    private func refreshHint(animated: Bool, emphasize: Bool = false) {
        // Show text only after an explicit attempt to cross the boundary.
        toolTip = boostPrompted && isAtBoostBoundary
            ? L("chrome.volume.boost.prompt") : nil
        updateHintAppearance(animated: animated, emphasize: emphasize)
    }

    // Hover gives a subtle hint; a boundary attempt reveals the full prompt.
    private func updateHintAppearance(animated: Bool, emphasize: Bool = false) {
        let target: Float
        if boostPrompted {
            target = 1
        } else if isAtBoostBoundary && hovering {
            target = 0.10
        } else {
            target = 0
        }

        // Prompt state controls the preview; expansion controls full intensity.
        if !isVisuallyExpanded {
            let ghost: Float = boostPrompted ? 0.5 : 0
            setOpacity(boostRemainLayer, to: ghost, animated: animated)
            setOpacity(boundaryLayer, to: ghost, animated: animated)
        }

        let chevrons = [hintChevronLow, hintChevronHigh]
        if emphasize, animated, !reduceMotion {
            // Stagger the chevrons by 60 milliseconds with a short overshoot.
            for (i, c) in chevrons.enumerated() {
                c.removeAnimation(forKey: "hintFade")
                c.removeAnimation(forKey: "hintRise")
                noAnim { c.opacity = target }
                let begin = CACurrentMediaTime() + Double(i) * 0.06
                let rise = CAKeyframeAnimation(keyPath: "transform.translation.y")
                rise.values = [-4, 0.8, 0]
                rise.keyTimes = [0, 0.7, 1]
                rise.duration = 0.22
                rise.timingFunction = CAMediaTimingFunction(name: .easeOut)
                rise.beginTime = begin
                rise.fillMode = .backwards
                rise.isRemovedOnCompletion = true
                c.add(rise, forKey: "hintRise")
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = 0.18
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                fade.beginTime = begin
                fade.fillMode = .backwards
                fade.isRemovedOnCompletion = true
                c.add(fade, forKey: "hintFade")
            }
            // Defer the sweep until the key or pointer is released.
            return
        }
        for c in chevrons {
            // Sample presentation values before replacing active animations.
            let from = c.presentation()?.opacity ?? c.opacity
            c.removeAnimation(forKey: "hintFade")
            c.removeAnimation(forKey: "hintRise")
            noAnim { c.opacity = target }
            guard animated, !reduceMotion, abs(from - target) > 0.001 else { continue }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue = target
            fade.duration = target > from ? 0.16 : 0.12
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fade.isRemovedOnCompletion = true
            c.add(fade, forKey: "hintFade")
        }
    }

    /// Play the one-shot sweep when a prompted interaction is released.
    func playBoostInvitation() {
        guard boostPrompted, !boostUnlocked, !reduceMotion else { return }
        runHintSweep()
    }

    /// Move a one-shot three-stop highlight through the preview track.
    private func runHintSweep() {
        hintSweepLayer.removeAnimation(forKey: "sweep")
        hintSweepLayer.removeAnimation(forKey: "sweepFade")
        let travel = CABasicAnimation(keyPath: "locations")
        travel.fromValue = [-0.6, -0.3, 0]
        travel.toValue = [1, 1.3, 1.6]
        travel.duration = 0.35
        travel.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        travel.isRemovedOnCompletion = true
        hintSweepLayer.add(travel, forKey: "sweep")
        let flash = CAKeyframeAnimation(keyPath: "opacity")
        flash.values = [0, 1, 1, 0]
        flash.keyTimes = [0, 0.25, 0.75, 1]
        flash.duration = 0.35
        flash.isRemovedOnCompletion = true
        hintSweepLayer.add(flash, forKey: "sweepFade")
    }

    private func updateAccessibility() {
        let pct = Int(volumePercent.rounded())
        let valueText = volumePercent > 100
            ? "\(pct)% · \(L("chrome.volume.boost.active"))"
            : "\(pct)%"
        setAccessibilityValue(NSNumber(value: volumePercent))
        setAccessibilityValueDescription(valueText)
        setAccessibilityMaxValue(NSNumber(value: maximumValue))
        if boostPrompted && isAtBoostBoundary {
            setAccessibilityHelp(L("chrome.volume.boost.prompt"))
        } else if volumePercent >= 500 {
            setAccessibilityHelp(L("chrome.volume.boost.max"))
        } else if volumePercent > 100 {
            setAccessibilityHelp(L("chrome.volume.boost.active"))
        } else {
            setAccessibilityHelp(nil)
        }
    }

    private func sendBoostIntentIfNeeded() {
        guard !boostUnlocked else { return }
        setBoostPrompted(true)
        onBoostIntent?()
    }

    private func value(at x: CGFloat) -> Double {
        let normalW = normalVisualWidth
        let trackX = x - Metric.edgeHitPadding
        if trackX <= normalW || !boostUnlocked {
            return max(0, min(100, Double(trackX / max(normalW, 1)) * 100))
        }
        let boostRatio = max(0, min(1, (trackX - normalW) / Metric.boostWidth))
        return 100 + Double(boostRatio) * 400
    }

    /// Apply three points of resistance at 100 percent, then map continuously
    /// through the normal range.
    private func applyBoostExitValue(_ x: CGFloat, boundaryX: CGFloat) {
        let releaseX = boundaryX - Metric.boostExitResistance
        boostExitReleaseX = releaseX
        // Once exit begins, this gesture cannot re-enter boost.
        boostIntentSentForDrag = true
        applyPostBoostExitValue(x, releaseX: releaseX)
    }

    private func applyPostBoostExitValue(_ x: CGFloat, releaseX: CGFloat) {
        if x >= releaseX {
            setValue(100, notify: true, directManipulation: true)
            return
        }
        let normalStartX = Metric.edgeHitPadding
        let ratio = (x - normalStartX) / max(releaseX - normalStartX, 1)
        setValue(Double(max(0, min(1, ratio))) * 100,
                 notify: true, directManipulation: true)
    }

    private func applyPointerValue(_ x: CGFloat) {
        if let releaseX = boostExitReleaseX {
            applyPostBoostExitValue(x, releaseX: releaseX)
            return
        }
        if boostUnlocked, let anchorX = boostDragAnchorX {
            // Anchor an unlocking drag at 105 percent to avoid a layout jump.
            let delta = Double((x - anchorX) / Metric.boostWidth) * 400
            let candidate = boostDragAnchorValue + delta
            if candidate > 100 {
                setValue(candidate, notify: true, directManipulation: true)
            } else {
                let boundaryX = anchorX
                    + CGFloat((100 - boostDragAnchorValue) / 400) * Metric.boostWidth
                applyBoostExitValue(x, boundaryX: boundaryX)
            }
            return
        }
        if boostUnlocked {
            let candidate = value(at: x)
            if candidate > 100 {
                setValue(candidate, notify: true, directManipulation: true)
            } else {
                applyBoostExitValue(x,
                                    boundaryX: Metric.edgeHitPadding + normalVisualWidth)
            }
            return
        }
        let trackX = x - Metric.edgeHitPadding
        if !boostUnlocked && volumePercent >= 100 && trackX > normalVisualWidth + 4 {
            if !boostIntentSentForDrag {
                boostIntentSentForDrag = true
                sendBoostIntentIfNeeded()
                if boostUnlocked {
                    boostDragAnchorX = x
                    boostDragAnchorValue = volumePercent
                }
            }
            return
        }
        setValue(value(at: x), notify: true, directManipulation: true)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = trackingAreaRef { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: .zero,
                               options: [.activeInActiveApp, .inVisibleRect,
                                         .mouseEnteredAndExited], owner: self)
        addTrackingArea(a)
        trackingAreaRef = a
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        onInteractionChanged?()
        needsLayout = true
        refreshHint(animated: true)
        updateStatusVisibility(animated: true)
    }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        onInteractionChanged?()
        if !dragging { needsLayout = true }
        refreshHint(animated: true)
        updateStatusVisibility(animated: true)
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        dragging = true
        onInteractionChanged?()
        boostIntentSentForDrag = false
        boostDragAnchorX = nil
        boostExitReleaseX = nil
        needsLayout = true
        updateStatusVisibility(animated: true)
        // Animate a large initial jump; subsequent drag events update directly.
        dragJustStarted = true
        applyPointerValue(convert(event.locationInWindow, from: nil).x)
        dragJustStarted = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        applyPointerValue(convert(event.locationInWindow, from: nil).x)
    }
    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        applyPointerValue(convert(event.locationInWindow, from: nil).x)
        dragging = false
        onInteractionChanged?()
        boostDragAnchorX = nil
        boostExitReleaseX = nil
        needsLayout = true
        updateStatusVisibility(animated: true)
        playBoostInvitation() // Sweep after a prompted drag is released.
        if volumePercent <= 100, isVisuallyExpanded { scheduleCollapse(delay: 0.18) }
    }

    // Clear gesture-local exit state when mouseUp may not arrive.
    func cancelInteraction() {
        guard dragging else { return }
        dragging = false
        onInteractionChanged?()
        boostIntentSentForDrag = false
        boostDragAnchorX = nil
        boostExitReleaseX = nil
        needsLayout = true
        cancelStatusTween()
        updateStatusVisibility(animated: true)
        if volumePercent <= 100, isVisuallyExpanded { scheduleCollapse(delay: 0.18) }
    }

    override func accessibilityPerformIncrement() -> Bool {
        guard isEnabled else { return false }
        if !boostUnlocked, volumePercent >= 100 {
            let wasPrompted = boostPrompted
            sendBoostIntentIfNeeded()
            if !wasPrompted, boostPrompted {
                NSAccessibility.post(
                    element: NSApplication.shared,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: L("chrome.volume.boost.prompt"),
                        .priority: NSAccessibilityPriorityLevel.high.rawValue
                    ])
            }
            return true
        }
        setValue(volumePercent + 5, notify: true, directManipulation: true)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        guard isEnabled else { return false }
        setValue(volumePercent - 5, notify: true, directManipulation: true)
        return true
    }
}

/// One continuous hover region covers the speaker, the gap and the slider.
/// Clipping the rail rather than hiding it preserves its keyboard and AX path.
final class SPVolumeHoverView: NSView {
    var onExpansionChanged: ((_ animated: Bool) -> Void)?
    private(set) var isExpanded = false
    private let muteButton: SPIconButton
    private let slider: SPVolumeControl
    private var hovering = false
    private var speakerFocused = false
    private var trackingAreaRef: NSTrackingArea?
    private var collapseWorkItem: DispatchWorkItem?
    private let sliderGap: CGFloat = 4

    init(muteButton: SPIconButton, slider: SPVolumeControl) {
        self.muteButton = muteButton
        self.slider = slider
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(muteButton)
        addSubview(slider)
        setAccessibilityElement(false)
        muteButton.refusesFirstResponder = false
        muteButton.preservesKeyboardFocusOnClick = true
        muteButton.nextKeyView = slider
        muteButton.onFocusChanged = { [weak self] focused in
            self?.speakerFocused = focused
            self?.refreshExpansion()
        }
        slider.onInteractionChanged = { [weak self] in self?.refreshExpansion() }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }

    var keepsControlsVisible: Bool {
        hovering || speakerFocused || slider.keepsVolumeVisible
    }

    var hasFocusedControl: Bool { speakerFocused || slider.hasInteractionFocus }

    var preferredVisualWidth: CGFloat {
        SPM.btnAux + (isExpanded ? sliderGap + slider.visibleVisualWidth : 0)
    }

    override func layout() {
        super.layout()
        muteButton.frame = NSRect(x: 0, y: (bounds.height - SPM.btnAux) / 2,
                                  width: SPM.btnAux, height: SPM.btnAux)
        slider.frame = NSRect(x: SPM.btnAux + sliderGap,
                              y: bounds.midY - slider.trackCenterOffset,
                              width: slider.preferredVisualWidth,
                              height: slider.preferredVisualHeight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingAreaRef { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.activeInActiveApp, .inVisibleRect,
                                            .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        refreshExpansion()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        refreshExpansion()
    }

    private func refreshExpansion() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        if keepsControlsVisible {
            setExpanded(true, animated: true)
            return
        }
        // The grace period also bridges a pointer crossing during relayout.
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.keepsControlsVisible else { return }
            self.setExpanded(false, animated: true)
        }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: work)
    }

    private func setExpanded(_ expanded: Bool, animated: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        onExpansionChanged?(animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
}

// Layer-backed progress control with idle, hover, and drag states. The track
// grows from 4 to 7 points and forms a smooth bulge near the pointer.
final class SPProgressView: NSView {

    var interactionLocked = false
    var onBegan: ((Double) -> Void)?
    var onScrub: ((Double) -> Void)?
    var onEnded: ((Double, Bool) -> Void)?

    enum HoverIntent { case moved, movedNoRequest, commit }
    var onHover: ((CGFloat?, Double, HoverIntent) -> Void)?

    private let remainLayer = CAShapeLayer()
    private let fillLayer = CAShapeLayer()
    private let knobLayer = CALayer()
    private let bufferedBaseLayer = CAShapeLayer()
    private let bufferedLayer = CAShapeLayer()
    private let bufferedMask = CAShapeLayer()
    private let bufferedPlayedLayer = CAShapeLayer()
    private var bufferedRanges: [ClosedRange<Double>] = []
    private var showsBufferedRanges = false

    private let damagePartialLayer = CAShapeLayer()
    private let damageNoneLayer = CAShapeLayer()
    private let damagePendingLayer = CAShapeLayer()
    private var damageBands: [SPDamageBand] = []
    private var damageDuration: Double = 0
    private var value: Double = 0        // 0..1
    private var dragging = false
    private var moved = false
    private var downX: CGFloat = 0
    private var hovering = false
    private var bulgeCenter: CGFloat?    // Pointer x while active; nil is flat.
    private var trackArea: NSTrackingArea?

    private var dust: SPDustHost?
    private var bulgeEnabled = true
    func setBufferedRanges(_ ranges: [ClosedRange<Double>], visible: Bool) {
        let normalized = visible ? SPBufferedTimeline.normalized(ranges) : []
        guard bufferedRanges != normalized || showsBufferedRanges != visible else { return }
        bufferedRanges = normalized
        showsBufferedRanges = visible
        dust?.setBufferedRanges(normalized, visible: visible)
        updateTrackVisibility()
        relayout()
    }
    func setDust(snapshot: SPThumbDustSnapshot?, duration: Double) {
        dust?.setSnapshot(snapshot, duration: duration)
    }

    func setDamage(bands: [SPDamageBand], duration: Double) {
        guard bands != damageBands || duration != damageDuration else { return }
        damageBands = bands
        damageDuration = duration
        dust?.setDamage(bands: bands, duration: duration)
        if dust == nil || showsBufferedRanges { relayout() }
    }

    func applyStyle(_ style: SPTimelineStyleSettings.Style) {
        bulgeEnabled = style == .tide
        setDustEnabled(SPDustHost.enabled)
        if dust == nil { relayout() }
    }

    // Animate from presentation paths. A fixed sample count preserves path
    // topology for Core Animation interpolation.
    private enum Bulge {
        static let sigma: CGFloat = 15   // Gaussian width; visible within about 3σ.
        static let amp: CGFloat = 5      // Symmetric half-height increase.
        static let samples = 128         // Fixed path topology.
    }
    // Both contours are built serially on the main thread. Reuse their 129-point
    // scratch storage instead of allocating two arrays for every pointer event;
    // sampled coordinates and Core Animation path topology remain unchanged.
    private var pathPoints = [CGPoint](repeating: .zero, count: Bulge.samples + 1)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for l: CALayer in [remainLayer, fillLayer, knobLayer, damagePartialLayer, damageNoneLayer, damagePendingLayer,
                          bufferedBaseLayer, bufferedLayer, bufferedMask, bufferedPlayedLayer] {
            l.actions = ["bounds": NSNull(), "position": NSNull(), "transform": NSNull(),
                         "hidden": NSNull(), "backgroundColor": NSNull(), "path": NSNull()]
        }
        remainLayer.fillColor = SPT.trackRemain.cgColor
        fillLayer.fillColor = NSColor.white.cgColor
        bufferedBaseLayer.fillColor = NSColor(white: 0.18, alpha: 1).cgColor
        bufferedLayer.fillColor = NSColor(white: 0.64, alpha: 1).cgColor
        bufferedPlayedLayer.fillColor = NSColor.white.cgColor
        bufferedMask.fillColor = NSColor.white.cgColor
        bufferedLayer.mask = bufferedMask
        bufferedBaseLayer.name = "sp.timeline.buffered.base"
        bufferedLayer.name = "sp.timeline.buffered.ranges"
        bufferedPlayedLayer.name = "sp.timeline.buffered.played"
        bufferedBaseLayer.zPosition = 10
        bufferedLayer.zPosition = 11
        bufferedPlayedLayer.zPosition = 12
        for l in [damagePendingLayer, damagePartialLayer, damageNoneLayer] { l.zPosition = 15 }
        knobLayer.zPosition = 20
        damagePartialLayer.fillColor = SPDamage.partialColor.cgColor
        damageNoneLayer.fillColor = SPDamage.noneColor.cgColor
        damagePendingLayer.fillColor = SPDamage.pendingColor.cgColor
        knobLayer.backgroundColor = NSColor.white.cgColor
        knobLayer.bounds = CGRect(x: 0, y: 0, width: SPM.knobD, height: SPM.knobD)
        knobLayer.cornerRadius = SPM.knobD / 2
        knobLayer.transform = CATransform3DMakeScale(0.001, 0.001, 1)
        layer?.addSublayer(remainLayer)
        layer?.addSublayer(fillLayer)
        layer?.addSublayer(damagePendingLayer)
        layer?.addSublayer(damagePartialLayer)
        layer?.addSublayer(damageNoneLayer)
        layer?.addSublayer(knobLayer)
        for l in [bufferedBaseLayer, bufferedLayer, bufferedPlayedLayer] { layer?.addSublayer(l) }
        updateTrackVisibility()
        applyStyle(SPTimelineStyleSettings.style)
    }

    func setDustEnabled(_ on: Bool) {
        if on {
            guard dust == nil else { return }
            let d = SPDustHost()
            dust = d
            d.attach(to: self)
            layer?.addSublayer(d.layer)
            knobLayer.isHidden = true
            damagePartialLayer.isHidden = true
            damageNoneLayer.isHidden = true
            damagePendingLayer.isHidden = true
            d.setDamage(bands: damageBands, duration: damageDuration)
            d.setBufferedRanges(bufferedRanges, visible: showsBufferedRanges)
            if bounds.width > 0 {
                d.setGeometry(bounds: bounds, scale: window?.backingScaleFactor ?? 2)
                d.setSplit(bounds.width * CGFloat(value))
            }
        } else {
            guard let d = dust else { return }
            d.setVisible(false)
            d.detach()
            d.layer.removeFromSuperlayer()
            dust = nil
            knobLayer.isHidden = false
            damagePartialLayer.isHidden = false
            damageNoneLayer.isHidden = false
            damagePendingLayer.isHidden = false
        }
        updateTrackVisibility()
        relayout()
    }

    private func updateTrackVisibility() {
        remainLayer.isHidden = dust != nil || showsBufferedRanges
        fillLayer.isHidden = dust != nil || showsBufferedRanges
        // The particle renderer owns its cache and damage presentation. A solid
        // rail (or a separate knob) would cover the gaps between its grains.
        for l in [bufferedBaseLayer, bufferedLayer, bufferedPlayedLayer] {
            l.isHidden = dust != nil || !showsBufferedRanges
        }
        knobLayer.isHidden = dust != nil
        for l in [damagePendingLayer, damagePartialLayer, damageNoneLayer] {
            l.isHidden = dust != nil
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func viewDidHide() { super.viewDidHide(); dust?.setVisible(false) }
    override func viewDidUnhide() { super.viewDidUnhide(); dust?.setVisible(true) }

    // Keep shape layers sharp when the backing scale changes.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let s = window?.backingScaleFactor ?? 2
        remainLayer.contentsScale = s
        fillLayer.contentsScale = s
        damagePartialLayer.contentsScale = s
        damageNoneLayer.contentsScale = s
        damagePendingLayer.contentsScale = s
        for l in [bufferedBaseLayer, bufferedLayer, bufferedMask, bufferedPlayedLayer] { l.contentsScale = s }
        dust?.setGeometry(bounds: bounds, scale: s)
    }

    override func layout() {
        super.layout()
        dust?.setGeometry(bounds: bounds, scale: window?.backingScaleFactor ?? 2)
        relayout()
    }

    private func relayout() { retargetTrack(duration: 0) }

    // Press to half amplitude, then rebound through 1.06 on release.
    private var ampScale: CGFloat = 1

    // Add a Gaussian bulge and taper both ends into a capsule.
    private func halfHeight(at x: CGFloat, halfBase: CGFloat, trackWidth: CGFloat) -> CGFloat {
        var h = halfBase
        if bulgeEnabled, let c = bulgeCenter {
            let d = (x - c) / Bulge.sigma
            if abs(d) < 3 { h += Bulge.amp * ampScale * exp(-0.5 * d * d) }
        }
        let r = halfBase
        if x < r {
            let t = (r - x) / r
            h *= sqrt(max(0, 1 - t * t))
        } else if x > trackWidth - r {
            let t = (x - (trackWidth - r)) / r
            h *= sqrt(max(0, 1 - t * t))
        }
        return h
    }

    // Build a symmetric closed contour with a fixed number of samples.
    private func trackPath(from x0: CGFloat, to x1: CGFloat, halfBase: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let w = max(bounds.width, 1)
        let midY = bounds.midY
        let n = Bulge.samples
        pathPoints.withUnsafeMutableBufferPointer { top in
            for i in 0...n {
                let x = x0 + (x1 - x0) * CGFloat(i) / CGFloat(n)
                top[i] = CGPoint(x: x, y: midY + halfHeight(at: x, halfBase: halfBase, trackWidth: w))
            }
            p.move(to: top[0])
            for pt in top.dropFirst() { p.addLine(to: pt) }
            for pt in top.reversed() { p.addLine(to: CGPoint(x: pt.x, y: 2 * midY - pt.y)) }
        }
        p.closeSubpath()
        return p
    }

    private func damagePath(cls: Int32, halfBase: CGFloat) -> CGPath? {
        guard damageDuration > 0 else { return nil }
        let p = CGMutablePath()
        let w = max(bounds.width, 1)
        let midY = bounds.midY
        var any = false
        for b in damageBands where b.cls == cls {
            let x0 = max(0, min(w, CGFloat(b.from / damageDuration) * w))
            let x1 = max(0, min(w, CGFloat(b.until / damageDuration) * w))
            guard x1 > x0 else { continue }
            p.addRect(CGRect(x: x0, y: midY - halfBase, width: max(1, x1 - x0), height: 2 * halfBase))
            any = true
        }
        return any ? p : nil
    }

    // A zero duration updates immediately. Positive durations continue from the
    // presentation path; direct dragging may cancel an in-flight path animation.
    private func retargetTrack(duration: CFTimeInterval, cancelInFlight: Bool = false) {
        guard bounds.width > 0 else { return }
        let halfBase = ((hovering || dragging) ? SPM.trackHover : SPM.trackIdle) / 2
        updateBufferedTrack(halfBase: halfBase, duration: duration, cancelInFlight: cancelInFlight)
        if let dust { dust.setSplit(bounds.width * CGFloat(value)); return }
        let split = bounds.width * CGFloat(value)
        let rp = trackPath(from: split, to: bounds.width, halfBase: halfBase)
        let fp = trackPath(from: 0, to: split, halfBase: halfBase)

        let fromR = duration > 0 ? (remainLayer.presentation()?.path ?? remainLayer.path) : nil
        let fromF = duration > 0 ? (fillLayer.presentation()?.path ?? fillLayer.path) : nil
        noAnim {
            remainLayer.path = rp
            fillLayer.path = fp
            knobLayer.position = CGPoint(x: split, y: bounds.midY)
            if damageBands.isEmpty {
                damagePartialLayer.path = nil
                damageNoneLayer.path = nil
                damagePendingLayer.path = nil
            } else {
                damagePartialLayer.path = damagePath(cls: SPDamageBand.partial, halfBase: halfBase)
                damageNoneLayer.path = damagePath(cls: SPDamageBand.none, halfBase: halfBase)
                damagePendingLayer.path = damagePath(cls: SPDamageBand.pending, halfBase: halfBase)
            }
        }
        guard duration > 0 else {
            // Cancel path interpolation during direct dragging.
            if cancelInFlight {
                remainLayer.removeAnimation(forKey: "liquid")
                fillLayer.removeAnimation(forKey: "liquid")
            }
            return
        }
        let curve = CAMediaTimingFunction(name: .easeOut)
        for (l, from, to): (CAShapeLayer, CGPath?, CGPath) in [(remainLayer, fromR, rp),
                                                               (fillLayer, fromF, fp)] {
            guard let from else { continue }
            let a = CABasicAnimation(keyPath: "path")
            a.fromValue = from
            a.toValue = to
            a.duration = duration
            a.timingFunction = curve
            a.isRemovedOnCompletion = true
            l.add(a, forKey: "liquid")
        }
    }

    private func updateBufferedTrack(halfBase: CGFloat, duration: CFTimeInterval, cancelInFlight: Bool) {
        guard showsBufferedRanges, dust == nil else { return }
        let full = trackPath(from: 0, to: bounds.width, halfBase: halfBase)
        let played = trackPath(from: 0, to: bounds.width * CGFloat(value), halfBase: halfBase)
        let mask = CGMutablePath()
        for range in bufferedRanges {
            mask.addRect(CGRect(x: bounds.width * range.lowerBound, y: bounds.minY,
                width: bounds.width * (range.upperBound - range.lowerBound), height: bounds.height))
        }
        let layers = [bufferedBaseLayer, bufferedLayer, bufferedPlayedLayer]
        let previous = layers.map { $0.presentation()?.path ?? $0.path }
        noAnim {
            for layer in layers { layer.frame = bounds }
            bufferedBaseLayer.path = full
            bufferedLayer.path = full
            bufferedPlayedLayer.path = played
            knobLayer.position = CGPoint(x: bounds.width * CGFloat(value), y: bounds.midY)
            bufferedMask.frame = bounds
            bufferedMask.path = mask
            damagePartialLayer.path = damagePath(cls: SPDamageBand.partial, halfBase: halfBase)
            damageNoneLayer.path = damagePath(cls: SPDamageBand.none, halfBase: halfBase)
            damagePendingLayer.path = damagePath(cls: SPDamageBand.pending, halfBase: halfBase)
        }
        for (index, layer) in layers.enumerated() {
            if duration > 0, let from = previous[index] {
                let animation = CABasicAnimation(keyPath: "path")
                animation.fromValue = from
                animation.toValue = layer.path
                animation.duration = duration
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(animation, forKey: "liquid")
            } else if cancelInFlight { layer.removeAnimation(forKey: "liquid") }
        }
    }

    func setValue(_ v: Double) {
        guard !dragging else { return }
        let nv = max(0, min(1, v))
        if abs(nv - value) * Double(bounds.width) < 0.5 { return }
        value = nv
        relayout()
    }

    func cancelInteraction() {
        guard dragging else { return }
        dragging = false
        moved = false
        ampScale = 1
        if !hovering { bulgeCenter = nil }
        dust?.released(hovering: hovering)
        applyState()
        if !hovering { onHover?(nil, 0, .moved) }
    }

    /// Rebound the pressed presentation path through 1.06 when still hovered.
    @discardableResult
    private func performPressRebound() -> Bool {
        if dust != nil || !bulgeEnabled { ampScale = 1; return false }
        guard ampScale != 1 else { return false }
        guard hovering, bulgeCenter != nil, bounds.width > 0,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            ampScale = 1
            return false
        }
        let halfBase = SPM.trackHover / 2 // Release remains hovered.
        let split = bounds.width * CGFloat(value)
        func paths(_ s: CGFloat) -> (CGPath, CGPath, CGPath) {
            ampScale = s
            return (trackPath(from: split, to: bounds.width, halfBase: halfBase),
                    trackPath(from: 0, to: split, halfBase: halfBase),
                    trackPath(from: 0, to: bounds.width, halfBase: halfBase))
        }
        let (r0, f0, c0) = paths(0.5)
        let (rO, fO, cO) = paths(1.06)
        let (r1, f1, c1) = paths(1) // Restore the model amplitude.
        var tracks = [(remainLayer, [r0, rO, r1]), (fillLayer, [f0, fO, f1])]
        if showsBufferedRanges {
            tracks += [(bufferedBaseLayer, [c0, cO, c1]), (bufferedLayer, [c0, cO, c1]),
                       (bufferedPlayedLayer, [f0, fO, f1])]
        }
        for (l, vals) in tracks {
            // Continue from an in-flight presentation path.
            let start = l.presentation()?.path ?? vals[0]
            noAnim { l.path = vals[2] }
            let a = CAKeyframeAnimation(keyPath: "path")
            a.values = [start, vals[1], vals[2]]
            a.keyTimes = [0, 0.55, 1]
            a.duration = 0.20
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            a.isRemovedOnCompletion = true
            l.add(a, forKey: "liquid")
        }
        return true
    }

    // Clicks update the split immediately; hover transitions use 0.15 seconds.
    private func applyState(trackDuration: CFTimeInterval = 0.15) {
        let scale: CGFloat = dragging ? 1.0 : (hovering ? 0.8 : 0.001)
        // Animate the compositor-only knob transform for 0.12 seconds.
        let anim = CABasicAnimation(keyPath: "transform")
        anim.duration = 0.12
        anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
        anim.isRemovedOnCompletion = true
        anim.fillMode = .removed
        noAnim { knobLayer.transform = CATransform3DMakeScale(scale, scale, 1) }
        knobLayer.add(anim, forKey: "scale")
        retargetTrack(duration: trackDuration)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = trackArea { removeTrackingArea(a) }

        let a = NSTrackingArea(rect: .zero,
                               options: [.activeAlways, .inVisibleRect,
                                         .mouseEnteredAndExited, .mouseMoved],
                               owner: self)
        addTrackingArea(a)
        trackArea = a
    }
    override func mouseEntered(with event: NSEvent) {
        pointerEntered(atX: convert(event.locationInWindow, from: nil).x)
    }
    override func mouseExited(with event: NSEvent) { pointerExited() }
    override func mouseMoved(with event: NSEvent) {
        pointerMoved(toX: convert(event.locationInWindow, from: nil).x)
    }

    func pointerEntered(atX x: CGFloat) {
        hovering = true
        bulgeCenter = x
        dust?.pointerEntered(x: x)
        applyState()
    }
    func pointerExited() {
        hovering = false
        bulgeCenter = nil
        dust?.pointerExited()
        if !dragging { onHover?(nil, 0, .moved) }
        applyState()
    }
    func pointerMoved(toX x: CGFloat) {
        bulgeCenter = x
        dust?.pointerMoved(x: x)
        // A short presentation transition smooths pointer tracking.
        retargetTrack(duration: 0.12)
        onHover?(x, ratio(at: x), .moved)
    }

    private func ratio(at x: CGFloat) -> Double {
        Double(max(0, min(1, x / max(bounds.width, 1))))
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        pointerPressed(atX: convert(event.locationInWindow, from: nil).x)
    }
    func pointerPressed(atX px: CGFloat) {
        guard !interactionLocked else { return }
        dragging = true
        moved = false
        let x = px
        downX = x
        let r = ratio(at: x)
        value = r
        bulgeCenter = x
        dust?.pressed(x: x)
        // Hold the bulge at half amplitude while pressed.
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            ampScale = 0.5
        }
        applyState(trackDuration: 0.15) // Briefly transition to the click target.
        onBegan?(r)

        onHover?(x, r, .movedNoRequest)
    }
    override func mouseDragged(with event: NSEvent) {
        pointerDragged(toX: convert(event.locationInWindow, from: nil).x)
    }
    func pointerDragged(toX dx: CGFloat) {
        guard dragging else { return }
        let x = max(0, min(bounds.width, dx))

        if !moved && abs(x - downX) < 3 { return }
        moved = true
        let r = ratio(at: x)
        value = r
        bulgeCenter = x
        dust?.pointerMoved(x: x)
        // Direct seeking follows the pointer without interpolation.
        retargetTrack(duration: 0, cancelInFlight: true)
        onScrub?(r)

        onHover?(x, r, .movedNoRequest)
    }
    override func mouseUp(with event: NSEvent) {
        pointerReleased(atX: convert(event.locationInWindow, from: nil).x)
    }
    func pointerReleased(atX ux: CGFloat) {
        guard dragging else { return }
        dragging = false
        if !hovering { bulgeCenter = nil }
        dust?.released(hovering: hovering)
        // Preserve the rebound animation while committing final model geometry.
        let rebounded = performPressRebound()
        applyState(trackDuration: rebounded ? 0 : 0.15)
        if !hovering { onHover?(nil, 0, .moved) }
        onEnded?(value, moved)

        if hovering {
            let x = max(0, min(bounds.width, ux))
            onHover?(x, ratio(at: x), .commit)
        }
    }
}

// ── Hover time bubble ──────────────────────────────────────────────
// The label always shows the pointer's requested time. Coarse seeking may land
// on a nearby keyframe, so secondary text color communicates approximation
// without changing the value. Text is vertically centered, width is measured,
// and callers align the origin to integral points.
final class SPHoverBubble: NSView {
    private let label = NSTextField(labelWithString: "")
    private var lastText = ""
    private var lastSecond: Double?
    private var lastState: Int32 = 0

    var stateLabels: (partial: String, none: String) = ("", "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 76, height: 24))
        wantsLayer = true
        layer?.backgroundColor = SPT.surfaceChip.cgColor
        layer?.cornerRadius = 12
        layer?.borderColor = SPT.strokeChip.cgColor
        layer?.borderWidth = 0.5
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = SPT.fgSecondary
        label.alignment = .center
        addSubview(label)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setTime(_ seconds: Double, state: Int32 = 0) -> CGFloat {
        let second = seconds.isFinite && seconds > 0 ? seconds.rounded(.towardZero) : 0
        if second != lastSecond || state != lastState {
            lastSecond = second
            if state != lastState {
                lastState = state
                label.textColor = state == SPDamageBand.none ? SPDamage.noneColor.withAlphaComponent(1)
                    : state == SPDamageBand.partial ? SPDamage.partialColor.withAlphaComponent(1) : SPT.fgSecondary
            }
            var text = SPTimeText.clock(seconds)
            if state == SPDamageBand.none, !stateLabels.none.isEmpty { text += " · " + stateLabels.none }
            else if state == SPDamageBand.partial, !stateLabels.partial.isEmpty { text += " · " + stateLabels.partial }
            if text != lastText {
                lastText = text
                label.stringValue = text
                label.sizeToFit()
            }
        }
        return max(56, label.frame.width + 22)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let s = label.frame.size
        label.frame = NSRect(x: ((newSize.width - s.width) / 2).rounded(),
                             y: ((newSize.height - s.height) / 2).rounded(),
                             width: s.width, height: s.height)
    }
}

final class SPHoverPreviewCard: NSView {
    private let imageLayer = CALayer()
    private var imageSize = CGSize.zero // pt

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = SPT.surfaceChip.cgColor
        layer?.borderColor = Self.borderIdle
        layer?.borderWidth = 0.5
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(),
                              "position": NSNull(), "hidden": NSNull()]
        imageLayer.contentsGravity = .resize

        imageLayer.wantsExtendedDynamicRangeContent = true
        layer?.addSublayer(imageLayer)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setImage(_ image: CGImage?) -> Bool {
        guard let image, image.width > 0, image.height > 0 else { return false }
        // The image is immutable. Keep positional/exact-state updates at the
        // caller, but do not re-submit identical contents on every pointer move.
        if let contents = imageLayer.contents, (contents as AnyObject) === image {
            return true
        }
        let replacing = !isHidden && imageLayer.contents != nil
        imageSize = CGSize(width: max(40, CGFloat(image.width) / 2),
                           height: max(24, CGFloat(image.height) / 2))
        if replacing {
            let t = CATransition()
            t.type = .fade
            t.duration = 0.15
            imageLayer.add(t, forKey: "swap")
        }
        noAnim { imageLayer.contents = image }
        return true
    }

    // While the pointer moves, 50% opacity marks the preview as provisional.
    // Once stationary with an exact image, it reaches full opacity within the
    // short-animation limit. State equality avoids repeated CA submissions.
    private var revealed = false
    private var dimmed = false
    private var pendingHide = false

    private static let borderIdle = NSColor(white: 1, alpha: 0.25).cgColor
    private static let borderExact = NSColor(white: 1, alpha: 0.45).cgColor

    func dimForSweep() {
        guard !dimmed else { return }
        dimmed = true
        revealed = false
        for key in ["reveal", "revealBorder", "motion"] {
            layer?.removeAnimation(forKey: key)
        }
        noAnim {
            layer?.opacity = 0.5
            layer?.borderColor = Self.borderIdle
        }
    }

    func revealExact() {
        guard !revealed else { return }
        revealed = true
        dimmed = false
        guard let layer else { return }
        layer.removeAnimation(forKey: "appear")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.5
        fade.toValue = 1.0
        fade.duration = 0.15
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        var from = CATransform3DMakeTranslation(bounds.width * 0.02,
                                                bounds.height * 0.02, 0)
        from = CATransform3DScale(from, 0.96, 0.96, 1)
        let settle = CABasicAnimation(keyPath: "transform")
        settle.fromValue = NSValue(caTransform3D: from)
        settle.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        settle.duration = 0.18
        settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let border = CABasicAnimation(keyPath: "borderColor")
        border.fromValue = Self.borderIdle
        border.toValue = Self.borderExact
        border.duration = 0.15
        noAnim {
            layer.opacity = 1.0
            layer.borderColor = Self.borderExact
        }
        layer.add(fade, forKey: "reveal")
        layer.add(settle, forKey: "motion")
        layer.add(border, forKey: "revealBorder")
    }

    func prepareToShow() -> Bool {
        let appearing = isHidden || pendingHide
        if pendingHide {
            pendingHide = false
            layer?.removeAnimation(forKey: "hide")
        }
        isHidden = false
        return appearing
    }

    func animateAppear() {
        guard let layer else { return }
        layer.removeAnimation(forKey: "reveal")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = layer.opacity
        fade.duration = 0.10

        let s: CGFloat = 0.94
        var from = CATransform3DMakeTranslation(bounds.width * (1 - s) / 2,
                                                bounds.height * (1 - s) / 2 - 12,
                                                0)
        from = CATransform3DScale(from, s, s, 1)
        let rise = CABasicAnimation(keyPath: "transform")
        rise.fromValue = NSValue(caTransform3D: from)
        rise.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        rise.duration = 0.16
        for (a, key) in [(fade, "appear"), (rise, "motion")] {
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(a, forKey: key)
        }
    }

    func hideAnimated() {
        guard !isHidden, !pendingHide else { return }
        guard let layer else {
            isHidden = true
            return
        }
        pendingHide = true
        layer.removeAnimation(forKey: "appear")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = (layer.presentation() ?? layer).opacity
        fade.toValue = 0.0

        let sink = CABasicAnimation(keyPath: "transform")
        sink.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        sink.toValue =
            NSValue(caTransform3D: CATransform3DMakeTranslation(0, -3, 0))
        for a in [fade, sink] {
            a.duration = 0.12
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        }
        fade.isRemovedOnCompletion = false
        fade.fillMode = .forwards
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.pendingHide else { return }
            self.pendingHide = false
            self.isHidden = true
            self.layer?.removeAnimation(forKey: "hide")
        }
        layer.add(fade, forKey: "hide")
        layer.add(sink, forKey: "motion")
        CATransaction.commit()
    }

    func hideImmediate() {
        pendingHide = false
        layer?.removeAnimation(forKey: "hide")
        isHidden = true
    }

    func place(centerX: CGFloat, bottomY: CGFloat, clampTo width: CGFloat) {
        let inset: CGFloat = 3
        let w = imageSize.width + inset * 2
        let h = imageSize.height + inset * 2
        let x = max(4, min(centerX - w / 2, width - w - 4)).rounded()
        let cardFrame = NSRect(x: x, y: bottomY, width: w, height: h)
        if frame != cardFrame { frame = cardFrame }
        let contentFrame = CGRect(x: inset, y: inset,
                                  width: imageSize.width, height: imageSize.height)
        if imageLayer.frame != contentFrame {
            noAnim { imageLayer.frame = contentFrame }
        }
    }
}

final class SPChromeView: NSView, PlayerChromePresenting {
    // Timeline clicks and drags use keyframe seeks throughout. Decoding an
    // entire GOP to refine the target raised remote 4K first-image latency from
    // about 128 ms to 905 ms, while keyframe snapping is visually unobtrusive.
#if !SP_APP_STORE
    private static let audit = ProcessInfo.processInfo.environment["SP_UI_AUDIT"] != nil
#endif

    var onPlayPause: (() -> Void)?
    var onScrubBegan: ((Double) -> Void)?
    var onScrubCoarse: ((Double) -> Void)?
    var onScrubEnded: ((Double, Bool) -> Void)?
    var onHoverTime: ((Double) -> Void)?
    var onHoverPreviewRequest: ((Double) -> Void)?
    var onHoverPreviewCommit: ((Double) -> Void)?
    var onHoverExit: (() -> Void)?

    var previewImageProvider: ((Double) -> (image: CGImage, exact: Bool)?)?
    var dustSnapshotProvider: (() -> SPThumbDustSnapshot?)?
    var damageSnapshotProvider: (() -> SPDamageSnapshot?)?
    private var damageBands: [SPDamageBand] = []
    private var damageGen: UInt64 = 0
    private var styleObserver: NSObjectProtocol?
    var onVolume: ((Double) -> Void)?       // 0...500; locked boost clamps at 100.
    var onVolumeBoostIntent: (() -> Void)?  // Intent to cross the locked boundary.
    var onMute: (() -> Void)?
    var onFullscreen: (() -> Void)?
    var onPictureInPicture: (() -> Void)?
    var onSettingsToggle: (() -> Void)?
    var onRateSelected: ((Double) -> Void)?
    var onSpeedSettings: (() -> Void)?
    var onSubtitlesToggle: (() -> Void)?
    var onTogglePlaylist: (() -> Void)?
    var onMotionSmoothingToggle: (() -> Void)?
    var onXDRToggle: (() -> Void)?
    var durationProvider: (() -> Double) = { 0 }

    static let rateOptions: [Double] = [0.25, 0.5, 1, 1.25, 1.5, 2, 3, 4, 5]

    private let scrim = CAGradientLayer()
    private let playBtn = SPPlayPauseButton(size: SPM.btnMain)
    private let muteBtn = SPIconButton(symbol: "speaker.wave.2.fill", pointSize: SPM.symAux, size: SPM.btnAux)
    private let fsBtn = SPIconButton(symbol: "arrow.up.left.and.arrow.down.right", pointSize: SPM.symAux, size: SPM.btnAux)
    private let pipBtn = SPIconButton(symbol: "pip.enter", pointSize: SPM.symAux, size: SPM.btnAux)
    private let settingsBtn = SPIconButton(symbol: "gearshape", pointSize: SPM.symAux, size: SPM.btnAux)
    private let playlistBtn = SPIconButton(symbol: "list.bullet", pointSize: SPM.symAux, size: SPM.btnAux)
    private let volSlider = SPVolumeControl(frame: .zero)
    private lazy var volumeGroup = SPVolumeHoverView(muteButton: muteBtn, slider: volSlider)
    private let rateChip = SPChipButton(width: 48)

    private let motionBtn = SPMotionButton()
    private let subtitlesBtn = SPIconButton(symbol: "rectangle", pointSize: SPM.symAux, size: SPM.btnAux)
    private static let subtitlesOutline = makeSubtitlesImage(filled: false)
    private static let subtitlesFilled = makeSubtitlesImage(filled: true)
    private static let playlistImage: NSImage = {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            for rect in [CGRect(x: 1, y: 14, width: 17, height: 2),
                         CGRect(x: 1, y: 9, width: 17, height: 2),
                         CGRect(x: 1, y: 4, width: 10, height: 2)] {
                context.fill(rect)
            }
            context.move(to: CGPoint(x: 14.5, y: 0.5))
            context.addLine(to: CGPoint(x: 21.5, y: 4.5))
            context.addLine(to: CGPoint(x: 14.5, y: 8.5))
            context.closePath()
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }()

    private static func makeSubtitlesImage(filled: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 17), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let outline = CGPath(roundedRect: CGRect(x: 1, y: 1, width: 20, height: 15),
                                 cornerWidth: 1, cornerHeight: 1, transform: nil)
            if filled {
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.addPath(outline)
                context.fillPath()
            } else {
                context.setStrokeColor(CGColor(gray: 1, alpha: 1))
                context.setLineWidth(1.8)
                context.addPath(outline)
                context.strokePath()
            }
            context.setFillColor(CGColor(gray: filled ? 0.3 : 1, alpha: 1))
            for rect in [CGRect(x: 4, y: 6, width: 4.5, height: 1.6),
                         CGRect(x: 11, y: 6, width: 7, height: 1.6),
                         CGRect(x: 4, y: 3, width: 8, height: 1.6),
                         CGRect(x: 14, y: 3, width: 4, height: 1.6)] {
                context.addPath(CGPath(roundedRect: rect, cornerWidth: 0.8,
                                       cornerHeight: 0.8, transform: nil))
                context.fillPath()
            }
            return true
        }
        image.isTemplate = !filled
        return image
    }
    private var xdrPresentation: XDRPresentation = .idle

    private var latestPosition: Double = 0
    private var latestDuration: Double = 0
    private var currentRate: Double = 1.0
    private var latestPlaying = false
    private var latestVolumePct: Double = 100
    private var latestMuted = false
    private var latestVolumeBoost: VolumeBoostPresentation = .normal
    private var latestHDRDescription: String?
    private var latestHDRDetail: String?
    private var regularRateWidth: CGFloat = 48
    private var motionPresentation: MotionPresentation = .idle

    private var turboFrozenMotion: MotionPresentation?
    private var lastRenderedModel: ChromePresentation?
    private let track = SPProgressView()
    private let timeLabel = SPPlaybackTimeButton(frame: .zero)
    private struct VolumeWidthTransition {
        var start: CGFloat
        var target: CGFloat
        var began: TimeInterval
        let duration: TimeInterval = 0.20
    }
    private var volumeWidthTransition: VolumeWidthTransition?
    private var visibleVolumeWidth: CGFloat = SPM.btnAux
    private var targetVolumeWidth: CGFloat = SPM.btnAux
    private var volumeAnimationTimer: Timer?
    private let bubble = SPHoverBubble()
    private let previewCard = SPHoverPreviewCard()
    private var lastHoverX: CGFloat?
    private var lastHoverRatio: Double = 0

    private var lastImageExact = false
    private var hoverStationary = false
    private var hoverStillTimer: Timer?
    private var hoverStillDeadline: TimeInterval = 0

    // Shared hover-glow state.
    private let glowA = CALayer()
    private let glowB = CALayer()
    private var activeGlow: CALayer?
    private var glowButton: NSButton?
    private var lastGlowButton: NSButton?
    private var lastGlowExit: TimeInterval = 0

    private var lastRenderedRate = Double.nan

    private var latestTurbo = false
    private var lastRenderedTurbo = false
    private static let turboAccent = SPT.turboAccentColor
    private let turboRing = CAShapeLayer()

    private func fireTurboShockRing() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let ring = turboRing
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.55
        grow.toValue = 2.1
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.95, 0.7, 0]
        fade.keyTimes = [0, 0.45, 1]
        let thin = CABasicAnimation(keyPath: "lineWidth")
        thin.fromValue = 3.0
        thin.toValue = 0.5
        let g = CAAnimationGroup()
        g.animations = [grow, fade, thin]
        g.duration = 0.5
        g.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.removeAllAnimations()
        ring.add(g, forKey: "shock")
    }
    private var scrubTargetSec: Double = 0

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        scrim.colors = SPT.scrimStops.map { NSColor(white: 0, alpha: $0.0).cgColor }
        scrim.locations = SPT.scrimStops.map { NSNumber(value: Double($0.1)) }
        scrim.startPoint = CGPoint(x: 0.5, y: 0)
        scrim.endPoint = CGPoint(x: 0.5, y: 1)
        scrim.actions = ["bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(scrim)

        let ringD = SPM.btnMain
        turboRing.bounds = CGRect(x: 0, y: 0, width: ringD, height: ringD)
        turboRing.path = CGPath(ellipseIn: turboRing.bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        turboRing.fillColor = nil
        turboRing.strokeColor = SPT.turboAccentColor.cgColor
        turboRing.lineWidth = 2.5
        turboRing.opacity = 0
        turboRing.actions = ["bounds": NSNull(), "position": NSNull(),
                             "opacity": NSNull(), "transform": NSNull(), "lineWidth": NSNull()]
        layer?.insertSublayer(turboRing, above: scrim)

        playBtn.target = self; playBtn.action = #selector(playTapped)
        muteBtn.target = self; muteBtn.action = #selector(muteTapped)
        fsBtn.target = self; fsBtn.action = #selector(fsTapped)
        pipBtn.target = self; pipBtn.action = #selector(pictureInPictureTapped)
        pipBtn.refusesFirstResponder = false
        pipBtn.setAccessibilityIdentifier("sp.chrome.pictureInPicture")
        pipBtn.isEnabled = false
        pipBtn.alphaValue = 0.4
        pipBtn.onFocusChanged = { [weak self] focused in
            guard let self else { return }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                noAnim { self.pipBtn.layer?.backgroundColor = focused ? SPT.fillHover.cgColor : nil }
            } else if focused {
                self.glowMove(to: self.pipBtn)
            } else {
                self.glowExit(from: self.pipBtn)
            }
        }
        setPictureInPictureSelected(false)
        settingsBtn.target = self; settingsBtn.action = #selector(settingsTapped)
        setSettingsSelected(false)
        playlistBtn.target = self; playlistBtn.action = #selector(playlistTapped)
        setPlaylistSelected(false)

        volSlider.target = self
        volSlider.action = #selector(volChanged)
        volSlider.onBoostIntent = { [weak self] in self?.onVolumeBoostIntent?() }
        volSlider.onExpansionChanged = { [weak self] _, animated in
            self?.layoutRightControls(animateVolume: animated)
        }
        volumeGroup.onExpansionChanged = { [weak self] animated in
            self?.layoutRightControls(animateVolume: animated)
        }
        muteBtn.setAccessibilityLabel(L("settings.mute"))

        rateChip.setText("1×")
        rateChip.toolTip = L("chrome.rate.tooltip")
        rateChip.target = self
        rateChip.action = #selector(rateTapped)
        noAnim { rateChip.layer?.backgroundColor = NSColor.clear.cgColor }
        if SPFeatures.enhancements {
            motionBtn.target = self
            motionBtn.action = #selector(motionSmoothingTapped)
            motionBtn.setAccessibilityLabel(L("chrome.memc.a11y.label"))
            applyMotionSmoothingAppearance()
        }
        subtitlesBtn.target = self
        subtitlesBtn.action = #selector(subtitlesTapped)
        setSubtitlesSelected(false, available: false)
        prepareStableControlMetrics()

        timeLabel.onWidthChanged = { [weak self] in self?.layoutRightControls() }

        track.onBegan = { [weak self] r in
            guard let self else { return }
            let dur = self.durationProvider()
            guard dur > 0 else { return }
            self.scrubTargetSec = r * dur
            self.setTimeLabels(position: self.scrubTargetSec, duration: dur)
            self.onScrubBegan?(self.scrubTargetSec)
        }
        track.onScrub = { [weak self] r in
            guard let self else { return }
            let dur = self.durationProvider()
            guard dur > 0 else { return }
            self.scrubTargetSec = r * dur
            self.setTimeLabels(position: self.scrubTargetSec, duration: dur)
            self.onScrubCoarse?(self.scrubTargetSec)
        }
        track.onEnded = { [weak self] r, dragged in
            guard let self else { return }
            let dur = self.durationProvider()
            self.onScrubEnded?(r * dur, dragged)
        }
        track.onHover = { [weak self] x, r, intent in

            switch intent {
            case .moved:
                self?.handleTrackHover(x, ratio: r, pointerMoved: true, request: .full)
            case .movedNoRequest:
                self?.handleTrackHover(x, ratio: r, pointerMoved: true, request: .none)
            case .commit:
                self?.handleTrackHover(x, ratio: r, pointerMoved: false, request: .thumbnailOnly)
            }
        }

        // Omitted feature chips never enter the view or layout hierarchy.
        var installedViews: [NSView] = [track, playBtn, volumeGroup]
        if SPFeatures.enhancements { installedViews += [motionBtn] }
        installedViews += [rateChip, playlistBtn, subtitlesBtn, settingsBtn, pipBtn, fsBtn,
                           timeLabel, bubble, previewCard]
        for v in installedViews { addSubview(v) }

        styleObserver = NotificationCenter.default.addObserver(
            forName: SPTimelineStyleSettings.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.track.applyStyle(SPTimelineStyleSettings.style)
                self.refreshDust()
            }
        }
        // Reduced Motion keeps each button's immediate hover highlight.
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            installHoverGlow()
        }
    }

    // Move one reusable hover glow within the playback cluster. Distant buttons
    // cross-fade between two layers; state-bearing chips are excluded.
    private func installHoverGlow() {
        for g in [glowA, glowB] {
            g.backgroundColor = SPT.fillHover.cgColor
            g.cornerRadius = 8
            g.opacity = 0
            g.actions = ["position": NSNull(), "bounds": NSNull(),
                         "opacity": NSNull(), "hidden": NSNull()]
            layer?.insertSublayer(g, above: scrim)
        }
        let handler: (NSButton, Bool) -> Void = { [weak self] b, inside in
            guard let self else { return }
            if inside { self.glowMove(to: b) } else { self.glowExit(from: b) }
        }
        playBtn.onHoverChanged = handler
        muteBtn.onHoverChanged = handler
        settingsBtn.onHoverChanged = handler
        playlistBtn.onHoverChanged = handler
        subtitlesBtn.onHoverChanged = handler
        fsBtn.onHoverChanged = handler
        pipBtn.onHoverChanged = handler
    }

    private func glowSet(_ g: CALayer, frame: CGRect) {
        noAnim { g.frame = frame; g.cornerRadius = min(frame.width, frame.height) / 2 }
    }

    private func glowFade(_ g: CALayer, to op: Float, duration: CFTimeInterval) {
        let from = g.presentation()?.opacity ?? g.opacity
        noAnim { g.opacity = op }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = op
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        a.isRemovedOnCompletion = true
        g.add(a, forKey: "opacity")
    }

    // Continue adjacent movement from presentation values.
    private func glowSlide(_ g: CALayer, to frame: CGRect, duration: CFTimeInterval) {
        let fromPos = g.presentation()?.position ?? g.position
        let fromBounds = g.presentation()?.bounds ?? g.bounds
        let fromOp = g.presentation()?.opacity ?? g.opacity
        glowSet(g, frame: frame)
        noAnim { g.opacity = 1 }
        let curve = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
        func add(_ key: String, _ from: Any?, _ to: Any) {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = from
            a.toValue = to
            a.duration = duration
            a.timingFunction = curve
            a.isRemovedOnCompletion = true
            g.add(a, forKey: key)
        }
        add("position", NSValue(point: fromPos), NSValue(point: g.position))
        add("bounds", NSValue(rect: fromBounds), NSValue(rect: g.bounds))
        add("opacity", fromOp, Float(1))
    }

    private func glowMove(to b: NSButton) {
        let target = convert(b.bounds, from: b)
        let now = ProcessInfo.processInfo.systemUptime
        // Treat an enter within 0.25 seconds of exit as a handoff.
        let prev = glowButton ?? ((now - lastGlowExit < 0.25) ? lastGlowButton : nil)
        glowButton = b
        let trio: [NSButton] = [playBtn, muteBtn]
        if let prev, prev !== b, let g = activeGlow,
           trio.contains(where: { $0 === prev }), trio.contains(where: { $0 === b }) {
            glowSlide(g, to: target, duration: 0.17)
            return
        }
        if let g = activeGlow, let prev, prev !== b,
           (g.presentation()?.opacity ?? g.opacity) > 0.05 {
            // Cross-fade between layers for a distant jump.
            glowFade(g, to: 0, duration: 0.10)
            let n = (g === glowA) ? glowB : glowA
            glowSet(n, frame: target)
            glowFade(n, to: 1, duration: 0.12)
            activeGlow = n
            return
        }
        // Fade in at the target, continuing from presentation opacity.
        let g = activeGlow ?? glowA
        glowSet(g, frame: target)
        glowFade(g, to: 1, duration: 0.12)
        activeGlow = g
    }

    private func glowExit(from b: NSButton) {
        guard glowButton === b else { return }
        glowButton = nil
        lastGlowButton = b
        lastGlowExit = ProcessInfo.processInfo.systemUptime
        if let g = activeGlow { glowFade(g, to: 0, duration: 0.10) }
    }

    // Reset stale geometry and hover state after layout or visibility changes.
    private func glowReset() {
        glowButton = nil
        lastGlowButton = nil
        for g in [glowA, glowB] {
            g.removeAllAnimations()
            noAnim { g.opacity = 0 }
        }
    }

    private enum HoverRequest { case none, thumbnailOnly, full }
    private func handleTrackHover(_ x: CGFloat?, ratio r: Double,
                                  pointerMoved: Bool, request: HoverRequest) {
        guard let x else {
            endHover(animated: true)
            return
        }

        if pointerMoved, let last = lastHoverX, abs(x - last) < 0.5, request == .full {
            return
        }
        let dur = durationProvider()
        guard dur > 0 else { return }
        let moved = pointerMoved && lastHoverX != x
        lastHoverX = x
        lastHoverRatio = r
        let t = r * dur
        if request == .thumbnailOnly {

            onHoverPreviewCommit?(t)
        } else if request == .full {
            onHoverTime?(t)
            onHoverPreviewRequest?(t)
        }
        if moved { noteHoverMovement() }
        let bw = bubble.setTime(t, state: damageBands.isEmpty ? 0 : SPDamage.state(at: t, in: damageBands))
        let cx = (track.frame.minX + x).rounded()
        let by = track.frame.maxY + 6
        bubble.frame = NSRect(x: max(4, min(cx - bw / 2, bounds.width - bw - 4)).rounded(),
                              y: by, width: bw, height: 24)
        bubble.isHidden = false
        let preview = previewImageProvider?(t)
        if let preview, previewCard.setImage(preview.image) {
            lastImageExact = preview.exact
            previewCard.place(centerX: cx, bottomY: by + 24 + 6, clampTo: bounds.width)
            let appearing = previewCard.prepareToShow()

            if hoverStationary && preview.exact { previewCard.revealExact() }
            if appearing { previewCard.animateAppear() }
        } else {
            lastImageExact = false
            previewCard.hideImmediate()
        }
    }

    private func noteHoverMovement() {
        hoverStationary = false
        previewCard.dimForSweep()

        hoverStillDeadline = ProcessInfo.processInfo.systemUptime + 0.12
        if hoverStillTimer == nil { armHoverStillTimer(after: 0.12) }
    }

    private func armHoverStillTimer(after t: TimeInterval) {
        let timer = Timer.scheduledTimer(withTimeInterval: t,
                                         repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hoverStillTimer = nil
                guard self.lastHoverX != nil else { return }
                let remain = self.hoverStillDeadline - ProcessInfo.processInfo.systemUptime
                if remain > 0.01 {
                    self.armHoverStillTimer(after: remain)
                    return
                }
                self.hoverStationary = true

                if !self.previewCard.isHidden && self.lastImageExact {
                    self.previewCard.revealExact()
                }
            }
        }
        timer.tolerance = 0.02
        hoverStillTimer = timer
    }

    private func cancelHoverStillness() {
        hoverStillTimer?.invalidate()
        hoverStillTimer = nil
        hoverStationary = false
    }

    private func endHover(animated: Bool) {
        let wasHovering = lastHoverX != nil
        lastHoverX = nil
        bubble.isHidden = true
        if animated { previewCard.hideAnimated() } else { previewCard.hideImmediate() }
        cancelHoverStillness()
        if wasHovering { onHoverExit?() }
    }

    func refreshHoverPreview() {
        guard let x = lastHoverX, !bubble.isHidden else { return }
        handleTrackHover(x, ratio: lastHoverRatio, pointerMoved: false, request: .none)
    }

#if !SP_APP_STORE

    enum TimelineSimPhase { case enter, move, press, drag, release, exit }
    func simulateTimelinePointer(_ phase: TimelineSimPhase, ratio: Double = 0) {
        let x = track.bounds.width * CGFloat(max(0, min(1, ratio)))
        switch phase {
        case .enter:   track.pointerEntered(atX: x)
        case .move:    track.pointerMoved(toX: x)
        case .press:   track.pointerPressed(atX: x)
        case .drag:    track.pointerDragged(toX: x)
        case .release: track.pointerReleased(atX: x)
        case .exit:    track.pointerExited()
        }
    }
#endif

    func refreshDust() {
        guard SPDustHost.enabled else { return }
        track.setDust(snapshot: dustSnapshotProvider?(), duration: durationProvider())
    }

    func refreshDamage() {
        if bubble.stateLabels.partial.isEmpty {
            bubble.stateLabels = (L("timeline.damage.partial"), L("timeline.damage.none"))
        }
        let snap = damageSnapshotProvider?()
        let gen = snap?.generation ?? 0
        if gen == damageGen && (snap != nil || damageBands.isEmpty) { return }
        damageGen = gen
        damageBands = SPDamage.bands(from: snap)
        track.setDamage(bands: damageBands, duration: durationProvider())
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The entire strip under the timeline belongs to controls, including the
    /// empty gaps and side margins. Keep this geometry available while hidden
    /// so a press which reveals chrome cannot also toggle the underlying video.
    func videoGestureExclusionRect(in targetView: NSView) -> NSRect {
        let height = max(0, min(bounds.height, track.frame.midY - bounds.minY))
        return convert(NSRect(x: bounds.minX, y: bounds.minY,
                              width: bounds.width, height: height), to: targetView)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        guard v === self else { return v }
        let local = convert(point, from: superview)
        return videoGestureExclusionRect(in: self).contains(local) ? self : nil
    }

    // Do not forward clicks on empty control chrome into the responder chain.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override var mouseDownCanMoveWindow: Bool { false }

    func layoutChrome(in parentBounds: NSRect) {
        let chromeFrame = NSRect(x: 0, y: 0, width: parentBounds.width, height: SPM.scrimH)
        let geometryChanged = frame != chromeFrame
        frame = chromeFrame
        noAnim { scrim.frame = bounds }

        if geometryChanged {
            endHover(animated: false)
            glowReset()
        }

        let colW = min(SPM.maxW, bounds.width - SPM.side * 2)
        let colX = (bounds.width - colW) / 2

        let byC = SPM.bot + SPM.btnRow / 2
        playBtn.frame = NSRect(x: colX, y: byC - SPM.btnMain / 2, width: SPM.btnMain, height: SPM.btnMain)
        turboRing.position = CGPoint(x: playBtn.frame.midX, y: playBtn.frame.midY)

        layoutRightControls()

        let ty = SPM.bot + SPM.btnRow + SPM.gapRT
        track.frame = NSRect(x: colX, y: ty, width: colW, height: SPM.trackRow)
    }

    func layout(in parentBounds: NSRect) {
        layoutChrome(in: parentBounds)
    }

    // Chrome is installed after the first frame. Measure its constant titles
    // once here; subsequent layout and FPS updates do no text measurement.
    private func prepareStableControlMetrics() {
        // Digits are monospaced and fmtRate emits at most two decimals. This
        // reserves every supported rate, including custom values between menu
        // entries, without a rate change moving the compact boundary.
        let widestRate = NSAttributedString(
            string: String(format: "%.2f×", PlayerCommandPolicy.playbackRateRange.upperBound),
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)])
        regularRateWidth = max(48, ceil(widestRate.size().width) + 16)
    }

    // Keep the quick actions reachable even while the volume rail is
    // open. Changed speed is the first optional item to yield in tight windows.
    private func layoutRightControls(animateVolume: Bool = false) {
        let colW = min(SPM.maxW, bounds.width - SPM.side * 2)
        let colX = (bounds.width - colW) / 2
        let byC = SPM.bot + SPM.btnRow / 2
        let compact = colW < 620
        let actionGap: CGFloat = compact ? 4 : SPM.gapIn
        volSlider.setCompact(compact)
        volumeGroup.needsLayout = true
        updateVolumeWidthTarget(volumeGroup.preferredVisualWidth, animated: animateVolume)
        visibleVolumeWidth = sampleVolumeWidth(at: ProcessInfo.processInfo.systemUptime)
        let volumeFrame = NSRect(x: playBtn.frame.maxX + SPM.gapIn,
                                 y: byC - SPM.btnRow / 2,
                                 width: visibleVolumeWidth,
                                 height: SPM.btnRow)
        volumeGroup.frame = volumeFrame
        volumeGroup.layoutSubtreeIfNeeded()
        var rx = colX + colW
        var rightActions: [NSButton] = [fsBtn, pipBtn, settingsBtn, subtitlesBtn]
        if SPFeatures.enhancements { rightActions.append(motionBtn) }
        rightActions.append(playlistBtn)
        motionBtn.setCompact(compact)
        for button in rightActions {
            let width = button === motionBtn ? motionBtn.preferredWidth : SPM.btnAux
            button.frame = NSRect(x: rx - width, y: byC - SPM.btnAux / 2,
                                   width: width, height: SPM.btnAux)
            rx = button.frame.minX - actionGap
        }
        let timeX = volumeFrame.maxX + 8
        let timeBudget = max(0, rx - 8 - timeX)
        let showRate = abs(currentRate - 1) > 0.0001
            && timeBudget >= timeLabel.preferredWidth + regularRateWidth + actionGap
        rateChip.isHidden = !showRate
        rateChip.frame = NSRect(x: rx - regularRateWidth, y: byC - SPM.btnAux / 2,
                                width: regularRateWidth, height: SPM.btnAux)
        if showRate { rx = rateChip.frame.minX - actionGap }
        timeLabel.frame = NSRect(x: timeX, y: byC - SPM.btnAux / 2,
                                 width: min(timeLabel.preferredWidth, max(0, rx - 8 - timeX)),
                                 height: SPM.btnAux)
    }

    // One clock drives the actual clip width and adjacent time position.
    // Timeline ticks can relayout without changing the transition's endpoint.
    private func updateVolumeWidthTarget(_ width: CGFloat, animated: Bool) {
        guard abs(width - targetVolumeWidth) > 0.001 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        visibleVolumeWidth = sampleVolumeWidth(at: now)
        targetVolumeWidth = width
        guard animated, !isHidden, volumeGroup.superview != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            volumeWidthTransition = nil
            volumeAnimationTimer?.invalidate()
            volumeAnimationTimer = nil
            visibleVolumeWidth = width
            return
        }
        volumeWidthTransition = VolumeWidthTransition(start: visibleVolumeWidth,
                                                       target: width, began: now)
        guard volumeAnimationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            let ownerExists = MainActor.assumeIsolated {
                guard let self else { return false }
                self.advanceVolumeAnimation()
                return true
            }
            if !ownerExists { timer.invalidate() }
        }
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        volumeAnimationTimer = timer
    }

    private func sampleVolumeWidth(at now: TimeInterval) -> CGFloat {
        guard let transition = volumeWidthTransition else { return visibleVolumeWidth }
        let fraction = min(1, max(0, (now - transition.began) / transition.duration))
        let eased = fraction * fraction * (3 - 2 * fraction)
        return transition.start + (transition.target - transition.start) * CGFloat(eased)
    }

    private func advanceVolumeAnimation() {
        guard let transition = volumeWidthTransition else { return }
        let now = ProcessInfo.processInfo.systemUptime
        visibleVolumeWidth = sampleVolumeWidth(at: now)
        if now - transition.began >= transition.duration {
            visibleVolumeWidth = transition.target
            volumeWidthTransition = nil
            volumeAnimationTimer?.invalidate()
            volumeAnimationTimer = nil
        }
        layoutRightControls()
    }

    var ownsKeyboardFocus: Bool {
        volumeGroup.hasFocusedControl || timeLabel.hasInteractionFocus || motionBtn.hasInteractionFocus || pipBtn.hasInteractionFocus
    }

    func settingsButtonRect(in parent: NSView) -> NSRect {
        settingsBtn.convert(settingsBtn.bounds, to: parent)
    }

    func settingsMenuAnchorRect(in parent: NSView) -> NSRect {
        let button = settingsButtonRect(in: parent)
        let timeline = track.convert(track.bounds, to: parent)
        return NSRect(x: button.minX, y: button.minY, width: button.width,
                      height: max(button.maxY, timeline.maxY) - button.minY)
    }

    func playlistButtonRect(in parent: NSView) -> NSRect {
        playlistBtn.convert(playlistBtn.bounds, to: parent)
    }

    func playlistMenuAnchorRect(in parent: NSView) -> NSRect {
        let button = playlistButtonRect(in: parent)
        let timeline = track.convert(track.bounds, to: parent)
        return NSRect(x: button.minX, y: button.minY, width: button.width,
                      height: max(button.maxY, timeline.maxY) - button.minY)
    }

    func render(_ presentation: ChromePresentation) {
        let previous = lastRenderedModel
        let pipAvailable = presentation.motion.hasMedia &&
            (presentation.lifecycle == .playing || presentation.lifecycle == .paused || presentation.lifecycle == .ended)
        pipBtn.isEnabled = pipAvailable
        pipBtn.alphaValue = pipAvailable ? 1 : 0.4
        if previous == nil || previous?.position != presentation.position ||
           previous?.duration != presentation.duration ||
           previous?.playbackRate != presentation.playbackRate {
            setTime(position: presentation.position, duration: presentation.duration,
                    rate: presentation.playbackRate)
        }
        if previous == nil || previous?.isPlaying != presentation.isPlaying {
            setPlaying(presentation.isPlaying)
        }
        // Apply boost state before value so values above 100 are not clamped.
        if previous == nil || previous?.volumeBoost != presentation.volumeBoost {
            setVolumeBoost(presentation.volumeBoost)
        }
        if previous == nil || previous?.volumePercent != presentation.volumePercent ||
           previous?.isMuted != presentation.isMuted {
            setVolume(pct: presentation.volumePercent, muted: presentation.isMuted)
        }
        if previous == nil || previous?.hdrDescription != presentation.hdrDescription ||
           previous?.hdrDetail != presentation.hdrDetail {
            setHDRBadge(presentation.hdrDescription, detail: presentation.hdrDetail)
        }
        if previous == nil || previous?.motion != presentation.motion {
            setMotionSmoothing(presentation.motion)
        }
        if previous == nil || previous?.xdr != presentation.xdr {
            setXDR(presentation.xdr)
        }
        lastRenderedModel = presentation
    }

    func show() {
        refreshDust()
        isHidden = false
        glowReset() // Rebuild hover state on the next enter.
        renderLatestPresentation()
        motionBtn.setEffectsVisible(true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            animator().alphaValue = 1
        }
    }

    func hide() {
        motionBtn.setEffectsVisible(false)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.alphaValue == 0 else { return }
            self.isHidden = true
#if !SP_APP_STORE
            if Self.audit, let root = self.superview?.layer {
                let names = (root.sublayers ?? []).filter { !$0.isHidden }
                    .map { String(describing: type(of: $0)) }
                NSLog("[UI审计] chrome 隐藏后可见层: %@", names.joined(separator: ", "))
            }
#endif
        })
    }

    func setTime(position: Double, duration: Double, rate: Double) {
        latestDuration = SPPlaybackTimeButton.normalizedSeconds(duration)
        latestPosition = latestDuration > 0
            ? min(latestDuration, SPPlaybackTimeButton.normalizedSeconds(position))
            : SPPlaybackTimeButton.normalizedSeconds(position)
        currentRate = rate
        guard !isHidden else { return }
        renderLatestTime()
    }

    static func fmtRate(_ r: Double) -> String {
        if r == r.rounded() { return String(format: "%.0f×", r) }
        if (r * 10) == (r * 10).rounded() { return String(format: "%.1f×", r) }
        return String(format: "%.2f×", r)
    }

    func setHDRBadge(_ desc: String?, detail: String? = nil) {
        guard latestHDRDescription != desc || latestHDRDetail != detail else { return }
        latestHDRDescription = desc
        latestHDRDetail = detail
        guard !isHidden else { return }
    }

    func setMotionSmoothing(_ presentation: MotionPresentation) {
        guard presentation != motionPresentation else { return }
        motionPresentation = presentation
        guard !isHidden, turboFrozenMotion == nil else { return }
        applyMotionSmoothingAppearance()
        layoutRightControls()
    }

    private func applyMotionSmoothingAppearance() {
        guard SPFeatures.enhancements else { return }
        let presentation = turboFrozenMotion ?? motionPresentation
        let enabled = presentation.isControlEnabled && !turboLocked
        motionBtn.configure(presentation, interactionEnabled: enabled)
        var tip = "Motion+ · " + presentation.toolTip
        if let fps = presentation.fpsReadout { tip += " · " + fps + " fps" }
        motionBtn.toolTip = tip
        motionBtn.setAccessibilityValue(presentation.accessibilityValue)
        motionBtn.setAccessibilityHelp(tip)
    }

    func setXDR(_ presentation: XDRPresentation) {
        xdrPresentation = presentation
    }

    func setSubtitlesSelected(_ shown: Bool, available: Bool) {
        subtitlesBtn.showsSelection = shown
        subtitlesBtn.state = shown ? .on : .off
        subtitlesBtn.image = shown ? Self.subtitlesFilled : Self.subtitlesOutline
        subtitlesBtn.isEnabled = available
        subtitlesBtn.alphaValue = available ? 1 : 0.4
        let label = L("settings.subtitles")
        subtitlesBtn.toolTip = label
        subtitlesBtn.setAccessibilityLabel(label)
        subtitlesBtn.setAccessibilityValue(available
            ? (shown ? L("chrome.a11y.on") : L("chrome.a11y.off")) : L("chrome.a11y.unavailable"))
    }

    @objc private func rateTapped() {
        if let onSpeedSettings { onSpeedSettings(); return }
        let menu = NSMenu()
        for r in Self.rateOptions {
            let item = NSMenuItem(title: Self.fmtRate(r), action: #selector(rateMenuPicked(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = Int((r * 100).rounded())
            item.state = abs(r - currentRate) < 0.001 ? .on : .off
            menu.addItem(item)
        }
        // Anchor the final item so the menu opens upward from the bottom chrome.
        menu.popUp(positioning: menu.items.last,
                   at: NSPoint(x: 0, y: 0), in: rateChip)
    }

    @objc private func rateMenuPicked(_ sender: NSMenuItem) {
        onRateSelected?(Double(sender.tag) / 100.0)
    }

    private func setTimeLabels(position: Double, duration: Double) {
        timeLabel.configure(position: position, duration: duration)
    }

    func setPlaying(_ playing: Bool) {
        latestPlaying = playing
        guard !isHidden else { return }
        renderLatestPlaying()
    }

    /// The owner supplies actual cached media-time intervals normalized to the
    /// current duration. An empty visible cache is distinct from local media.
    func setBufferedRanges(_ ranges: [ClosedRange<Double>], visible: Bool) {
        track.setBufferedRanges(ranges, visible: visible)
        track.toolTip = visible ? L("timeline.cachedTooltip") : nil
    }

    func setVolume(pct: Double, muted: Bool) {
        latestVolumePct = pct
        latestMuted = muted
        guard !isHidden else { return }
        renderLatestVolume(animated: true)
    }

    func setVolumeBoost(_ presentation: VolumeBoostPresentation) {
        latestVolumeBoost = presentation
        guard !isHidden else { return }
        renderLatestVolumeBoost()
    }

    func cancelTransientInteraction() {
        track.cancelInteraction()
        volSlider.cancelInteraction()
        endHover(animated: false)
    }

    /// Play the boost invitation after keyboard release when eligible.
    func playVolumeBoostInvitation() {
        guard !isHidden else { return }
        volSlider.playBoostInvitation()
    }

    private func renderLatestPresentation() {
        renderLatestTime()
        renderLatestPlaying(animated: false)
        renderLatestVolumeBoost()
        renderLatestVolume(animated: false)
        applyMotionSmoothingAppearance()
        layoutRightControls()
    }

    private func renderLatestTime() {
        if latestDuration > 0 {
            track.setValue(latestPosition / latestDuration)
        } else {
            track.setValue(0)
        }
        setTimeLabels(position: latestPosition, duration: latestDuration)
        if currentRate != lastRenderedRate || latestTurbo != lastRenderedTurbo {
            lastRenderedRate = currentRate
            lastRenderedTurbo = latestTurbo
            rateChip.setText(Self.fmtRate(currentRate),
                             color: latestTurbo ? Self.turboAccent : .white)
            layoutRightControls()
        }
    }

    private var turboLocked = false

    private func setTurboLocked(_ locked: Bool) {
        guard locked != turboLocked else { return }
        turboLocked = locked
        for b in [rateChip] as [NSButton] {
            b.isEnabled = !locked
            b.alphaValue = locked ? 0.4 : 1
        }
        track.interactionLocked = locked

        turboFrozenMotion = locked ? motionPresentation : nil
        guard !isHidden else { return }
        applyMotionSmoothingAppearance()
        if !locked { layoutRightControls() }
    }

    func setTurboPhase(_ phase: SPTurboPhase) {
        setTurboLocked(phase != .idle)
        playBtn.setTurboPhase(phase, chargeDuration: SPTurboSpeed.holdThreshold)
        if phase == .active { fireTurboShockRing() }
        let on = phase == .active
        guard on != latestTurbo else { return }
        latestTurbo = on
        guard !isHidden else { return }
        renderLatestTime()
    }

    // Hidden-state replay reaches the final shape without a delayed morph.
    private func renderLatestPlaying(animated: Bool = true) {
        playBtn.setPlaying(latestPlaying, animated: animated)
    }

    private func renderLatestVolumeBoost() {
        switch latestVolumeBoost {
        case .normal:
            volSlider.setBoostPrompted(false)
            volSlider.setBoostUnlocked(false)
        case .prompted:
            volSlider.setBoostUnlocked(false)
            volSlider.setBoostPrompted(true)
        case .unlocked:
            volSlider.setBoostUnlocked(true)
            volSlider.setBoostPrompted(false)
        }
    }

    private func renderLatestVolume(animated: Bool) {
        volSlider.setValue(latestVolumePct, animated: animated)
        muteBtn.setSymbol(latestMuted || latestVolumePct == 0
                              ? "speaker.slash.fill" : "speaker.wave.2.fill",
                          pointSize: SPM.symAux)
    }

    private static func fmt(_ t: Double) -> String { SPTimeText.clock(t) }

    func setSettingsSelected(_ shown: Bool) {
        settingsBtn.showsSelection = shown
        settingsBtn.state = shown ? .on : .off
        settingsBtn.setSymbol(shown ? "gearshape.fill" : "gearshape", pointSize: SPM.symAux)
        let label = shown ? L("settings.close") : L("settings.title")
        settingsBtn.toolTip = label
        settingsBtn.setAccessibilityLabel(label)
    }

    func setPlaylistSelected(_ shown: Bool) {
        playlistBtn.showsSelection = shown
        playlistBtn.state = shown ? .on : .off
        playlistBtn.image = Self.playlistImage
        let label = L("control.playlist")
        playlistBtn.toolTip = label
        playlistBtn.setAccessibilityLabel(label)
        playlistBtn.setAccessibilityValue(shown ? L("chrome.a11y.on") : L("chrome.a11y.off"))
    }

    func setPictureInPictureSelected(_ selected: Bool) {
        pipBtn.showsSelection = selected
        pipBtn.state = selected ? .on : .off
        pipBtn.setSymbol(selected ? "pip.exit" : "pip.enter", pointSize: SPM.symAux)
        let label = selected ? L("video.pip.return") : L("video.context.pictureInPicture")
        pipBtn.toolTip = label
        pipBtn.setAccessibilityLabel(label)
        pipBtn.setAccessibilityValue(selected ? L("chrome.a11y.on") : L("chrome.a11y.off"))
    }

    @objc private func playTapped() { onPlayPause?() }
    @objc private func muteTapped() { onMute?() }
    @objc private func fsTapped() { onFullscreen?() }
    @objc private func pictureInPictureTapped() { onPictureInPicture?() }
    @objc private func settingsTapped() { onSettingsToggle?() }
    @objc private func playlistTapped() { onTogglePlaylist?() }
    @objc private func motionSmoothingTapped() { onMotionSmoothingToggle?() }
    @objc private func subtitlesTapped() { onSubtitlesToggle?() }
    @objc private func volChanged() { onVolume?(volSlider.volumePercent) }
}

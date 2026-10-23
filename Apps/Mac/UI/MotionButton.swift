import AppKit
import QuartzCore

/// Explicit environmental inputs keep the expensive-looking effect bounded to
/// the tiny control and prevent animation behind hidden playback chrome.
struct SPMotionEffectsGate {
    static func allowsAnimation(selected: Bool, enabled: Bool, effectsVisible: Bool,
                                attached: Bool, windowVisible: Bool, windowUnoccluded: Bool,
                                appActive: Bool, hidden: Bool, reduceMotion: Bool) -> Bool {
        selected && enabled && effectsVisible && attached && windowVisible
            && windowUnoccluded && appActive && !hidden && !reduceMotion
    }
}

/// Frame-generation control. All movement is composited by Core Animation;
/// no timer, display link, video readback or playback-engine work lives here.
@MainActor
final class SPMotionButton: NSButton, CAAnimationDelegate {
    private enum Palette {
        static let cyan = NSColor(srgbRed: 0.10, green: 0.83, blue: 0.98, alpha: 1)
        static let violet = NSColor(srgbRed: 0.47, green: 0.31, blue: 0.98, alpha: 1)
        static let pink = NSColor(srgbRed: 0.96, green: 0.25, blue: 0.69, alpha: 1)
    }
    private let surface = CALayer()
    private let liquid = CALayer()
    private let baseGradient = CAGradientLayer()
    private let cyanCloud = CAGradientLayer()
    private let pinkCloud = CAGradientLayer()
    private let borderHost = CALayer()
    private let borderGradient = CAGradientLayer()
    private let borderMask = CAShapeLayer()
    private let halo = CAShapeLayer()
    private let focusRing = CAShapeLayer()
    private let foreground = CALayer()
    private let frames = CAShapeLayer()
    private let sparkle = CAShapeLayer()
    private let orbitLights = [CALayer(), CALayer(), CALayer()]
    private var selected = false
    private var effectsVisible = false
    private var hovering = false
    private var keyboardFocused = false
    private var accessibilityFocused = false
    private var animationRunning = false
    private var introGeneration = 0
    private var previousRequested = false
    private var previousHadMedia = false
    private var previousInteractionEligible = false
    private var handledKeyUps = Set<UInt16>()
    private var tracking: NSTrackingArea?
    private var lastLayoutSize = NSSize.zero
    private var lastToolTip = ""
    var preferredWidth: CGFloat { 36 }
    var hasInteractionFocus: Bool { keyboardFocused || accessibilityFocused }
    override var acceptsFirstResponder: Bool { isEnabled && !refusesFirstResponder }
    override var mouseDownCanMoveWindow: Bool { false }
    override var isEnabled: Bool { didSet { updateAppearance(); updateEffectActivity() } }
    override var isHighlighted: Bool { didSet { updateAppearance() } }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 36, height: 32))
        title = "FPS+"
        imagePosition = .noImage
        isBordered = false
        focusRingType = .none
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.masksToBounds = false
        identifier = NSUserInterfaceItemIdentifier("chrome.motion")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(L("chrome.memc.a11y.label"))
        buildLayers()
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            center.addObserver(self, selector: #selector(environmentChanged(_:)), name: name, object: nil)
        }
        center.addObserver(self, selector: #selector(windowWillClose(_:)),
                           name: NSWindow.willCloseNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(environmentChanged(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        configure(.idle, interactionEnabled: false)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SPMotionButton: no coder path") }
    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func buildLayers() {
        guard let layer else { return }
        halo.fillColor = NSColor.clear.cgColor
        halo.strokeColor = Palette.violet.withAlphaComponent(0.28).cgColor
        halo.lineWidth = 1.2
        halo.shadowColor = Palette.cyan.cgColor
        halo.shadowOffset = .zero
        halo.shadowRadius = 7
        halo.shadowOpacity = 0.48
        layer.addSublayer(halo)
        surface.masksToBounds = true
        layer.addSublayer(surface)
        liquid.masksToBounds = true
        surface.addSublayer(liquid)
        baseGradient.colors = [
            NSColor(srgbRed: 0.06, green: 0.29, blue: 0.42, alpha: 1).cgColor,
            NSColor(srgbRed: 0.28, green: 0.16, blue: 0.57, alpha: 1).cgColor,
            NSColor(srgbRed: 0.47, green: 0.12, blue: 0.38, alpha: 1).cgColor,
        ]
        baseGradient.startPoint = CGPoint(x: 0, y: 0)
        baseGradient.endPoint = CGPoint(x: 1, y: 1)
        liquid.addSublayer(baseGradient)
        for (cloud, color) in [(cyanCloud, Palette.cyan), (pinkCloud, Palette.pink)] {
            cloud.type = .radial
            cloud.colors = [color.withAlphaComponent(0.72).cgColor, color.withAlphaComponent(0).cgColor]
            cloud.locations = [0, 1]
            cloud.startPoint = CGPoint(x: 0.5, y: 0.5)
            cloud.endPoint = CGPoint(x: 1, y: 1)
            liquid.addSublayer(cloud)
        }
        borderGradient.type = .conic
        borderGradient.colors = [Palette.cyan.cgColor, Palette.violet.cgColor, Palette.pink.cgColor,
                                 Palette.violet.cgColor, Palette.cyan.cgColor]
        borderGradient.locations = [0, 0.25, 0.5, 0.75, 1]
        borderGradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        borderGradient.endPoint = CGPoint(x: 1, y: 0.5)
        borderMask.fillColor = NSColor.clear.cgColor
        borderMask.strokeColor = NSColor.white.cgColor
        borderMask.lineWidth = 1
        borderHost.addSublayer(borderGradient)
        borderHost.mask = borderMask
        layer.addSublayer(borderHost)
        for (index, light) in orbitLights.enumerated() {
            let color = index == 0 ? Palette.cyan : (index == 1 ? Palette.pink : NSColor.white)
            light.backgroundColor = color.cgColor
            light.cornerRadius = index == 2 ? 0.75 : 1.1
            light.shadowColor = color.cgColor
            light.shadowRadius = 2.2
            light.shadowOpacity = 0.7
            light.shadowOffset = .zero
            layer.addSublayer(light)
        }
        layer.addSublayer(foreground)
        frames.strokeColor = NSColor.white.withAlphaComponent(0.95).cgColor
        frames.fillColor = NSColor.clear.cgColor
        frames.lineWidth = 1.2
        frames.lineCap = .round
        frames.lineJoin = .round
        foreground.addSublayer(frames)
        sparkle.fillColor = NSColor.white.cgColor
        foreground.addSublayer(sparkle)
        foreground.shadowColor = NSColor.black.cgColor
        foreground.shadowOpacity = 0.22
        foreground.shadowRadius = 0.8
        foreground.shadowOffset = CGSize(width: 0, height: -0.5)
        focusRing.fillColor = NSColor.clear.cgColor
        focusRing.strokeColor = NSColor.white.withAlphaComponent(0.8).cgColor
        focusRing.lineWidth = 1.4
        layer.addSublayer(focusRing)
    }

    // Retained for playback-chrome compatibility; this control is always icon-only.
    func setCompact(_ compact: Bool) { }
    func configure(_ presentation: MotionPresentation, interactionEnabled: Bool) {
        let nextSelected = presentation.visualState == .on
        let nextEnabled = presentation.isControlEnabled && interactionEnabled
        // Consume every request transition, including those made while hidden or
        // suspended. Restoring media, bypass recovery and Turbo unlock are static.
        let switchedOn = previousHadMedia && presentation.hasMedia
            && previousInteractionEligible && !previousRequested && presentation.requested
        previousRequested = presentation.requested
        previousHadMedia = presentation.hasMedia
        previousInteractionEligible = nextEnabled
        let appearanceChanged = selected != nextSelected || isEnabled != nextEnabled
        selected = nextSelected
        if isEnabled != nextEnabled { isEnabled = nextEnabled }
        state = selected ? .on : .off
        setAccessibilityValue(presentation.accessibilityValue)
        var tip = "Motion+ · " + presentation.toolTip
        if let fps = presentation.fpsReadout { tip += " · " + fps + " fps" }
        if tip != lastToolTip {
            lastToolTip = tip
            toolTip = tip
            setAccessibilityHelp(tip)
        }
        if appearanceChanged { updateAppearance() }
        updateEffectActivity()
        if switchedOn && permitsIntro {
            layoutSubtreeIfNeeded()
            startAnimations()
        }
    }
    func setEffectsVisible(_ visible: Bool) {
        guard visible != effectsVisible else { return }
        effectsVisible = visible
        updateEffectActivity()
    }
    private func updateAppearance() {
        guard wantsLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let highlighted = hovering || hasInteractionFocus || isHighlighted
        surface.backgroundColor = NSColor.white.withAlphaComponent(highlighted ? 0.12 : 0.065).cgColor
        surface.borderColor = NSColor.white.withAlphaComponent(highlighted ? 0.28 : 0.16).cgColor
        surface.borderWidth = selected ? 0 : 0.8
        liquid.isHidden = !selected
        borderHost.isHidden = !selected
        halo.isHidden = !animationRunning || !selected || !isEnabled
        for light in orbitLights {
            light.isHidden = !animationRunning || !selected || !isEnabled
            light.opacity = 0
        }
        foreground.opacity = isEnabled ? 1 : 0.42
        surface.opacity = isEnabled ? 1 : 0.48
        borderHost.opacity = isEnabled ? 0.9 : 0.3
        // Intro-only decorations must remain invisible when explicit fades
        // finish, even before their completion callback is delivered.
        halo.opacity = 0
        focusRing.isHidden = !hasInteractionFocus
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { stopAnimations(); return }
        let sizeChanged = lastLayoutSize != bounds.size
        lastLayoutSize = bounds.size
        let height = min(28, bounds.height)
        let body = CGRect(x: 2, y: (bounds.height - height) / 2,
                          width: max(0, bounds.width - 4), height: height)
        let radius: CGFloat = 8.5
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.frame = body
        surface.cornerRadius = radius
        liquid.frame = surface.bounds
        liquid.cornerRadius = radius
        baseGradient.frame = liquid.bounds
        let cloudSize = CGSize(width: max(48, body.width * 0.85), height: 64)
        cyanCloud.frame = CGRect(origin: CGPoint(x: -cloudSize.width * 0.16, y: -18), size: cloudSize)
        pinkCloud.frame = CGRect(origin: CGPoint(x: body.width - cloudSize.width * 0.82, y: -15), size: cloudSize)
        halo.frame = bounds
        let bodyPath = CGPath(roundedRect: body.insetBy(dx: -0.5, dy: -0.5), cornerWidth: radius + 0.5,
                              cornerHeight: radius + 0.5, transform: nil)
        halo.path = bodyPath
        halo.shadowPath = bodyPath
        borderHost.frame = body
        borderMask.frame = borderHost.bounds
        borderMask.path = CGPath(roundedRect: borderHost.bounds.insetBy(dx: 0.5, dy: 0.5),
                                 cornerWidth: radius, cornerHeight: radius, transform: nil)
        let side = max(60, body.width * 2)
        borderGradient.frame = CGRect(x: (body.width - side) / 2, y: (body.height - side) / 2, width: side, height: side)
        foreground.frame = bounds
        let glyphX = (bounds.width - 22) / 2
        let glyphY = (bounds.height - 20) / 2
        frames.frame = CGRect(x: glyphX, y: glyphY, width: 22, height: 20)
        let framesPath = CGMutablePath()
        framesPath.addRoundedRect(in: CGRect(x: 0.7, y: 6.5, width: 12, height: 9.5), cornerWidth: 1.7, cornerHeight: 1.7)
        framesPath.addRoundedRect(in: CGRect(x: 5.5, y: 2, width: 12.5, height: 9.5), cornerWidth: 1.7, cornerHeight: 1.7)
        frames.path = framesPath
        sparkle.frame = frames.frame
        let star = CGMutablePath()
        let center = CGPoint(x: 18.2, y: 16)
        star.move(to: CGPoint(x: center.x, y: center.y + 4))
        star.addQuadCurve(to: CGPoint(x: center.x + 3.4, y: center.y), control: CGPoint(x: center.x + 0.8, y: center.y + 0.7))
        star.addQuadCurve(to: CGPoint(x: center.x, y: center.y - 4), control: CGPoint(x: center.x + 0.8, y: center.y - 0.7))
        star.addQuadCurve(to: CGPoint(x: center.x - 3.4, y: center.y), control: CGPoint(x: center.x - 0.8, y: center.y - 0.7))
        star.addQuadCurve(to: CGPoint(x: center.x, y: center.y + 4), control: CGPoint(x: center.x - 0.8, y: center.y + 0.7))
        star.closeSubpath()
        sparkle.path = star
        for (index, light) in orbitLights.enumerated() {
            let diameter: CGFloat = index == 2 ? 1.5 : 2.2
            light.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            light.position = [CGPoint(x: body.minX + 11, y: body.maxY),
                              CGPoint(x: body.maxX - 7, y: body.minY),
                              CGPoint(x: body.midX + 6, y: body.maxY)][index]
        }
        focusRing.frame = bounds
        focusRing.path = CGPath(roundedRect: body.insetBy(dx: -1.8, dy: -1.8),
                                cornerWidth: radius + 1.8, cornerHeight: radius + 1.8, transform: nil)
        updateContentsScale()
        CATransaction.commit()
        updateAppearance()
        if sizeChanged && animationRunning { stopAnimations() }
        updateEffectActivity()
    }
    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for drawing in [frames, sparkle, borderMask, halo, focusRing] { drawing.contentsScale = scale }
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
        needsLayout = true
        updateEffectActivity()
    }
    override func viewDidHide() { super.viewDidHide(); updateEffectActivity() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateEffectActivity() }
    @objc nonisolated private func environmentChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.updateEffectActivity() }
    }
    @objc private func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        effectsVisible = false
        stopAnimations()
    }
    private var permitsIntro: Bool {
        SPMotionEffectsGate.allowsAnimation(
            selected: selected, enabled: isEnabled, effectsVisible: effectsVisible,
            attached: window != nil, windowVisible: window?.isVisible == true,
            windowUnoccluded: window?.occlusionState.contains(.visible) == true,
            appActive: NSApplication.shared.isActive, hidden: isHiddenOrHasHiddenAncestor,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
    private func updateEffectActivity() {
        // Visibility changes can cancel an introduction, but never replay one.
        if !permitsIntro { stopAnimations() }
    }
    private func startAnimations() {
        guard !animationRunning, bounds.width > 0, bounds.height > 0 else { return }
        animationRunning = true
        introGeneration &+= 1
        updateAppearance()
        let duration = 0.8
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = -Double.pi * 0.8
        rotation.toValue = 0
        rotation.duration = duration
        rotation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        rotation.delegate = self
        rotation.setValue(introGeneration, forKey: "motionIntroGeneration")
        borderGradient.add(rotation, forKey: "motion.border.intro")
        for (index, cloud) in [cyanCloud, pinkCloud].enumerated() {
            let origin = cloud.position
            let direction: CGFloat = index == 0 ? 1 : -1
            let drift = CAKeyframeAnimation(keyPath: "position")
            drift.values = [NSValue(point: CGPoint(x: origin.x - 12 * direction, y: origin.y - 3)),
                            NSValue(point: CGPoint(x: origin.x + 7 * direction, y: origin.y + 2)),
                            NSValue(point: origin)]
            drift.keyTimes = [0, 0.45, 1]
            drift.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            drift.duration = duration
            cloud.add(drift, forKey: "motion.liquid.intro")
        }
        let aura = CAKeyframeAnimation(keyPath: "opacity")
        aura.values = [0, 0.95, 0]
        aura.keyTimes = [0, 0.25, 1]
        aura.duration = duration
        halo.add(aura, forKey: "motion.halo.intro")
        let path = CGPath(roundedRect: surface.frame.insetBy(dx: -1.5, dy: -1.5),
                          cornerWidth: 10, cornerHeight: 10, transform: nil)
        for (index, light) in orbitLights.enumerated() {
            let orbit = CAKeyframeAnimation(keyPath: "position")
            orbit.path = path
            orbit.calculationMode = .paced
            orbit.duration = duration
            orbit.timeOffset = Double(index) * 0.11
            light.add(orbit, forKey: "motion.light.intro")
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0.8, 0]
            fade.keyTimes = [0, 0.2, 1]
            fade.duration = duration
            light.add(fade, forKey: "motion.light.fade")
        }
    }
    nonisolated func animationDidStop(_ animation: CAAnimation, finished flag: Bool) {
        guard flag, let generation = animation.value(forKey: "motionIntroGeneration") as? Int else { return }
        Task { @MainActor [weak self] in
            guard let self, self.animationRunning, self.introGeneration == generation else { return }
            self.stopAnimations()
        }
    }
    private func stopAnimations() {
        guard animationRunning else { return }
        animationRunning = false
        introGeneration &+= 1
        for animated in [borderGradient, cyanCloud, pinkCloud, halo] + orbitLights { animated.removeAllAnimations() }
        updateAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        tracking = area
        addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; updateAppearance() }
    override func mouseExited(with event: NSEvent) { hovering = false; updateAppearance() }
    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        keyboardFocused = true
        updateAppearance()
        return true
    }
    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        keyboardFocused = false
        updateAppearance()
        return true
    }
    override func setAccessibilityFocused(_ focused: Bool) {
        super.setAccessibilityFocused(focused)
        accessibilityFocused = focused
        updateAppearance()
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let previousResponder = window?.firstResponder
        let priorRefusal = refusesFirstResponder
        refusesFirstResponder = true
        defer {
            refusesFirstResponder = priorRefusal
            if previousResponder !== self, window?.firstResponder === self { window?.makeFirstResponder(previousResponder) }
            state = selected ? .on : .off
        }
        super.mouseDown(with: event)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 49 || event.keyCode == 36 || event.keyCode == 76 else {
            super.keyDown(with: event)
            return
        }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            nextResponder?.keyDown(with: event)
            return
        }
        handledKeyUps.insert(event.keyCode)
        guard !event.isARepeat else { return }
        performClick(nil)
    }
    override func keyUp(with event: NSEvent) {
        if handledKeyUps.remove(event.keyCode) != nil { return }
        super.keyUp(with: event)
    }
    override func performClick(_ sender: Any?) {
        guard isEnabled else { return }
        sendAction(action, to: target)
        state = selected ? .on : .off
    }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil)
        return true
    }
    override func draw(_ dirtyRect: NSRect) { }
}

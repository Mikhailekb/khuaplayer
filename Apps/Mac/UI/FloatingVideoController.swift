import AppKit
import QuartzCore

/// Cache coverage is already mapped to media time by the owner. These helpers
/// only sanitize display geometry; they never estimate time from file size.
enum SPBufferedTimeline {
    static func normalized(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        let clipped = ranges.compactMap { range -> ClosedRange<Double>? in
            guard range.lowerBound.isFinite, range.upperBound.isFinite else { return nil }
            let lower = max(0, range.lowerBound), upper = min(1, range.upperBound)
            return upper > lower ? lower...upper : nil
        }.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for range in clipped {
            if let previous = merged.last, range.lowerBound <= previous.upperBound {
                merged[merged.count - 1] = previous.lowerBound...max(previous.upperBound, range.upperBound)
            } else { merged.append(range) }
        }
        return merged
    }
}

/// The floating window keeps the existing Metal view and decoder. Its controls
/// send ordinary playback commands back to the owning player.
@MainActor
final class SPFloatingVideoController: NSObject, NSWindowDelegate {
    var onTogglePlayback: (() -> Void)?
    var onSeek: ((Double) -> Void)?
    var onVolumeChange: ((Double) -> Void)?
    var onToggleMute: (() -> Void)?
    var onFocusLoss: (() -> Void)?
    var onLayoutChange: (() -> Void)?
    var onDidRestore: (() -> Void)?

    var isActive: Bool { panel != nil && videoView != nil }
    var window: NSWindow? { panel }

    private var panel: SPFloatingVideoPanel?
    private var content: SPFloatingVideoContent?
    private var videoView: NSView?
    private weak var originalParent: NSView?
    private weak var originalNextSibling: NSView?
    private weak var originalWindow: NSWindow?
    private var originalFrame: NSRect = .zero
    private var originalAutoresizing: NSView.AutoresizingMask = []
    private var aspectRatio: CGFloat = 16 / 9
    private var presentsWindow = true
    private var playback = SPFloatingVideoPlayback()
    private var bufferedRanges: [ClosedRange<Double>] = []
    private var showsBufferedRanges = false
    private var closingPanel = false

    @discardableResult
    func present(videoView: NSView, aspectRatio: CGFloat, sourceWindow: NSWindow?,
                 showWindow: Bool = true) -> Bool {
        if isActive { return self.videoView === videoView }
        guard let parent = videoView.superview else { return false }
        self.videoView = videoView
        originalParent = parent
        originalWindow = sourceWindow ?? videoView.window
        originalFrame = videoView.frame
        originalAutoresizing = videoView.autoresizingMask
        if let index = parent.subviews.firstIndex(of: videoView), index + 1 < parent.subviews.count {
            originalNextSibling = parent.subviews[index + 1]
        }
        self.aspectRatio = aspectRatio.isFinite && aspectRatio > 0 ? min(4, max(0.25, aspectRatio)) : 16 / 9
        presentsWindow = showWindow
        let visible = (sourceWindow?.screen ?? NSScreen.main)?.visibleFrame ??
            NSRect(x: 0, y: 0, width: 1280, height: 800)
        let maximumHeight = max(180, visible.height * 0.65)
        let width = min(420, max(280, visible.width * 0.26), maximumHeight * self.aspectRatio)
        let size = NSSize(width: width, height: width / self.aspectRatio)
        let frame = NSRect(x: max(visible.minX, visible.maxX - size.width - 24),
                           y: visible.minY + 48, width: size.width, height: size.height)
        let panel = SPFloatingVideoPanel(contentRect: frame,
            styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.acceptsMouseMovedEvents = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let minimumWidth = min(280, max(160, maximumHeight * self.aspectRatio))
        panel.contentMinSize = NSSize(width: minimumWidth, height: minimumWidth / self.aspectRatio)
        panel.contentAspectRatio = NSSize(width: self.aspectRatio, height: 1)
        panel.delegate = self
        panel.title = sourceWindow?.title ?? ""
        panel.setAccessibilityIdentifier("sp.floatingVideoWindow")
        self.panel = panel

        let content = SPFloatingVideoContent(frame: NSRect(origin: .zero, size: size))
        content.onTogglePlayback = { [weak self] in self?.onTogglePlayback?() }
        content.onSeek = { [weak self] in self?.onSeek?($0) }
        content.onVolumeChange = { [weak self] in self?.onVolumeChange?($0) }
        content.onToggleMute = { [weak self] in self?.onToggleMute?() }
        content.onReturn = { [weak self] in self?.returnToPlayer() }
        content.onClose = { [weak self] in self?.returnToPlayer() }
        self.content = content
        videoView.removeFromSuperview()
        videoView.autoresizingMask = []
        content.attach(videoView)
        panel.contentView = content
        content.update(playback)
        content.setBufferedRanges(bufferedRanges, visible: showsBufferedRanges)
        content.layoutSubtreeIfNeeded()
        if showWindow { panel.orderFront(nil) }
        onLayoutChange?()
        return true
    }

    /// Session teardown restores the view without activating another window.
    func restore() {
        guard let panel else { return }
        onFocusLoss?()
        let video = videoView
        let parent = originalParent
        let next = originalNextSibling
        panel.delegate = nil
        content?.cancelPendingHide()
        video?.removeFromSuperview()
        if let video, let parent {
            if let next, next.superview === parent {
                parent.addSubview(video, positioned: .below, relativeTo: next)
            } else {
                parent.addSubview(video, positioned: .below, relativeTo: parent.subviews.first)
            }
            video.autoresizingMask = originalAutoresizing
            video.frame = originalFrame
        }
        self.panel = nil
        content = nil
        videoView = nil
        originalParent = nil
        originalNextSibling = nil
        originalWindow = nil
        if !closingPanel { panel.close() }
        onLayoutChange?()
        onDidRestore?()
    }

    func update(isPlaying: Bool) {
        playback.isPlaying = isPlaying
        content?.update(playback)
        content?.setBufferedRanges(bufferedRanges, visible: showsBufferedRanges)
    }

    func setBufferedRanges(_ ranges: [ClosedRange<Double>], visible: Bool) {
        bufferedRanges = visible ? SPBufferedTimeline.normalized(ranges) : []
        showsBufferedRanges = visible
        content?.setBufferedRanges(bufferedRanges, visible: visible)
    }

    func update(isPlaying: Bool, position: Double, duration: Double,
                volumePercent: Double, muted: Bool) {
        playback = SPFloatingVideoPlayback(isPlaying: isPlaying, position: position,
            duration: duration, volumePercent: volumePercent, muted: muted)
        content?.update(playback)
        content?.setBufferedRanges(bufferedRanges, visible: showsBufferedRanges)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        closingPanel = true
        returnToPlayer()
        closingPanel = false
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        onFocusLoss?()
    }

    func windowDidResize(_ notification: Notification) {
        content?.needsLayout = true
        content?.layoutSubtreeIfNeeded()
        onLayoutChange?()
    }

    func windowDidChangeScreen(_ notification: Notification) { onLayoutChange?() }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let previous = sender.contentView?.bounds.size ?? .zero
        var proposed = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let vertical = abs(proposed.height - previous.height) > abs(proposed.width - previous.width)
        let minimumWidth = sender.contentMinSize.width
        proposed.width = max(minimumWidth, vertical ? proposed.height * aspectRatio : proposed.width)
        proposed.height = proposed.width / aspectRatio
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: proposed)).size
    }

    private func returnToPlayer() {
        let source = originalWindow
        let shouldPresent = presentsWindow
        restore()
        if shouldPresent {
            source?.deminiaturize(nil)
            source?.makeKeyAndOrderFront(nil)
        }
    }
}

private struct SPFloatingVideoPlayback {
    var isPlaying = false
    var position: Double = 0
    var duration: Double = 0
    var volumePercent: Double = 100
    var muted = false
}

@MainActor
private final class SPFloatingVideoPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class SPFloatingVideoContent: NSView {
    var onTogglePlayback: (() -> Void)?
    var onSeek: ((Double) -> Void)?
    var onVolumeChange: ((Double) -> Void)?
    var onToggleMute: (() -> Void)?
    var onReturn: (() -> Void)?
    var onClose: (() -> Void)?
    private weak var video: NSView?
    private let controls = SPFloatingVideoControls()
    private let playPause = NSButton()
    private let returnButton = NSButton()
    private let closeButton = NSButton()
    private let muteButton = NSButton()
    private let volume = SPFloatingVideoSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let timeline = SPFloatingVideoSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let currentTime = NSTextField(labelWithString: "0:00")
    private let totalTime = NSTextField(labelWithString: "0:00")
    private let dragArea = SPFloatingVideoDragArea()
    private var playback = SPFloatingVideoPlayback()
    private var hovered = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        configure(playPause, symbol: "play.fill", title: L("video.pip.playPause"),
                  identifier: "sp.floatingVideo.playPause", action: #selector(togglePlayback), pointSize: 34)
        configure(returnButton, symbol: "pip.exit", title: L("video.pip.return"),
                  identifier: "sp.floatingVideo.return", action: #selector(returnVideo))
        configure(closeButton, symbol: "xmark", title: L("video.pip.close"),
                  identifier: "sp.floatingVideo.close", action: #selector(closeVideo))
        configure(muteButton, symbol: "speaker.wave.2", title: L("settings.mute"),
                  identifier: "sp.floatingVideo.mute", action: #selector(toggleMute))
        volume.target = self
        volume.action = #selector(changeVolume)
        volume.isContinuous = true
        volume.setAccessibilityIdentifier("sp.floatingVideo.volume")
        volume.setAccessibilityLabel(L("chrome.volume.a11y.label"))
        timeline.target = self
        timeline.action = #selector(seek)
        timeline.isContinuous = false
        timeline.setAccessibilityIdentifier("sp.floatingVideo.timeline")
        timeline.setAccessibilityLabel(L("video.pip.seek"))
        timeline.onTrackingChange = { [weak self] _ in
            guard let self else { return }
            self.updateControlsVisibility()
        }
        volume.onTrackingChange = timeline.onTrackingChange
        for slider in [volume, timeline] { controls.addSubview(slider) }
        for (label, identifier) in [(currentTime, "sp.floatingVideo.currentTime"), (totalTime, "sp.floatingVideo.totalTime")] {
            label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            label.textColor = .white
            label.isSelectable = false
            label.setAccessibilityIdentifier(identifier)
            controls.addSubview(label)
        }
        totalTime.alignment = .right
        addSubview(dragArea)
        addSubview(controls)
        controls.receivesInput = false
        controls.alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; updateControlsVisibility() }
    override func mouseMoved(with event: NSEvent) { hovered = true; updateControlsVisibility() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateControlsVisibility() }

    func attach(_ view: NSView) {
        video = view
        addSubview(view, positioned: .below, relativeTo: dragArea)
        needsLayout = true
    }

    func update(_ value: SPFloatingVideoPlayback) {
        playback = value
        let duration = value.duration.isFinite && value.duration > 0 ? value.duration : 0
        if !timeline.isTracking {
            timeline.maxValue = duration > 0 ? duration : 1
            timeline.doubleValue = value.position.isFinite ? min(duration, max(0, value.position)) : 0
        }
        timeline.isEnabled = duration > 0
        currentTime.stringValue = Self.clock(timeline.doubleValue)
        totalTime.stringValue = Self.clock(duration)
        if !volume.isTracking {
            volume.doubleValue = value.volumePercent.isFinite ? min(100, max(0, value.volumePercent)) : 100
        }
        muteButton.image = NSImage(systemSymbolName: value.muted || volume.doubleValue == 0 ? "speaker.slash" : "speaker.wave.2",
                                   accessibilityDescription: L("settings.mute"))
        playPause.image = NSImage(systemSymbolName: value.isPlaying ? "pause.fill" : "play.fill",
                                  accessibilityDescription: L("video.pip.playPause"))?
            .withSymbolConfiguration(.init(pointSize: 34, weight: .regular))
        updateControlsVisibility()
    }

    func setBufferedRanges(_ ranges: [ClosedRange<Double>], visible: Bool) {
        let show = visible && playback.duration.isFinite && playback.duration > 0
        timeline.setBufferedRanges(ranges, visible: show)
        timeline.toolTip = show ? L("timeline.cachedTooltip") : nil
    }

    override func layout() {
        super.layout()
        video?.frame = bounds
        controls.frame = bounds
        let top = max(0, bounds.height - 38)
        closeButton.frame = NSRect(x: 6, y: top, width: 32, height: 32)
        returnButton.frame = NSRect(x: 40, y: top, width: 32, height: 32)
        let volumeWidth = min(100, max(60, bounds.width * 0.23))
        volume.frame = NSRect(x: bounds.width - volumeWidth - 12, y: top + 6, width: volumeWidth, height: 20)
        muteButton.frame = NSRect(x: volume.frame.minX - 36, y: top, width: 32, height: 32)
        playPause.frame = NSRect(x: bounds.midX - 30, y: bounds.midY - 30, width: 60, height: 60)
        currentTime.frame = NSRect(x: 12, y: 22, width: max(55, bounds.width / 2 - 20), height: 20)
        totalTime.frame = NSRect(x: bounds.midX, y: 22, width: max(55, bounds.width / 2 - 12), height: 20)
        timeline.frame = NSRect(x: 10, y: 4, width: max(0, bounds.width - 20), height: 20)
        dragArea.frame = NSRect(x: 0, y: max(0, bounds.height - 26), width: bounds.width, height: 26)
        controls.needsLayout = true
    }

    func cancelPendingHide() {
        controls.layer?.removeAllAnimations()
    }

    private func updateControlsVisibility() {
        setControlsVisible(hovered || timeline.isTracking || volume.isTracking)
    }

    private func setControlsVisible(_ visible: Bool) {
        guard controls.receivesInput != visible || controls.alphaValue != (visible ? 1 : 0) else { return }
        controls.receivesInput = visible
        controls.layer?.removeAllAnimations()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
            controls.animator().alphaValue = visible ? 1 : 0
        }
    }

    private func configure(_ button: NSButton, symbol: String, title: String,
                           identifier: String, action: Selector, pointSize: CGFloat = 20) {
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .white
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier(identifier)
        button.target = self
        button.action = action
        controls.addSubview(button)
    }

    private static func clock(_ value: Double) -> String {
        let seconds = value.isFinite ? max(0, Int(min(Double(Int.max / 2), value))) : 0
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    @objc private func togglePlayback() { onTogglePlayback?() }
    @objc private func returnVideo() { onReturn?() }
    @objc private func closeVideo() { onClose?() }
    @objc private func toggleMute() { onToggleMute?() }
    @objc private func changeVolume() { onVolumeChange?(volume.doubleValue) }
    @objc private func seek() {
        guard timeline.isEnabled else { return }
        currentTime.stringValue = Self.clock(timeline.doubleValue)
        onSeek?(timeline.doubleValue)
    }
}

@MainActor
private final class SPFloatingVideoControls: NSView {
    var receivesInput = true
    private let shade = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shade.colors = [NSColor.black.withAlphaComponent(0.45).cgColor, NSColor.clear.cgColor,
                        NSColor.clear.cgColor, NSColor.black.withAlphaComponent(0.5).cgColor]
        shade.locations = [0, 0.25, 0.65, 1]
        shade.startPoint = CGPoint(x: 0.5, y: 1)
        shade.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(shade)
        setAccessibilityIdentifier("sp.floatingVideo.controls")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); shade.frame = bounds }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard receivesInput, let hit = super.hitTest(point), hit is NSControl, !(hit is NSTextField) else { return nil }
        return hit
    }
}

@MainActor
final class SPFloatingVideoSlider: NSSlider {
    var isTracking = false
    var onTrackingChange: ((Bool) -> Void)?

    func setBufferedRanges(_ ranges: [ClosedRange<Double>], visible: Bool) {
        guard let cell = cell as? SPFloatingVideoSliderCell else { return }
        let normalized = visible ? SPBufferedTimeline.normalized(ranges) : []
        guard cell.bufferedRanges != normalized || cell.showsBufferedRanges != visible else { return }
        cell.bufferedRanges = normalized
        cell.showsBufferedRanges = visible
        needsDisplay = true
    }

    override init(frame: NSRect) { super.init(frame: frame); cell = SPFloatingVideoSliderCell() }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }
    func beginTracking() { isTracking = true; onTrackingChange?(true) }
    func endTracking() { isTracking = false; onTrackingChange?(false) }
    override func mouseDown(with event: NSEvent) {
        beginTracking()
        defer { endTracking() }
        super.mouseDown(with: event)
    }
}

@MainActor
private final class SPFloatingVideoSliderCell: NSSliderCell {
    var bufferedRanges: [ClosedRange<Double>] = []
    var showsBufferedRanges = false
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        // Native slider tracking leaves half a knob at both ends. Use the same
        // travel range for the painted rail, then the native rounded position
        // for the fill endpoint instead of a second full-width calculation.
        let nativeKnob = knobRect(flipped: flipped)
        let inset = min(max(0, rect.width / 2), nativeKnob.width / 2)
        let track = NSRect(x: rect.minX + inset, y: rect.midY - 1.5,
                           width: max(0, rect.width - 2 * inset), height: 3)
        NSColor.white.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
        if showsBufferedRanges {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).addClip()
            NSColor.white.withAlphaComponent(0.66).setFill()
            for range in bufferedRanges {
                NSRect(x: track.minX + track.width * range.lowerBound, y: track.minY,
                       width: track.width * (range.upperBound - range.lowerBound), height: track.height).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        let end = min(track.maxX, max(track.minX, nativeKnob.midX))
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY,
            width: max(0, end - track.minX), height: track.height), xRadius: 1.5, yRadius: 1.5).fill()
    }
    override func drawKnob(_ rect: NSRect) {
        let knob = NSRect(x: rect.midX - 3.5, y: rect.midY - 3.5, width: 7, height: 7)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
    }
}

@MainActor
private final class SPFloatingVideoDragArea: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

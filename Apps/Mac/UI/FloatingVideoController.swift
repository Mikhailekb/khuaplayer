import AppKit

/// An app-managed floating video window using the existing Metal view.
/// Moving the view preserves the decoder, torrent session and display colors.
@MainActor
final class SPFloatingVideoController: NSObject, NSWindowDelegate {
    var onTogglePlayback: (() -> Void)?
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
    private var playing = false
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

        let screen = sourceWindow?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        var width = min(420, max(280, visible.width * 0.26))
        let maximumHeight = max(180, visible.height * 0.65)
        if width / self.aspectRatio + SPFloatingVideoContent.controlsHeight > maximumHeight {
            width = max(160, (maximumHeight - SPFloatingVideoContent.controlsHeight) * self.aspectRatio)
        }
        let size = NSSize(width: width, height: width / self.aspectRatio + SPFloatingVideoContent.controlsHeight)
        let frame = NSRect(x: max(visible.minX, visible.maxX - size.width - 24),
                           y: visible.minY + 48, width: size.width, height: size.height)
        let panel = SPFloatingVideoPanel(contentRect: frame,
                                        styleMask: [.borderless, .resizable, .nonactivatingPanel],
                                        backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.backgroundColor = .black
        panel.contentMinSize = NSSize(width: 160, height: 160 / self.aspectRatio + SPFloatingVideoContent.controlsHeight)
        panel.delegate = self
        panel.title = sourceWindow?.title ?? ""
        panel.setAccessibilityIdentifier("sp.floatingVideoWindow")
        self.panel = panel

        let content = SPFloatingVideoContent(frame: NSRect(origin: .zero, size: size))
        content.onTogglePlayback = { [weak self] in self?.onTogglePlayback?() }
        content.onReturn = { [weak self] in self?.returnToPlayer() }
        content.onClose = { [weak self] in self?.returnToPlayer() }
        self.content = content
        videoView.removeFromSuperview()
        videoView.autoresizingMask = []
        content.attach(videoView)
        panel.contentView = content
        content.update(isPlaying: playing)
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
        playing = isPlaying
        content?.update(isPlaying: isPlaying)
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

    func windowDidChangeScreen(_ notification: Notification) {
        onLayoutChange?()
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let previous = sender.contentView?.bounds.size ?? .zero
        var proposed = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let vertical = abs(proposed.height - previous.height) > abs(proposed.width - previous.width)
        if vertical {
            proposed.width = max(160, (proposed.height - SPFloatingVideoContent.controlsHeight) * aspectRatio)
        } else {
            proposed.width = max(160, proposed.width)
        }
        proposed.height = proposed.width / aspectRatio + SPFloatingVideoContent.controlsHeight
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

@MainActor
private final class SPFloatingVideoPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class SPFloatingVideoContent: NSView {
    static let controlsHeight: CGFloat = 32
    var onTogglePlayback: (() -> Void)?
    var onReturn: (() -> Void)?
    var onClose: (() -> Void)?
    private weak var video: NSView?
    private let playPause = NSButton()
    private let returnButton = NSButton()
    private let closeButton = NSButton()
    private let dragArea = SPFloatingVideoDragArea()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        configure(playPause, symbol: "play.fill", title: L("video.pip.playPause"),
                  identifier: "sp.floatingVideo.playPause", action: #selector(togglePlayback))
        configure(returnButton, symbol: "pip.exit", title: L("video.pip.return"),
                  identifier: "sp.floatingVideo.return", action: #selector(returnVideo))
        configure(closeButton, symbol: "xmark", title: L("video.pip.close"),
                  identifier: "sp.floatingVideo.close", action: #selector(closeVideo))
        addSubview(dragArea)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { true }

    func attach(_ view: NSView) {
        video = view
        addSubview(view, positioned: .below, relativeTo: playPause)
        needsLayout = true
    }

    func update(isPlaying: Bool) {
        playPause.image = NSImage(systemSymbolName: isPlaying ? "pause.fill" : "play.fill",
                                  accessibilityDescription: L("video.pip.playPause"))
    }

    override func layout() {
        super.layout()
        video?.frame = NSRect(x: 0, y: Self.controlsHeight, width: bounds.width,
                              height: max(0, bounds.height - Self.controlsHeight))
        playPause.frame = NSRect(x: bounds.midX - 16, y: 0, width: 32, height: 32)
        returnButton.frame = NSRect(x: 8, y: 0, width: 32, height: 32)
        closeButton.frame = NSRect(x: max(0, bounds.width - 40), y: 0, width: 32, height: 32)
        dragArea.frame = NSRect(x: 0, y: max(Self.controlsHeight, bounds.height - 18),
                                width: bounds.width, height: min(18, max(0, bounds.height - Self.controlsHeight)))
    }

    private func configure(_ button: NSButton, symbol: String, title: String,
                           identifier: String, action: Selector) {
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .white
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier(identifier)
        button.target = self
        button.action = action
        addSubview(button)
    }

    @objc private func togglePlayback() { onTogglePlayback?() }
    @objc private func returnVideo() { onReturn?() }
    @objc private func closeVideo() { onClose?() }
}

@MainActor
private final class SPFloatingVideoDragArea: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

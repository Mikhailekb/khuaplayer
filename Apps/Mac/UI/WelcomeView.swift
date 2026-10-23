import AppKit

/// Empty-state welcome content with a two-column layout and a subtle glow.
/// It is installed only after the window remains idle, so file launches skip
/// this work. Texture generation uses floating-point color plus dithering on a
/// background thread; the main thread only assembles views. There are no image
/// assets, timers, or persistent animations.
final class WelcomeView: NSView {
    /// Shared limit for visible continue-watching rows and storage warming.
    static let visibleEntryCount = 6
    var onOpenFile: (() -> Void)?
    var onOpenTorrent: (() -> Void)?
    var onOpenMagnet: (() -> Void)?
    // Hover entry and exit drive delayed open-panel preparation.
    var onOpenIntent: (() -> Void)?
    var onOpenIntentEnd: (() -> Void)?
    var onPlay: ((RecentPlay) -> Void)?
#if SP_INTERNAL_BUILD && !SP_APP_STORE

    func firstRecentRowCenterInWindow() -> NSPoint? {
        guard let row = rightRows.first as? NSView else { return nil }
        let c = NSPoint(x: row.bounds.midX, y: row.bounds.midY)
        return row.convert(c, to: nil)
    }
#endif
    // Default-player offer link (idle-phase detection decides visibility).
    var onSetDefault: (() -> Void)?
    var onSetDefaultDismiss: (() -> Void)?

    static let contentSize = NSSize(width: 640, height: 360)
    private static let panelWidth: CGFloat = 250

    nonisolated static let bareLaunchHintKey = "sp.launch.bareHint"

    private let leftPanel = NSView()
    private let textureView = NSImageView()
    private var rightRows: [NSView] = []
    private var entries: [RecentPlay] = []
    private var emptyListLabel: NSTextField?
    private var textureGeneration = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0x10 / 255.0, green: 0x10 / 255.0,
                                         blue: 0x12 / 255.0, alpha: 1).cgColor

        leftPanel.wantsLayer = true
        leftPanel.layer?.masksToBounds = true

        leftPanel.layer?.backgroundColor = NSColor(srgbRed: 0x0c / 255.0, green: 0x0c / 255.0,
                                                   blue: 0x10 / 255.0, alpha: 1).cgColor
        addSubview(leftPanel)

        textureView.imageScaling = .scaleNone
        textureView.alphaValue = 0
        leftPanel.addSubview(textureView)

        buildLeftContent()

    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")
    private let openButton = WelcomeOpenButton()
    private let torrentButton = WelcomeOpenButton(title: L("torrent.openFile"), shortcut: nil)
    private let magnetButton = WelcomeOpenButton(title: L("torrent.openMagnet"), shortcut: nil)

    private func buildLeftContent() {
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.shadowColor = NSColor.black.cgColor
        iconView.layer?.shadowOpacity = 0.55
        iconView.layer?.shadowRadius = 14
        iconView.layer?.shadowOffset = CGSize(width: 0, height: -8)
        leftPanel.addSubview(iconView)

        nameLabel.stringValue = L("app.displayName")
        nameLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        nameLabel.textColor = NSColor(white: 1, alpha: 0.95)
        leftPanel.addSubview(nameLabel)

        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        versionLabel.stringValue = String(format: L("welcome.versionFmt"), "\(short) (\(build))")
        versionLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        versionLabel.textColor = NSColor(white: 1, alpha: 0.32)
        leftPanel.addSubview(versionLabel)

        openButton.onClick = { [weak self] in self?.onOpenFile?() }
        // Hovering this button signals the same open intent as the File menu.
        // Warm sidebar volumes before the panel service enumerates them.
        openButton.onHover = { [weak self] in
            OpenPanelWarmer.warm(trigger: .menuIntent)
            self?.onOpenIntent?()
        }
        openButton.onHoverEnd = { [weak self] in self?.onOpenIntentEnd?() }
        openButton.identifier = NSUserInterfaceItemIdentifier("welcome.openVideo")
        leftPanel.addSubview(openButton)
        torrentButton.identifier = NSUserInterfaceItemIdentifier("welcome.openTorrent")
        torrentButton.onClick = { [weak self] in self?.onOpenTorrent?() }
        leftPanel.addSubview(torrentButton)
        magnetButton.identifier = NSUserInterfaceItemIdentifier("welcome.openMagnet")
        magnetButton.onClick = { [weak self] in self?.onOpenMagnet?() }
        leftPanel.addSubview(magnetButton)

        // Keep the drag-and-drop hint only in the empty list on the right.
        // Reserve space for the default-player link so its fade-in does not
        // move nearby controls.
        setDefaultLink.onClick = { [weak self] in self?.onSetDefault?() }
        setDefaultLink.onDismiss = { [weak self] in
            self?.hideSetDefaultOffer()
            self?.onSetDefaultDismiss?()
        }
        setDefaultLink.isHidden = true
        setDefaultLink.alphaValue = 0
        leftPanel.addSubview(setDefaultLink)
    }

    // MARK: - Default-player offer

    private let setDefaultLink = WelcomeSetDefaultLink()

    /// Show an idempotent setup or restore offer after background evaluation.
    func showSetDefaultOffer(title: String) {
        guard setDefaultLink.isHidden else { return }
        setDefaultLink.setTitle(title)
        needsLayout = true
        setDefaultLink.isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            setDefaultLink.animator().alphaValue = 1
        }
    }

    /// Hide after the user applies or permanently dismisses the offer.
    func hideSetDefaultOffer() {
        guard !setDefaultLink.isHidden else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            setDefaultLink.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.setDefaultLink.isHidden = true
        })
    }

    override func layout() {
        super.layout()
        let b = bounds
        leftPanel.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: b.height)
        layoutTexture()

        let buttonHeight: CGFloat = 30
        let buttonGap: CGFloat = 8
        let stackH: CGFloat = 76 + 16 + 20 + 3 + 15 + 26 + buttonHeight * 3 + buttonGap * 2
        var y = (b.height + stackH) / 2
        y -= 76
        iconView.frame = NSRect(x: (Self.panelWidth - 76) / 2, y: y, width: 76, height: 76)

        iconView.layer?.shadowPath = CGPath(
            roundedRect: CGRect(x: 8, y: 8, width: 60, height: 60),
            cornerWidth: 13.5, cornerHeight: 13.5, transform: nil)
        y -= 16 + 20
        nameLabel.sizeToFit()
        nameLabel.frame.origin = NSPoint(x: (Self.panelWidth - nameLabel.frame.width) / 2, y: y)
        y -= 3 + 15
        versionLabel.sizeToFit()
        versionLabel.frame.origin = NSPoint(x: (Self.panelWidth - versionLabel.frame.width) / 2, y: y)
        y -= 26 + 30
        let sourceButtons = [openButton, torrentButton, magnetButton]
        let buttonWidth = min(218, sourceButtons.map(\.preferredContentWidth).max() ?? 218)
        for (index, button) in sourceButtons.enumerated() {
            button.layoutContent(width: buttonWidth)
            button.frame.origin = NSPoint(x: (Self.panelWidth - buttonWidth) / 2,
                                          y: y - CGFloat(index) * (buttonHeight + buttonGap))
        }
        // Center the label itself; the reserved close-button area is asymmetric.
        setDefaultLink.layoutContent()
        setDefaultLink.frame.origin = NSPoint(
            x: (Self.panelWidth - setDefaultLink.titleWidth) / 2 - 4, y: 12)

        layoutRightColumn()
    }

    private func layoutTexture() {
        // The texture is static and exactly matches the panel bounds.
        textureView.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: bounds.height)
    }

    private func layoutRightColumn() {
        let left = Self.panelWidth + 24
        let right = bounds.width - 22
        var y = bounds.height - 46 - 14
        headerLabel.sizeToFit()
        headerLabel.frame.origin = NSPoint(x: left, y: y)
        y -= 10
        for row in rightRows {
            let h = row.frame.height
            y -= h
            row.frame = NSRect(x: left - 10, y: y, width: right - left + 10 + 10, height: h)
        }
        if let empty = emptyListLabel {
            empty.sizeToFit()
            let colMidX = (left + right) / 2
            empty.frame.origin = NSPoint(x: colMidX - empty.frame.width / 2,
                                         y: bounds.height / 2 - empty.frame.height / 2)
        }
        clearLink.layoutContent()
        clearLink.frame.origin = NSPoint(x: right - clearLink.frame.width, y: 14)
        layoutFailureNotice()
        if let notice = transientNotice {
            notice.sizeToFit()
            notice.frame.origin = NSPoint(x: left, y: 15)
        }
    }

    private let headerLabel: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.attributedStringValue = NSAttributedString(
            string: L("welcome.continueWatching"),
            attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
                .foregroundColor: NSColor(white: 1, alpha: 0.32),
                .kern: 2.4,
            ])
        return l
    }()

    func reload() {
        entries = RecentPlays.load()
        rightRows.forEach { $0.removeFromSuperview() }
        rightRows.removeAll()
        emptyListLabel?.removeFromSuperview()
        emptyListLabel = nil
        if headerLabel.superview == nil { addSubview(headerLabel) }
        headerLabel.isHidden = entries.isEmpty

        if entries.isEmpty {
            let l = NSTextField(labelWithString: L("welcome.emptyList"))
            l.font = .systemFont(ofSize: 12)
            l.textColor = NSColor(white: 1, alpha: 0.28)
            addSubview(l)
            emptyListLabel = l
        } else {
            for (i, entry) in entries.prefix(Self.visibleEntryCount).enumerated() {
                let row = WelcomeRowView(entry: entry, isFirst: i == 0)
                row.onClick = { [weak self] in self?.onPlay?(entry) }
                row.onRemove = { [weak self] in self?.removeEntry(path: entry.path) }
                // Torrent identities are not local files; hover must never
                // inspect them or start a worker/network session.
                if entry.torrent == nil && !SPRecentWarmPolicy.isManagedTorrentPath(entry.path) {
                    row.onHover = { RecentPlaysWarmer.warmEntryIntent(path: entry.path) }
                }
                addSubview(row)
                rightRows.append(row)
            }
        }
        if clearLink.superview == nil {
            clearLink.onClick = { [weak self] in self?.onClearAll?() }
            addSubview(clearLink)
        }
        clearLink.isHidden = entries.isEmpty
        applyFailureNoticeVisibility()
        needsLayout = true
    }

    private func removeEntry(path: String) {
        PlayerViewController.resumeSaveQueue.async { [weak self] in
            RecentPlays.remove(path: path)
            DispatchQueue.main.async { self?.reload() }
        }
    }

    var onClearAll: (() -> Void)?
    private let clearLink = WelcomeClearLink()

    private var transientNotice: NSTextField?

    private var failureNotice: NSView?
    private var failureRetryButton: NSButton?

    func showFailureNotice(title: String, reason: String, retryEnabled: Bool, onRetry: @escaping () -> Void) {
        if failureNotice == nil {
            let box = NSView()
            let t = NSTextField(labelWithString: "")
            t.font = .systemFont(ofSize: 15, weight: .semibold)
            t.textColor = NSColor(white: 1, alpha: 0.95)
            t.alignment = .center
            t.tag = 1
            box.addSubview(t)
            let r = NSTextField(wrappingLabelWithString: "")
            r.font = .systemFont(ofSize: 12)
            r.textColor = NSColor(white: 1, alpha: 0.6)
            r.alignment = .center
            r.maximumNumberOfLines = 3
            r.tag = 2
            box.addSubview(r)
            let open = NSButton(title: L("emptyState.action.open"), target: self, action: #selector(failureOpenClicked))
            open.bezelStyle = .rounded
            open.keyEquivalent = "\r"
            open.tag = 3
            box.addSubview(open)
            let retry = NSButton(title: L("emptyState.action.retry"), target: self, action: #selector(failureRetryClicked))
            retry.bezelStyle = .rounded
            retry.tag = 4
            box.addSubview(retry)
            failureRetryButton = retry
            addSubview(box)
            failureNotice = box
        }
        guard let box = failureNotice else { return }
        (box.viewWithTag(1) as? NSTextField)?.stringValue = title
        (box.viewWithTag(2) as? NSTextField)?.stringValue = reason
        failureRetryButton?.isEnabled = retryEnabled
        failureRetryAction = onRetry
        applyFailureNoticeVisibility()
        needsLayout = true
    }

    func hideFailureNotice() {
        guard failureNotice != nil else { return }
        failureNotice?.removeFromSuperview()
        failureNotice = nil
        failureRetryButton = nil
        failureRetryAction = nil
        applyFailureNoticeVisibility()
        needsLayout = true
    }

    func setFailureRetryEnabled(_ enabled: Bool) { failureRetryButton?.isEnabled = enabled }
    var isShowingFailureNotice: Bool { failureNotice != nil }

    private var failureRetryAction: (() -> Void)?
    @objc private func failureOpenClicked() { onOpenFile?() }
    @objc private func failureRetryClicked() { failureRetryAction?() }

    private func applyFailureNoticeVisibility() {
        let hidden = failureNotice != nil
        headerLabel.isHidden = hidden || entries.isEmpty
        emptyListLabel?.isHidden = hidden
        clearLink.isHidden = hidden || entries.isEmpty
        rightRows.forEach { $0.isHidden = hidden }
    }

    private func layoutFailureNotice() {
        guard let box = failureNotice else { return }
        let left = Self.panelWidth + 24
        let right = bounds.width - 22
        let width = right - left
        guard let t = box.viewWithTag(1) as? NSTextField, let r = box.viewWithTag(2) as? NSTextField,
              let open = box.viewWithTag(3) as? NSButton, let retry = box.viewWithTag(4) as? NSButton else { return }
        t.sizeToFit()
        r.preferredMaxLayoutWidth = width - 16
        let rSize = r.sizeThatFits(NSSize(width: width - 16, height: 200))
        open.sizeToFit(); retry.sizeToFit()
        let btnH = max(open.frame.height, retry.frame.height)
        let totalH = t.frame.height + 8 + rSize.height + 18 + btnH
        box.frame = NSRect(x: left, y: (bounds.height - totalH) / 2, width: width, height: totalH)
        var y = totalH - t.frame.height
        t.frame = NSRect(x: 0, y: y, width: width, height: t.frame.height)
        y -= 8 + rSize.height
        r.frame = NSRect(x: 8, y: y, width: width - 16, height: rSize.height)
        y -= 18 + btnH
        let gap: CGFloat = 12
        let bw = open.frame.width + gap + retry.frame.width
        var x = (width - bw) / 2
        open.frame = NSRect(x: x, y: y, width: open.frame.width, height: btnH)
        x += open.frame.width + gap
        retry.frame = NSRect(x: x, y: y, width: retry.frame.width, height: btnH)
    }
    func showTransientNotice(_ text: String) {
        transientNotice?.removeFromSuperview()
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = NSColor(white: 1, alpha: 0.45)
        addSubview(l)
        transientNotice = l
        needsLayout = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self, weak l] in
            guard let l, self?.transientNotice === l else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                l.animator().alphaValue = 0
            }, completionHandler: {
                l.removeFromSuperview()
            })
            self?.transientNotice = nil
        }
    }

    func playFirst() {
        if let first = entries.first { onPlay?(first) }
    }

    private static let prewarmLock = NSLock()
    nonisolated(unsafe) private static var prewarmStore: (image: NSImage, scale: CGFloat)?

    nonisolated(unsafe) private static var prewarmIssued = false
    private static let prewarmSignal = DispatchSemaphore(value: 0)

    static func prewarmTexture(scale: CGFloat, qos: DispatchQoS.QoSClass = .userInitiated) {
        let size = NSSize(width: panelWidth, height: contentSize.height)
        prewarmLock.lock()
        prewarmIssued = true
        prewarmLock.unlock()
        DispatchQueue.global(qos: qos).async {
            defer { prewarmSignal.signal() }
            guard let cg = renderPanelTexture(pointSize: size, scale: scale) else { return }
            let image = NSImage(cgImage: cg, size: size)
            prewarmLock.lock()
            prewarmStore = (image, scale)
            prewarmLock.unlock()
        }
    }

    private nonisolated static func awaitPrewarmedTexture(scale: CGFloat,
                                                          timeoutMs: Int) -> NSImage? {
        prewarmLock.lock()
        let issued = prewarmIssued
        prewarmIssued = false
        prewarmLock.unlock()
        guard issued else { return nil }
        _ = prewarmSignal.wait(timeout: .now() + .milliseconds(timeoutMs))
        return takePrewarmedTexture(scale: scale)
    }

    private nonisolated static func takePrewarmedTexture(scale: CGFloat) -> NSImage? {
        prewarmLock.lock()
        defer { prewarmLock.unlock() }
        guard let (image, s) = prewarmStore, s == scale else { return nil }
        prewarmStore = nil
        return image
    }

    func rerollTexture() {
        textureView.image = nil
        prepareTextureIfNeeded()
    }

    func prepareTextureIfNeeded() {
        guard textureView.image == nil else { return }
        textureGeneration &+= 1
        let gen = textureGeneration
        let scale = window?.backingScaleFactor ?? 2.0

        if let image = Self.takePrewarmedTexture(scale: scale) {
            textureView.image = image
            textureView.alphaValue = 1
            layoutTexture()
            if PlayerViewController.dbg { NSLog("[UI] 欢迎屏纹理预热命中") }
            return
        }
        let size = NSSize(width: Self.panelWidth, height: Self.contentSize.height)
        let t0 = CFAbsoluteTimeGetCurrent()

        let anyOtherVisibleWindow = NSApp.windows.contains {
            $0.isVisible && $0 !== window
        }
        if window?.isVisible != true && !anyOtherVisibleWindow {

            if let image = Self.awaitPrewarmedTexture(scale: scale, timeoutMs: 150) {
                textureView.image = image
                textureView.alphaValue = 1
                layoutTexture()
                if PlayerViewController.dbg {
                    NSLog("[UI] 欢迎屏纹理预热等待命中 %.1fms",
                          (CFAbsoluteTimeGetCurrent() - t0) * 1000)
                }
                return
            }
            if let cg = WelcomeView.renderPanelTexture(pointSize: size, scale: scale) {
                textureView.image = NSImage(cgImage: cg, size: size)
                textureView.alphaValue = 1
                layoutTexture()
                if PlayerViewController.dbg {
                    NSLog("[UI] 欢迎屏纹理同步生成（亮相前）%.1fms",
                          (CFAbsoluteTimeGetCurrent() - t0) * 1000)
                }
            }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let cg = WelcomeView.renderPanelTexture(pointSize: size, scale: scale) else { return }
            let image = NSImage(cgImage: cg, size: size)
            DispatchQueue.main.async {
                guard let self, self.textureGeneration == gen else { return }
                self.textureView.image = image
                self.layoutTexture()
                if PlayerViewController.dbg {
                    NSLog("[UI] 欢迎屏纹理生成 %.1fms (%.0fx%.0f@%.0fx)",
                          (CFAbsoluteTimeGetCurrent() - t0) * 1000, size.width, size.height, scale)
                }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    self.textureView.animator().alphaValue = 1
                }
            }
        }
    }

    nonisolated static func renderPanelTexture(pointSize: NSSize, scale: CGFloat) -> CGImage? {
        let w = Int(pointSize.width * scale), h = Int(pointSize.height * scale)
        guard w > 0, h > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let inv = 1.0 / Double(scale)
        let wPt = Double(pointSize.width), hPt = Double(pointSize.height)

        let c0 = (0x15 / 255.0, 0x15 / 255.0, 0x1b / 255.0)
        let c1 = (0x0c / 255.0, 0x0c / 255.0, 0x11 / 255.0)
        let c2 = (0x07 / 255.0, 0x07 / 255.0, 0x09 / 255.0)

        let seed = arc4random()
        let s01 = { (shift: UInt32) in Double((seed >> shift) & 0xFF) / 255.0 }
        let glowCx = wPt / 2 + (s01(0) - 0.5) * 12
        let glowCy = hPt * 0.33 + (s01(8) - 0.5) * 12
        let glowR = 175.0
        let tintMix = s01(16)
        let glowRC = (150.0 + 12.0 * tintMix) / 255.0
        let glowGC = (170.0 - 8.0 * tintMix) / 255.0
        let noisePhase = seed &* 2654435761
        let gradDen = 0.25 * wPt + 0.97 * hPt

        buf.withUnsafeMutableBytes { raw in
            let p = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for py in 0..<h {
                let ypt = Double(py) * inv

                let rowHasGlow = abs(ypt - glowCy) < glowR
                let scanBoost = (Int(ypt.rounded(.down)) % 3 == 0) ? 0.016 : 0.0
                for px in 0..<w {
                    let xpt = Double(px) * inv

                    let t = min(1.0, max(0.0, (0.25 * xpt + 0.97 * ypt) / gradDen))
                    var r: Double, g: Double, b: Double
                    if t < 0.48 {
                        let f = t / 0.48
                        r = c0.0 + (c1.0 - c0.0) * f
                        g = c0.1 + (c1.1 - c0.1) * f
                        b = c0.2 + (c1.2 - c0.2) * f
                    } else {
                        let f = (t - 0.48) / 0.52
                        r = c1.0 + (c2.0 - c1.0) * f
                        g = c1.1 + (c2.1 - c1.1) * f
                        b = c1.2 + (c2.2 - c1.2) * f
                    }
                    if rowHasGlow {

                        let dx = xpt - glowCx, dy = ypt - glowCy
                        let rr = (dx * dx + dy * dy).squareRoot()
                        if rr < glowR {
                            let a = 0.13 * 0.5 * (1 + cos(rr / glowR * Double.pi))
                            r += glowRC * a
                            g += glowGC * a
                            b += 1.0 * a
                        }
                    }

                    if scanBoost > 0 { r += scanBoost; g += scanBoost; b += scanBoost }

                    let edge = min(min(xpt, wPt - xpt), min(ypt, hPt - ypt))
                    if edge < 70 {
                        let v = edge / 70
                        let dark = 0.7 + 0.3 * v * (2 - v)
                        r *= dark; g *= dark; b *= dark
                    }
                    // Per-pixel noise supplies both visible fine grain and
                    // quantization dithering; the launch seed changes its phase.
                    var hsh = UInt32(truncatingIfNeeded: px &* 73856093 ^ py &* 19349663) ^ noisePhase
                    hsh ^= hsh << 13; hsh ^= hsh >> 17; hsh ^= hsh << 5
                    let n = (Double(hsh & 0xFFFF) / 32768.0 - 1.0) * 0.010
                    r += n; g += n; b += n

                    let o = (py * w + px) * 4
                    p[o + 0] = UInt8(min(255, max(0, r * 255 + 0.5)))
                    p[o + 1] = UInt8(min(255, max(0, g * 255 + 0.5)))
                    p[o + 2] = UInt8(min(255, max(0, b * 255 + 0.5)))
                    p[o + 3] = 255
                }
            }
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        return ctx.makeImage()
    }

}

final class WelcomeOpenButton: NSView {
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    var onHoverEnd: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let kbd = NSTextField(labelWithString: "⌘O")

    init(title: String? = nil, shortcut: String? = "⌘O") {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.09).cgColor
        layer?.cornerRadius = 7
        label.stringValue = title ?? L("welcome.openVideo")
        label.font = .systemFont(ofSize: 12.5)
        label.textColor = NSColor(white: 1, alpha: 0.88)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setAccessibilityElement(false)
        addSubview(label)
        kbd.stringValue = shortcut ?? ""
        kbd.isHidden = shortcut == nil
        kbd.setAccessibilityElement(false)
        kbd.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        kbd.textColor = NSColor(white: 1, alpha: 0.4)
        addSubview(kbd)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label.stringValue)
        toolTip = label.stringValue
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    var preferredContentWidth: CGFloat {
        let textWidth = max(label.intrinsicContentSize.width, label.cell?.cellSize.width ?? 0)
        let shortcutWidth = kbd.isHidden ? 0 : max(kbd.intrinsicContentSize.width, kbd.cell?.cellSize.width ?? 0) + 10
        return 36 + ceil(textWidth + shortcutWidth)
    }
    func layoutContent(width: CGFloat? = nil) {
        let w = min(218, width ?? preferredContentWidth)
        frame.size = NSSize(width: w, height: 30)
        kbd.sizeToFit()
        let shortcutWidth = kbd.isHidden ? 0 : kbd.frame.width + 10
        label.frame = NSRect(x: 18, y: 7, width: max(0, w - 36 - shortcutWidth), height: 17)
        kbd.frame.origin = NSPoint(x: max(18, w - 18 - kbd.frame.width), y: (30 - kbd.frame.height) / 2)
    }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 49 { onClick?() }
        else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func draw(_ dirtyRect: NSRect) {
        if window?.firstResponder === self {
            NSColor.white.withAlphaComponent(0.45).setStroke()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).stroke()
        }
    }
    override func mouseDown(with event: NSEvent) { onClick?() }

    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = hoverArea { removeTrackingArea(old) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        hoverArea = ta
    }
    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.14).cgColor
        onHover?()
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.09).cgColor
        onHoverEnd?()
    }
    override var mouseDownCanMoveWindow: Bool { false }
}

final class WelcomeRowView: NSView {
    var onClick: (() -> Void)?
    var onRemove: (() -> Void)?
    var onHover: (() -> Void)?

    private let isFirst: Bool
    private let nameLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private var triangle: NSView?
    private var sourceCue: NSImageView?
    private var progressTrack: NSView?
    private var progressFill: NSView?
    private let fraction: Double

    init(entry: RecentPlay, isFirst: Bool) {
        self.isFirst = isFirst
        self.fraction = entry.duration > 0 ? min(1, max(0, entry.position / entry.duration)) : 0
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: isFirst ? 42 : 34))
        wantsLayer = true
        layer?.cornerRadius = 7
        if isFirst {
            layer?.backgroundColor = NSColor(white: 1, alpha: 0.07).cgColor
            let tri = TriangleView()
            addSubview(tri)
            triangle = tri
            let track = NSView(); track.wantsLayer = true
            track.layer?.backgroundColor = NSColor(white: 1, alpha: 0.1).cgColor
            track.layer?.cornerRadius = 1
            addSubview(track)
            progressTrack = track
            let fill = NSView(); fill.wantsLayer = true
            fill.layer?.backgroundColor = NSColor(white: 1, alpha: 0.55).cgColor
            fill.layer?.cornerRadius = 1
            addSubview(fill)
            progressFill = fill
        }
        if entry.torrent != nil {
            let cue = NSImageView(image: NSImage(systemSymbolName: "link", accessibilityDescription: nil) ?? NSImage())
            cue.contentTintColor = NSColor(white: 1, alpha: 0.42)
            cue.imageScaling = .scaleProportionallyUpOrDown
            cue.setAccessibilityElement(false)
            addSubview(cue)
            sourceCue = cue
            triangle?.isHidden = true
        }
        nameLabel.stringValue = entry.title
        nameLabel.font = .systemFont(ofSize: 12.5)
        nameLabel.textColor = NSColor(white: 1, alpha: 0.82)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1
        addSubview(nameLabel)
        metaLabel.stringValue = entry.isFinished
            ? L("welcome.finished")
            : String(format: L("welcome.remainFmt"), entry.remainingText)
        metaLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        metaLabel.textColor = NSColor(white: 1, alpha: 0.38)
        addSubview(metaLabel)

        playButton.onClick = { [weak self] in self?.onClick?() }
        playButton.isHidden = true
        addSubview(playButton)
        removeButton.onClick = { [weak self] in self?.onRemove?() }
        removeButton.isHidden = true
        addSubview(removeButton)

        menu = {
            let m = NSMenu()
            m.addItem(withTitle: L("welcome.removeFromList"),
                      action: #selector(removeAction), keyEquivalent: "").target = self
            return m
        }()
    }

    private let playButton = WelcomeRowActionButton(glyph: "▶\u{FE0E}", glyphSize: 9,
                                                    tint: .systemGreen)
    private let removeButton = WelcomeRowActionButton(glyph: "✕", glyphSize: 11,
                                                      tint: .systemRed)

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    @objc private func removeAction() { onRemove?() }

    override func layout() {
        super.layout()
        let textTop: CGFloat = isFirst ? frame.height - 12 - 15 : (frame.height - 15) / 2
        metaLabel.sizeToFit()
        metaLabel.frame.origin = NSPoint(x: frame.width - 10 - metaLabel.frame.width, y: textTop + 1)

        let btnY = textTop + 8 - 11
        removeButton.frame = NSRect(x: frame.width - 8 - 22, y: btnY, width: 22, height: 22)
        playButton.frame = NSRect(x: frame.width - 8 - 22 - 4 - 22, y: btnY, width: 22, height: 22)
        let nameX: CGFloat = isFirst || sourceCue != nil ? 28 : 10
        let rightReserve = max(metaLabel.frame.width + 24, 22 + 4 + 22 + 18)
        nameLabel.frame = NSRect(x: nameX, y: textTop,
                                 width: frame.width - nameX - rightReserve, height: 16)
        triangle?.frame = NSRect(x: 11, y: textTop + 3, width: 9, height: 10)
        sourceCue?.frame = NSRect(x: 10, y: textTop + 2, width: 12, height: 12)
        if let track = progressTrack, let fill = progressFill {
            let x: CGFloat = 28, w = frame.width - x - 10
            track.frame = NSRect(x: x, y: 7, width: w, height: 2)
            fill.frame = NSRect(x: x, y: 7, width: w * CGFloat(fraction), height: 2)
        }
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override var mouseDownCanMoveWindow: Bool { false }

    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = hoverArea { removeTrackingArea(old) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        hoverArea = ta
    }
    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 1, alpha: isFirst ? 0.1 : 0.05).cgColor
        metaLabel.isHidden = true
        playButton.isHidden = false
        removeButton.isHidden = false
        onHover?()
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = isFirst ? NSColor(white: 1, alpha: 0.07).cgColor : nil
        metaLabel.isHidden = false
        playButton.isHidden = true
        removeButton.isHidden = true
    }
}

final class WelcomeRowActionButton: NSView {
    var onClick: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let tint: NSColor

    init(glyph: String, glyphSize: CGFloat, tint: NSColor) {
        self.tint = tint
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        label.stringValue = glyph
        label.font = .systemFont(ofSize: glyphSize, weight: .semibold)
        label.textColor = tint.withAlphaComponent(0.9)
        label.alignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    override func layout() {
        super.layout()
        label.sizeToFit()
        label.frame.origin = NSPoint(x: (bounds.width - label.frame.width) / 2,
                                     y: (bounds.height - label.frame.height) / 2)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override var mouseDownCanMoveWindow: Bool { false }

    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = hoverArea { removeTrackingArea(old) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        hoverArea = ta
    }
    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = tint.withAlphaComponent(0.18).cgColor
        label.textColor = tint
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
        label.textColor = tint.withAlphaComponent(0.9)
    }
}

final class WelcomeClearLink: NSView {
    var onClick: (() -> Void)?
    private let label = NSTextField(labelWithString: L("menu.clearHistory"))

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 11)
        label.textColor = NSColor(white: 1, alpha: 0.3)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    func layoutContent() {
        label.sizeToFit()
        frame.size = NSSize(width: label.frame.width + 8, height: label.frame.height + 8)
        label.frame.origin = NSPoint(x: 4, y: 4)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override var mouseDownCanMoveWindow: Bool { false }

    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = hoverArea { removeTrackingArea(old) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        hoverArea = ta
    }
    override func mouseEntered(with event: NSEvent) {
        label.textColor = NSColor(white: 1, alpha: 0.6)
    }
    override func mouseExited(with event: NSEvent) {
        label.textColor = NSColor(white: 1, alpha: 0.3)
    }
}

// Welcome-page default-player link with a hover-only permanent-dismiss button.
// Its width always includes the reserved button area to prevent layout movement.
final class WelcomeSetDefaultLink: NSView {
    var onClick: (() -> Void)?
    var onDismiss: (() -> Void)?
    private let label = NSTextField(labelWithString: L("defaultPlayer.title"))
    private let dismissLabel = NSTextField(labelWithString: "✕")

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 11)
        label.textColor = NSColor(white: 1, alpha: 0.35)
        addSubview(label)
        dismissLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        dismissLabel.textColor = NSColor(white: 1, alpha: 0.4)
        dismissLabel.isHidden = true
        addSubview(dismissLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not implemented") }

    func setTitle(_ title: String) {
        label.stringValue = title
    }

    /// Label width after layout, used by the parent for optical centering.
    var titleWidth: CGFloat { label.frame.width }

    func layoutContent() {
        label.sizeToFit()
        dismissLabel.sizeToFit()
        let w = 4 + label.frame.width + 8 + dismissLabel.frame.width + 4
        frame.size = NSSize(width: w, height: label.frame.height + 8)
        label.frame.origin = NSPoint(x: 4, y: 4)
        dismissLabel.frame.origin = NSPoint(
            x: 4 + label.frame.width + 8,
            y: 4 + (label.frame.height - dismissLabel.frame.height) / 2)
    }

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        if !dismissLabel.isHidden, x >= dismissLabel.frame.minX - 4 {
            onDismiss?()
        } else {
            onClick?()
        }
    }
    override var mouseDownCanMoveWindow: Bool { false }

    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = hoverArea { removeTrackingArea(old) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        hoverArea = ta
    }
    override func mouseEntered(with event: NSEvent) {
        label.textColor = NSColor(white: 1, alpha: 0.7)
        dismissLabel.isHidden = false
    }
    override func mouseExited(with event: NSEvent) {
        label.textColor = NSColor(white: 1, alpha: 0.35)
        dismissLabel.isHidden = true
    }
}

private final class TriangleView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 0, y: 0))
        p.line(to: NSPoint(x: 0, y: bounds.height))
        p.line(to: NSPoint(x: bounds.width, y: bounds.height / 2))
        p.close()
        NSColor(white: 1, alpha: 0.85).setFill()
        p.fill()
    }
}

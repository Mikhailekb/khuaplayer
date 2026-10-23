import AppKit
import QuartzCore

final class SPPlaybackNoticeView: NSView {
    private enum G {
        static let height: CGFloat = 30
        static let padH: CGFloat = 14
        static let padV: CGFloat = 7
        static let marginH: CGFloat = 16
        static let topGap: CGFloat = 24
        static let fontSize: CGFloat = 13
        static let fade: CFTimeInterval = 0.15
        static let transientSeconds: TimeInterval = 3
    }

    private let label = NSTextField(labelWithString: "")
    private var stickyText: String?
    private var transientText: String?
    private var transientTimer: Timer?
    private var lastBounds: NSRect = .zero
    private var lastTopInset: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.58).cgColor
        layer?.cornerRadius = G.height / 2
        label.font = .systemFont(ofSize: G.fontSize, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.cell?.usesSingleLineMode = false
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        addSubview(label)
        isHidden = true
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SPPlaybackNoticeView: no coder path") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setSticky(_ text: String?) {
        stickyText = text
        refresh()
    }

    func showTransient(_ text: String) {
        transientText = text
        transientTimer?.invalidate()
        transientTimer = Timer.scheduledTimer(withTimeInterval: G.transientSeconds, repeats: false) { [weak self] _ in
            self?.transientText = nil
            self?.refresh()
        }
        refresh()
    }

    func clearAll() {
        transientTimer?.invalidate()
        transientTimer = nil
        stickyText = nil
        transientText = nil
        refresh()
    }

    func place(in bounds: NSRect, topInset: CGFloat) {
        lastBounds = bounds
        lastTopInset = topInset
        guard let text = currentText, bounds.width > 0, bounds.height > 0 else { return }
        label.stringValue = text
        guard let cell = label.cell else { return }
        // Intrinsic width excludes part of NSTextFieldCell's text insets. Use
        // the actual cell metrics, then reserve a point for fractional glyphs.
        let measuringBounds = NSRect(x: 0, y: 0, width: 100_000, height: 100_000)
        let naturalWidth = ceil(cell.cellSize(forBounds: measuringBounds).width) + 1
        let margin = min(G.marginH, bounds.width / 4)
        let w = min(naturalWidth + G.padH * 2, bounds.width - margin * 2)
        let padH = min(G.padH, max(0, (w - 20) / 2))
        let labelW = max(1, w - padH * 2)
        let labelH = ceil(cell.cellSize(forBounds:
            NSRect(x: 0, y: 0, width: labelW, height: measuringBounds.height)).height)
        let h = max(G.height, labelH + G.padV * 2)
        frame = NSRect(x: bounds.midX - w / 2, y: bounds.maxY - topInset - G.topGap - h,
                       width: w, height: h)
        label.frame = NSRect(x: padH, y: (h - labelH) / 2, width: labelW, height: labelH)
    }

    private var currentText: String? { transientText ?? stickyText }

    private func refresh() {
        if currentText != nil {
            place(in: lastBounds, topInset: lastTopInset)

            if isHidden || alphaValue < 1 {
                isHidden = false
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = G.fade
                    animator().alphaValue = 1
                }
            }
        } else if !isHidden {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = G.fade
                animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.currentText == nil else { return }
                self.isHidden = true
            })
        }
    }
}

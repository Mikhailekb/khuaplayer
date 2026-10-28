import AppKit

/// A single, explicitly named buffer measurement. The producer owns the metric's
/// meaning: reader delivery, resident bytes and torrent traffic are not interchangeable.
/// No time estimate or percentage is inferred by the view.
struct SPTorrentBufferPresentation: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case waiting, buffering, paused, ready, stopped, failed
    }

    enum Action: Equatable, Sendable {
        case stopBuffering, resumeBuffering, cancelOpening
    }

    let title: String
    let state: State
    let primaryValue: String?
    let secondaryValue: String?
    let progress: Double?
    /// Includes its scope in the localized text, e.g. "Torrent: 2.3 MB/s".
    let networkRateText: String?
    let details: String?
    let detailsTitle: String
    let action: Action?
    let actionTitle: String?
    let actionEnabled: Bool

    init(title: String, state: State, primaryValue: String? = nil,
         secondaryValue: String? = nil, progress: Double? = nil,
         networkRateText: String? = nil, details: String? = nil,
         detailsTitle: String, action: Action? = nil, actionTitle: String? = nil,
         actionEnabled: Bool = true) {
        self.title = title
        self.state = state
        self.primaryValue = primaryValue
        self.secondaryValue = secondaryValue
        self.progress = progress.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        self.networkRateText = networkRateText
        self.details = details
        self.detailsTitle = detailsTitle
        self.action = action
        self.actionTitle = actionTitle
        self.actionEnabled = actionEnabled
    }
}

/// Compact footer for the current playback buffer. Persistent file downloads
/// belong to their playlist rows, so they never compete with this measurement.
@MainActor
final class SPTorrentBufferStatusView: NSView {
    var onAction: ((SPTorrentBufferPresentation.Action) -> Void)?
    var isCompact = false {
        didSet {
            guard isCompact != oldValue else { return }
            updateFonts()
            needsLayout = true
            invalidateIntrinsicContentSize()
        }
    }
    var preferredHeight: CGFloat {
        guard let presentation else { return 0 }
        if hasMeasurement { return isCompact ? 84 : 108 }
        return presentation.networkRateText?.isEmpty == false ? (isCompact ? 54 : 62) : 38
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: preferredHeight)
    }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private let titleLabel = SPTorrentBufferLabel(size: 12, weight: .medium)
    private let valueLabel = SPTorrentBufferLabel(size: 20, weight: .medium)
    private let targetLabel = SPTorrentBufferLabel(size: 11, secondary: true)
    private let networkLabel = SPTorrentBufferLabel(size: 11, secondary: true)
    private let progressView = SPTorrentBufferProgressView(frame: .zero)
    private let activityIndicator = NSProgressIndicator()
    private let actionButton = NSButton()
    private let detailsButton = NSButton()
    private var presentation: SPTorrentBufferPresentation?
    private var detailsPopover: NSPopover?
    private var hasMeasurement: Bool {
        presentation?.progress != nil || presentation?.primaryValue?.isEmpty == false ||
            presentation?.secondaryValue?.isEmpty == false
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("torrent.playlist.buffer")
        setAccessibilityRole(.group)
        titleLabel.identifier = NSUserInterfaceItemIdentifier("torrent.playlist.status")
        valueLabel.identifier = NSUserInterfaceItemIdentifier("torrent.playlist.buffer.value")
        targetLabel.identifier = NSUserInterfaceItemIdentifier("torrent.playlist.buffer.target")
        networkLabel.identifier = NSUserInterfaceItemIdentifier("torrent.playlist.buffer.network")
        targetLabel.alignment = .right

        activityIndicator.style = .spinning
        activityIndicator.controlSize = .small
        activityIndicator.isDisplayedWhenStopped = false
        activityIndicator.setAccessibilityElement(false)

        for (button, name) in [(actionButton, "torrent.playlist.pauseBuffer"),
                               (detailsButton, "torrent.playlist.buffer.details")] {
            button.title = ""
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.contentTintColor = .white
            button.bezelStyle = .regularSquare
            button.target = self
            button.identifier = NSUserInterfaceItemIdentifier(name)
        }
        actionButton.wantsLayer = true
        actionButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        actionButton.layer?.cornerRadius = 6
        actionButton.action = #selector(performAction)
        detailsButton.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        detailsButton.contentTintColor = NSColor(white: 0.65, alpha: 1)
        detailsButton.action = #selector(showDetails)

        for view in [titleLabel, valueLabel, targetLabel, networkLabel, progressView,
                     activityIndicator, actionButton, detailsButton] {
            addSubview(view)
        }
        // The complete measurement is read once through the progress element.
        valueLabel.setAccessibilityElement(false)
        targetLabel.setAccessibilityElement(false)
        updateFonts()
        setPresentation(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SPTorrentBufferStatusView: no coder path") }

    func setPresentation(_ value: SPTorrentBufferPresentation?) {
        presentation = value
        isHidden = value == nil
        setAccessibilityLabel(value?.title)
        titleLabel.stringValue = value?.title ?? ""
        titleLabel.toolTip = value?.title
        valueLabel.stringValue = value?.primaryValue ?? ""
        targetLabel.stringValue = value?.secondaryValue ?? ""
        networkLabel.stringValue = value?.networkRateText ?? ""
        networkLabel.toolTip = value?.networkRateText
        networkLabel.isHidden = networkLabel.stringValue.isEmpty
        let measurement = [value?.primaryValue, value?.secondaryValue]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        valueLabel.toolTip = measurement
        targetLabel.toolTip = measurement
        progressView.setPresentation(fraction: value?.progress,
                                    subdued: value?.state == .paused || value?.state == .stopped,
                                    label: value?.title, measurement: measurement)
        progressView.isHidden = value?.progress == nil
        // Unknown data has no numeric bar. The spinner communicates activity
        // without presenting an invented completion fraction.
        let isWaiting = value?.progress == nil && (value?.state == .waiting || value?.state == .buffering)
        if isWaiting { activityIndicator.startAnimation(nil) }
        else { activityIndicator.stopAnimation(nil) }

        actionButton.isHidden = value?.action == nil || (value?.actionTitle?.isEmpty ?? true)
        actionButton.isEnabled = value?.actionEnabled == true
        actionButton.toolTip = value?.actionTitle
        actionButton.setAccessibilityLabel(value?.actionTitle)
        let symbol: String
        switch value?.action {
        case .stopBuffering: symbol = "pause.fill"
        case .resumeBuffering: symbol = "arrow.down"
        case .cancelOpening, .none: symbol = "xmark"
        }
        actionButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        detailsButton.isHidden = value?.details?.isEmpty ?? true
        detailsButton.toolTip = value?.detailsTitle
        detailsButton.setAccessibilityLabel(value?.detailsTitle)
        if detailsButton.isHidden {
            detailsPopover?.close()
        } else if detailsPopover?.isShown == true, let value {
            updateDetailsPopover(value)
        }
        // A measurement with no denominator still remains readable by VoiceOver.
        valueLabel.setAccessibilityElement(value?.progress == nil && !measurement.isEmpty)
        valueLabel.setAccessibilityLabel(measurement)
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    private func updateFonts() {
        valueLabel.font = .monospacedDigitSystemFont(ofSize: isCompact ? 15 : 20, weight: .medium)
        targetLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        networkLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    }

    override func layout() {
        super.layout()
        let width = max(0, bounds.width)
        let headerY: CGFloat = isCompact ? 3 : 5
        var trailing = width
        for button in [actionButton, detailsButton] where !button.isHidden {
            trailing = max(0, trailing - 28)
            button.frame = NSRect(x: trailing, y: headerY, width: min(28, width), height: 28)
            trailing = max(0, trailing - 4)
        }
        let hasActivity = presentation?.progress == nil &&
            (presentation?.state == .waiting || presentation?.state == .buffering)
        let titleX: CGFloat = hasActivity ? 21 : 0
        titleLabel.frame = NSRect(x: titleX, y: headerY + 5,
                                 width: max(0, trailing - titleX - 4), height: 18)
        activityIndicator.frame = NSRect(x: 0, y: headerY + 6, width: 14, height: 14)

        let metricY: CGFloat = isCompact ? 32 : 36
        let metricHeight: CGFloat = isCompact ? 20 : 25
        // NSTextField's fitted width can still truncate a right-aligned final
        // glyph; reserve the cell's text inset as well as its measured text.
        let targetWidth = targetLabel.stringValue.isEmpty ? 0 :
            min(width * 0.52, ceil(targetLabel.intrinsicContentSize.width) + 8)
        let valueWidth = max(0, width - targetWidth - (targetWidth > 0 ? 8 : 0))
        valueLabel.frame = NSRect(x: 0, y: metricY, width: valueWidth, height: metricHeight)
        targetLabel.frame = NSRect(x: max(0, width - targetWidth),
                                  y: metricY + (isCompact ? 3 : 8), width: targetWidth, height: 16)
        progressView.frame = NSRect(x: 0, y: isCompact ? 56 : 68, width: width, height: 4)
        let networkY: CGFloat = hasMeasurement ? (isCompact ? 65 : 82) : (isCompact ? 33 : 38)
        networkLabel.frame = NSRect(x: 0, y: networkY, width: width, height: 16)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { detailsPopover?.close() }
    }

    @objc private func performAction() {
        guard let presentation, presentation.actionEnabled, let action = presentation.action else { return }
        onAction?(action)
    }

    @objc private func showDetails() {
        guard let presentation, presentation.details?.isEmpty == false else { return }
        if detailsPopover?.isShown == true {
            detailsPopover?.close()
            return
        }
        updateDetailsPopover(presentation)
        detailsPopover?.show(relativeTo: detailsButton.bounds, of: detailsButton, preferredEdge: .maxY)
    }

    private func updateDetailsPopover(_ presentation: SPTorrentBufferPresentation) {
        if detailsPopover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            popover.appearance = NSAppearance(named: .darkAqua)
            popover.contentViewController = SPTorrentBufferDetailsController()
            detailsPopover = popover
        }
        (detailsPopover?.contentViewController as? SPTorrentBufferDetailsController)?
            .configure(title: presentation.detailsTitle, details: presentation.details ?? "")
    }
}

@MainActor
private func SPTorrentBufferLabel(size: CGFloat, weight: NSFont.Weight = .regular,
                                  secondary: Bool = false) -> NSTextField {
    let label = NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = secondary ? NSColor(white: 0.65, alpha: 1) : .white
    label.maximumNumberOfLines = 1
    label.lineBreakMode = .byTruncatingTail
    return label
}

@MainActor
private final class SPTorrentBufferProgressView: NSView {
    private var fraction: Double?
    private var subdued = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("torrent.playlist.progress")
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityMinValue(0)
        setAccessibilityMaxValue(1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SPTorrentBufferProgressView: no coder path") }

    func setPresentation(fraction: Double?, subdued: Bool, label: String?, measurement: String) {
        self.fraction = fraction
        self.subdued = subdued
        setAccessibilityLabel(label)
        setAccessibilityValue(fraction)
        setAccessibilityValueDescription(measurement.isEmpty ? nil : measurement)
        toolTip = measurement.isEmpty ? nil : measurement
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
        guard let fraction, fraction > 0 else { return }
        NSColor.white.withAlphaComponent(subdued ? 0.55 : 0.9).setFill()
        let fill = NSRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
        NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
    }
}

@MainActor
private final class SPTorrentBufferDetailsController: NSViewController {
    private let titleLabel = SPTorrentBufferLabel(size: 12, weight: .semibold)
    private let detailLabel = SPTorrentBufferLabel(size: 12, secondary: true)

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 310, height: 120))
        detailLabel.maximumNumberOfLines = 0
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.isSelectable = true
        view.addSubview(titleLabel)
        view.addSubview(detailLabel)
    }

    func configure(title: String, details: String) {
        loadViewIfNeeded()
        titleLabel.stringValue = title
        detailLabel.stringValue = details
        let width: CGFloat = 278
        let contentHeight = ceil(detailLabel.cell?.cellSize(forBounds:
            NSRect(x: 0, y: 0, width: width, height: 1_000)).height ?? 80)
        let height = contentHeight + 56
        preferredContentSize = NSSize(width: 310, height: height)
        view.setFrameSize(preferredContentSize)
        titleLabel.frame = NSRect(x: 16, y: height - 34, width: width, height: 18)
        detailLabel.frame = NSRect(x: 16, y: 16, width: width, height: contentHeight)
    }
}

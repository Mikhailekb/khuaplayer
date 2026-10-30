import AppKit

@MainActor private func SPPlaylistLabel(_ text: String = "", size: CGFloat = 13,
                                      weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = secondary ? NSColor(white: 0.65, alpha: 1) : .white
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    return label
}

private final class SPPlaylistNode: NSObject {
    let key: String
    let name: String
    let entry: SPPlaylistEntry?
    var children: [SPPlaylistNode] = []
    weak var parent: SPPlaylistNode?
    var isFolder: Bool { entry == nil }
    var fileCount: Int { entry == nil ? children.reduce(0) { $0 + $1.fileCount } : 1 }

    init(key: String, name: String, entry: SPPlaylistEntry? = nil, parent: SPPlaylistNode? = nil) {
        self.key = key
        self.name = name
        self.entry = entry
        self.parent = parent
    }
}

/// Keyboard selection is independent of playback. Arrow keys explore the tree;
/// Enter or a pointer click explicitly opens a leaf.
private final class SPPlaylistOutlineView: NSOutlineView {
    var onActivate: ((Int) -> Void)?
    var onActionAtPoint: ((NSPoint) -> Bool)?
    var onEscape: (() -> Void)?
    var onPlaybackKeyDown: ((NSEvent) -> Bool)?
    var onPlaybackKeyUp: ((NSEvent) -> Bool)?
    var onResignKeyboardFocus: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if onPlaybackKeyDown?(event) == true { return }
        switch event.keyCode {
        case 36, 76: if selectedRow >= 0 { onActivate?(selectedRow) }
        case 53: onEscape?()
        default: super.keyDown(with: event)
        }
    }
    override func keyUp(with event: NSEvent) {
        if onPlaybackKeyUp?(event) != true { super.keyUp(with: event) }
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResignKeyboardFocus?() }
        return resigned
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let actionHit = onActionAtPoint?(point) == true
        let selectedItems = actionHit ? selectedRowIndexes.compactMap { self.item(atRow: $0) as? SPPlaylistNode } : []
        let clicked = row(at: point)
        let item = clicked >= 0 ? self.item(atRow: clicked) as? SPPlaylistNode : nil
        let wasExpanded = item.map { isItemExpanded($0) } ?? false
        super.mouseDown(with: event)
        if actionHit {
            // Child buttons normally receive their own native mouse tracking.
            // If AppKit routes the press through the outline, don't turn it
            // into media activation or steal the tree's keyboard selection.
            let rows = IndexSet(selectedItems.compactMap { item in
                let row = self.row(forItem: item)
                return row >= 0 ? row : nil
            })
            selectRowIndexes(rows, byExtendingSelection: false)
            return
        }
        if let item {
            // Resolve again after tracking: a live catalogue can change indices.
            let current = row(forItem: item)
            guard current >= 0 else { return }
            if item.isFolder {
                // Disclosure clicks are already handled by NSOutlineView;
                // clicking the folder label performs the same single toggle.
                if isItemExpanded(item) == wasExpanded { onActivate?(current) }
            } else { onActivate?(current) }
        }
    }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

private final class SPPlaylistRowView: NSTableRowView {
    var current = false { didSet { needsDisplay = true } }
    override var isEmphasized: Bool { get { false } set {} }
    override func drawBackground(in dirtyRect: NSRect) {
        if current {
            NSColor.white.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
    }
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.white.withAlphaComponent(current ? 0.04 : 0.08).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}

private final class SPPlaylistDownloadProgressView: NSView {
    var fraction: Double = 0 {
        didSet { needsDisplay = true; setAccessibilityValue(fraction) }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("torrent.playlist.file.progress")
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityMinValue(0)
        setAccessibilityMaxValue(1)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SPPlaylistDownloadProgressView: no coder path") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
        guard fraction > 0 else { return }
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width * fraction,
            height: bounds.height), xRadius: 2, yRadius: 2).fill()
    }
}

private final class SPPlaylistCellView: NSTableCellView {
    private let icon = NSImageView()
    private let caption = SPPlaylistLabel(size: 13)
    private let detail = SPPlaylistLabel(size: 11, secondary: true)
    private let count = SPPlaylistLabel(size: 11, secondary: true)
    private let fileAction = NSButton()
    private let downloadDetail = SPPlaylistLabel(size: 10.5, secondary: true)
    private let downloadProgress = SPPlaylistDownloadProgressView(frame: .zero)
    private var folder = false
    private var detailCount = 0
    private var hasDownloadDetail = false
    private var fileSave: SPTorrentFileSavePresentation?
    var onActivate: (() -> Void)?
    var onFileAction: (() -> Void)?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("playlist.cell")
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = NSColor(white: 0.82, alpha: 1)
        count.alignment = .right
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byWordWrapping
        fileAction.title = ""
        fileAction.isBordered = false
        fileAction.contentTintColor = .white
        fileAction.imagePosition = .imageOnly
        fileAction.focusRingType = .default
        fileAction.target = self
        fileAction.action = #selector(performFileAction)
        fileAction.identifier = NSUserInterfaceItemIdentifier("torrent.playlist.file.action")
        downloadDetail.identifier = NSUserInterfaceItemIdentifier("torrent.playlist.file.status")
        downloadDetail.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        for view in [icon, caption, detail, count, downloadDetail, downloadProgress, fileAction] {
            addSubview(view)
        }
        for view in [icon, caption, detail, count] { view.setAccessibilityElement(false) }
        downloadDetail.setAccessibilityElement(false)
        setAccessibilityElement(true)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SPPlaylistCellView: no coder path") }

    func configure(_ node: SPPlaylistNode, current: Bool,
                   canSave: Bool, save: SPTorrentFileSavePresentation?) {
        folder = node.isFolder
        fileSave = folder || !canSave ? nil : save
        caption.stringValue = node.name
        caption.font = .systemFont(ofSize: 13, weight: folder ? .medium : .regular)
        caption.textColor = .white
        count.stringValue = folder && node.parent != nil ? L("playlist.items", node.fileCount) : ""
        count.isHidden = count.stringValue.isEmpty
        var details: [String] = []
        if current { details.append(L("playlist.currentlyPlaying")) }
        if node.entry?.isGrowing == true { details.append(L("playlist.updatingFile")) }
        detail.stringValue = details.joined(separator: "\n")
        detailCount = details.count
        detail.isHidden = detailCount == 0
        let symbol = folder ? "folder" : (current ? "play.fill" : "doc")
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: current ? 13 : 16, weight: .regular))
        icon.contentTintColor = current ? .white : NSColor(white: 0.76, alpha: 1)
        toolTip = node.entry?.relativePath ?? node.name
        fileAction.isHidden = folder || !canSave
        fileAction.isEnabled = fileSave?.phase != .cancelling
        var actionTitle = L("torrent.saveFile")
        var actionSymbol = "arrow.down.to.line"
        var saveDetail = ""
        switch fileSave?.phase {
        case .saving:
            actionTitle = L("torrent.cancelSave")
            actionSymbol = "xmark"
            if let save = fileSave {
                let percent = NumberFormatter.localizedString(from: NSNumber(value: save.fraction), number: .percent)
                let received = ByteCountFormatter.string(fromByteCount: max(0, save.receivedBytes), countStyle: .file)
                let expected = ByteCountFormatter.string(fromByteCount: max(0, save.expectedBytes), countStyle: .file)
                saveDetail = L("torrent.fileSaveProgress", percent, received, expected)
            }
        case .cancelling:
            actionTitle = L("torrent.cancellingSave")
            actionSymbol = "ellipsis"
            saveDetail = actionTitle
        case .saved:
            actionTitle = L("torrent.showSavedFile")
            actionSymbol = "checkmark.circle"
            saveDetail = L("torrent.fileSaved")
        case .failed:
            actionTitle = L("torrent.retrySave")
            actionSymbol = "arrow.clockwise"
            saveDetail = L("torrent.fileSaveFailed")
        case .cancelled:
            actionTitle = L("torrent.retrySave")
            actionSymbol = "arrow.down.to.line"
            saveDetail = L("torrent.fileSaveCancelled")
        case nil: break
        }
        fileAction.image = NSImage(systemSymbolName: actionSymbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        fileAction.toolTip = actionTitle
        fileAction.setAccessibilityLabel(actionTitle + ": " + node.name)
        hasDownloadDetail = !saveDetail.isEmpty
        downloadDetail.stringValue = saveDetail
        downloadDetail.toolTip = fileSave?.failureDescription ?? saveDetail
        downloadDetail.isHidden = !hasDownloadDetail
        downloadProgress.isHidden = fileSave?.hasProgress != true
        downloadProgress.fraction = fileSave?.fraction ?? 0
        downloadProgress.setAccessibilityLabel(node.name)
        setAccessibilityRole(folder ? .cell : .button)
        setAccessibilityLabel(([node.entry?.relativePath ?? node.name] + details + (hasDownloadDetail ? [saveDetail] : [])).joined(separator: ", "))
        setAccessibilityValue(current)
        setAccessibilityChildren(fileAction.isHidden ? [] : [fileAction] + (downloadProgress.isHidden ? [] : [downloadProgress]))
        needsLayout = true
    }
    func isFileAction(at point: NSPoint, from view: NSView) -> Bool {
        !fileAction.isHidden && fileAction.frame.contains(convert(point, from: view))
    }
    override func layout() {
        let trailing: CGFloat = !fileAction.isHidden ? 42 : (count.isHidden ? 10 : min(88, bounds.width * 0.32))
        let hasDetail = detailCount > 0 || hasDownloadDetail
        icon.frame = NSRect(x: 2, y: hasDetail ? 10 : bounds.midY - 9, width: 18, height: 18)
        caption.frame = NSRect(x: 28, y: hasDetail ? 7 : bounds.midY - 9,
                               width: max(0, bounds.width - 28 - trailing), height: 20)
        detail.frame = NSRect(x: 28, y: 28, width: max(0, bounds.width - 38), height: CGFloat(detailCount) * 14)
        count.frame = NSRect(x: max(28, bounds.width - trailing), y: bounds.midY - 8,
                             width: max(0, trailing - 8), height: 18)
        fileAction.frame = NSRect(x: max(0, bounds.width - 34), y: hasDetail ? 3 : bounds.midY - 15, width: 30, height: 30)
        let downloadY = 28 + CGFloat(detailCount) * 14
        downloadDetail.frame = NSRect(x: 28, y: downloadY, width: max(0, bounds.width - 38), height: 17)
        downloadProgress.frame = NSRect(x: 28, y: downloadY + 20, width: max(0, bounds.width - 38), height: 3)
    }
    @objc private func performFileAction() {
        guard !fileAction.isHidden, fileAction.isEnabled else { return }
        onFileAction?()
    }
    override func accessibilityPerformPress() -> Bool {
        guard !folder else { return false }
        onActivate?()
        return true
    }
}

private final class SPPlaylistAutoAdvanceButton: NSButton {
    var onChange: ((Bool) -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var state: NSControl.StateValue { didSet { needsDisplay = true; setAccessibilityValue(state == .on) } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        title = ""
        isBordered = false
        focusRingType = .none
        setButtonType(.toggle)
        target = self
        action = #selector(changed)
        identifier = NSUserInterfaceItemIdentifier("playlist.autoAdvance")
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(L("playlist.autoAdvance"))
        toolTip = L("playlist.autoAdvance")
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SPPlaylistAutoAdvanceButton: no coder path") }
    @objc private func changed() { onChange?(state == .on) }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    override func draw(_ dirtyRect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let textRect = NSRect(x: 0, y: bounds.midY - 17, width: max(0, bounds.width - 52), height: 36)
        (L("playlist.autoAdvance") as NSString).draw(in: textRect, withAttributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(white: 0.83, alpha: 1), .paragraphStyle: paragraph])
        let track = NSRect(x: bounds.width - 36, y: bounds.midY - 10, width: 36, height: 20)
        NSColor.white.withAlphaComponent(state == .on ? 0.4 : 0.17).setFill()
        NSBezierPath(roundedRect: track, xRadius: 10, yRadius: 10).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: track.minX + (state == .on ? 18 : 2), y: track.minY + 2, width: 16, height: 16)).fill()
        if window?.firstResponder === self {
            NSColor.white.withAlphaComponent(0.65).setStroke()
            NSBezierPath(roundedRect: track.insetBy(dx: -3, dy: -3), xRadius: 13, yRadius: 13).stroke()
        }
    }
}

/// A virtualized folder tree. Catalogue refreshes preserve the user's expanded
/// folders, keyboard selection and scroll position without performing file I/O.
@MainActor
final class SPPlaylistView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    static let idealWidth: CGFloat = 360
    var preferredMenuSize: NSSize { NSSize(width: Self.idealWidth, height: 500) }
    var preferredHeight: CGFloat { preferredMenuSize.height }
    var onOpenFolder: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onClose: (() -> Void)?
    var onSelect: ((URL) -> Void)?
    var onAutoAdvanceChanged: ((Bool) -> Void)?
    var onOpenTorrent: (() -> Void)? { didSet { updateSourceButton() } }
    var onSaveTorrentFile: (() -> Void)?
    var onSaveTorrentEntry: ((URL) -> Void)?
    var onCancelTorrentEntrySave: ((URL) -> Void)?
    var onRevealTorrentEntrySave: ((URL) -> Void)?
    var onCancelTorrentSave: (() -> Void)?
    var onCancelTorrentOpen: (() -> Void)?
    var onTogglePauseBuffer: (() -> Void)?
    /// Only an unmodified Space is delegated to playback. Tree navigation and
    /// AppKit key equivalents stay with the normal responder chain.
    var onPlaybackKeyDown: ((NSEvent) -> Void)?
    var onPlaybackKeyUp: ((NSEvent) -> Void)?
    var onPlaybackFocusLost: (() -> Void)?

    private let titleLabel = SPPlaylistLabel(size: 20, weight: .semibold)
    private let subtitleLabel = SPPlaylistLabel(size: 12, secondary: true)
    private let openFolderButton = NSButton()
    private let refreshButton = NSButton()
    private let closeButton = NSButton()
    private let spinner = NSProgressIndicator()
    private let refreshingLabel = SPPlaylistLabel(L("playlist.refreshing"), size: 11, secondary: true)
    private let statusLabel = SPPlaylistLabel(size: 11, secondary: true)
    private let scrollView = NSScrollView()
    private let outline = SPPlaylistOutlineView()
    private let emptyLabel = SPPlaylistLabel(size: 13, secondary: true)
    private let autoAdvanceButton = SPPlaylistAutoAdvanceButton(frame: .zero)
    private let preferencesHint = SPPlaylistLabel(L("playlist.preferencesHint"), size: 10.5, secondary: true)
    private var torrentPresentation: SPTorrentPlaylistPresentation?
    private let bufferStatusView = SPTorrentBufferStatusView(frame: .zero)
    private let torrentStatus = SPPlaylistLabel(size: 12)
    private let torrentDetails = SPPlaylistLabel(size: 10.5, secondary: true)
    private let torrentProgress = NSProgressIndicator()
    private let torrentActionButton = NSButton()
    private let pauseBufferButton = NSButton()
    private var compactTorrentFooter: Bool { bounds.height < 340 }
    private var hasTorrentDetails: Bool { !(torrentPresentation?.details?.isEmpty ?? true) }
    private var hasTorrentProgress: Bool { torrentPresentation?.downloadProgress?.isFinite == true }
    private var hasPauseBufferAction: Bool { !(torrentPresentation?.pauseBufferAction?.isEmpty ?? true) }
    private var torrentDetailsHeight: CGFloat {
        guard hasTorrentDetails else { return 0 }
        let width = max(1, bounds.width - 36)
        return max(14, min(66, ceil(torrentDetails.cell?.cellSize(forBounds:
            NSRect(x: 0, y: 0, width: width, height: 1000)).height ?? 28)))
    }
    private var hasTorrentAction: Bool {
        guard let presentation = torrentPresentation else { return false }
        return presentation.isResolving || presentation.isSaving || presentation.canSave
    }
    private var torrentContentHeight: CGFloat {
        guard torrentPresentation != nil else { return 0 }
        if torrentPresentation?.bufferStatus != nil {
            bufferStatusView.isCompact = compactTorrentFooter
            return bufferStatusView.preferredHeight
        }
        if compactTorrentFooter { return 52 + (hasPauseBufferAction ? 34 : 0) }
        return 42 + (hasTorrentDetails ? torrentDetailsHeight + 2 : 0)
            + (hasTorrentProgress ? 12 : 0) + (hasPauseBufferAction ? 34 : 0) + (hasTorrentAction ? 34 : 0)
    }
    private var footerHeight: CGFloat {
        torrentPresentation == nil ? (rootURL != nil && bounds.height >= 440 ? 78 : 55) : 55 + torrentContentHeight
    }
    private var rootURL: URL?
    private var entries: [SPPlaylistEntry] = []
    private var torrentFileSourceRoot: String?
    private var torrentFileSaves: [String: SPTorrentFileSavePresentation] = [:]
    private var currentURL: URL?
    private var rootNode: SPPlaylistNode?
    private var nodes: [String: SPPlaylistNode] = [:]
    private var expandedKeys: Set<String> = []
    private var restoring = false
    private var statusHeight: CGFloat = 0
    private var forwardingKeyDown = false
    private var playbackSpaceIsDown = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var isHidden: Bool {
        didSet { if isHidden { cancelPlaybackKey() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.055, alpha: 0.95).cgColor
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        identifier = NSUserInterfaceItemIdentifier("playlist.panel")
        setAccessibilityRole(.group)
        setAccessibilityLabel(L("playlist.title"))
        titleLabel.identifier = NSUserInterfaceItemIdentifier("playlist.rootTitle")
        subtitleLabel.identifier = NSUserInterfaceItemIdentifier("playlist.count")
        addSubview(titleLabel)
        addSubview(subtitleLabel)
        for (button, symbol, text, name) in [(openFolderButton, "folder", L("playlist.openFolder"), "playlist.openFolder"),
                                             (refreshButton, "arrow.clockwise", L("playlist.refresh"), "playlist.refresh"),
                                             (closeButton, "xmark", L("playlist.close"), "playlist.close")] {
            button.title = button === openFolderButton ? text : ""
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
            button.imagePosition = button === openFolderButton ? .imageLeading : .imageOnly
            button.font = .systemFont(ofSize: 13)
            button.isBordered = false
            button.contentTintColor = .white
            button.target = self
            button.identifier = NSUserInterfaceItemIdentifier(name)
            button.setAccessibilityLabel(text)
            button.toolTip = text
            addSubview(button)
        }
        openFolderButton.alignment = .left
        openFolderButton.action = #selector(openFolder)
        refreshButton.action = #selector(refresh)
        closeButton.action = #selector(close)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel(L("playlist.refreshing"))
        addSubview(spinner)
        refreshingLabel.isHidden = true
        addSubview(refreshingLabel)
        statusLabel.maximumNumberOfLines = 3
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.identifier = NSUserInterfaceItemIdentifier("playlist.status")
        addSubview(statusLabel)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.contentView.drawsBackground = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("playlist.name"))
        column.resizingMask = .autoresizingMask
        column.width = Self.idealWidth - 20
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.selectionHighlightStyle = .regular
        outline.focusRingType = .none
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.indentationPerLevel = 18
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.allowsEmptySelection = true
        outline.allowsMultipleSelection = false
        outline.autoresizesOutlineColumn = true
        outline.dataSource = self
        outline.delegate = self
        outline.identifier = NSUserInterfaceItemIdentifier("playlist.tree")
        outline.setAccessibilityLabel(L("playlist.title"))
        outline.onActivate = { [weak self] row in self?.activate(row) }
        outline.onActionAtPoint = { [weak self] point in
            guard let self else { return false }
            let row = self.outline.row(at: point)
            guard row >= 0, let cell = self.outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SPPlaylistCellView else { return false }
            return cell.isFileAction(at: point, from: self.outline)
        }
        outline.onEscape = { [weak self] in self?.onClose?() }
        outline.onPlaybackKeyDown = { [weak self] in self?.routePlaybackKeyDown($0) ?? false }
        outline.onPlaybackKeyUp = { [weak self] in self?.routePlaybackKeyUp($0) ?? false }
        outline.onResignKeyboardFocus = { [weak self] in self?.checkPlaybackFocusAfterChange() }
        scrollView.documentView = outline
        addSubview(scrollView)
        emptyLabel.maximumNumberOfLines = 3
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.alignment = .center
        emptyLabel.identifier = NSUserInterfaceItemIdentifier("playlist.empty")
        addSubview(emptyLabel)
        autoAdvanceButton.onChange = { [weak self] in self?.onAutoAdvanceChanged?($0) }
        addSubview(autoAdvanceButton)
        preferencesHint.identifier = NSUserInterfaceItemIdentifier("playlist.preferencesHint")
        preferencesHint.toolTip = L("playlist.preferencesHint")
        addSubview(preferencesHint)
        torrentStatus.identifier = NSUserInterfaceItemIdentifier("torrent.playlist.status")
        torrentDetails.identifier = NSUserInterfaceItemIdentifier("torrent.playlist.details")
        torrentDetails.maximumNumberOfLines = 4
        torrentDetails.lineBreakMode = .byWordWrapping
        torrentProgress.style = .bar
        torrentProgress.isIndeterminate = false
        torrentProgress.minValue = 0
        torrentProgress.maxValue = 1
        torrentProgress.identifier = NSUserInterfaceItemIdentifier("torrent.playlist.progress")
        torrentActionButton.font = .systemFont(ofSize: 12)
        torrentActionButton.isBordered = false
        torrentActionButton.contentTintColor = .white
        torrentActionButton.wantsLayer = true
        torrentActionButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        torrentActionButton.layer?.cornerRadius = 6
        torrentActionButton.target = self
        torrentActionButton.action = #selector(torrentAction)
        torrentActionButton.identifier = NSUserInterfaceItemIdentifier("torrent.playlist.action")
        pauseBufferButton.font = .systemFont(ofSize: 12)
        pauseBufferButton.isBordered = false
        pauseBufferButton.contentTintColor = .white
        pauseBufferButton.wantsLayer = true
        pauseBufferButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        pauseBufferButton.layer?.cornerRadius = 6
        pauseBufferButton.target = self
        pauseBufferButton.action = #selector(togglePauseBuffer)
        pauseBufferButton.identifier = NSUserInterfaceItemIdentifier("torrent.playlist.pauseBuffer")
        for view in [torrentStatus, torrentDetails, torrentProgress, torrentActionButton, pauseBufferButton] {
            view.isHidden = true
            addSubview(view)
        }
        bufferStatusView.isHidden = true
        bufferStatusView.onAction = { [weak self] action in
            switch action {
            case .stopBuffering, .resumeBuffering: self?.onTogglePauseBuffer?()
            case .cancelOpening: self?.onCancelTorrentOpen?()
            }
        }
        addSubview(bufferStatusView)
        configure(root: nil, entries: [], currentURL: nil, autoAdvance: true, isRefreshing: false, error: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SPPlaylistView: no coder path") }
    @objc private func openFolder() {
        if torrentPresentation != nil, let onOpenTorrent { onOpenTorrent() }
        else { onOpenFolder?() }
    }
    @objc private func torrentAction() {
        guard let presentation = torrentPresentation else { return }
        if presentation.isResolving { onCancelTorrentOpen?() }
        else if presentation.isSaving { onCancelTorrentSave?() }
        else if presentation.canSave { onSaveTorrentFile?() }
    }
    @objc private func togglePauseBuffer() {
        guard hasPauseBufferAction, torrentPresentation?.pauseBufferEnabled == true else { return }
        onTogglePauseBuffer?()
    }
    private func updateSourceButton() {
        let title = torrentPresentation != nil && onOpenTorrent != nil ? L("torrent.openSource") : L("playlist.openFolder")
        openFolderButton.title = title
        openFolderButton.setAccessibilityLabel(title)
        openFolderButton.toolTip = title
    }
    func setTorrentPresentation(_ presentation: SPTorrentPlaylistPresentation?) {
        torrentPresentation = presentation
        let modernFooter = presentation?.bufferStatus != nil
        bufferStatusView.isCompact = compactTorrentFooter
        bufferStatusView.setPresentation(presentation?.bufferStatus)
        bufferStatusView.isHidden = !modernFooter
        torrentStatus.stringValue = presentation?.status ?? ""
        torrentStatus.toolTip = presentation?.status
        torrentStatus.isHidden = presentation == nil
        torrentDetails.stringValue = presentation?.details ?? ""
        torrentDetails.toolTip = presentation?.details
        torrentDetails.isHidden = presentation == nil || !hasTorrentDetails
        torrentProgress.isHidden = presentation == nil || !hasTorrentProgress
        if let progress = presentation?.downloadProgress, progress.isFinite {
            torrentProgress.doubleValue = min(1, max(0, progress))
        }
        torrentActionButton.isHidden = !hasTorrentAction
        pauseBufferButton.isHidden = !hasPauseBufferAction
        pauseBufferButton.isEnabled = presentation?.pauseBufferEnabled == true
        pauseBufferButton.title = presentation?.pauseBufferAction ?? ""
        pauseBufferButton.toolTip = presentation?.pauseBufferAction
        pauseBufferButton.setAccessibilityLabel(presentation?.pauseBufferAction ?? "")
        if let presentation {
            let title = presentation.isResolving ? L("torrent.cancel")
                : (presentation.isSaving ? L("torrent.cancelSave") : L("torrent.saveFile"))
            torrentActionButton.title = title
            torrentActionButton.toolTip = title
            torrentActionButton.setAccessibilityLabel(title)
        }
        if modernFooter {
            for view in [torrentStatus, torrentDetails, torrentProgress, torrentActionButton, pauseBufferButton] {
                view.isHidden = true
            }
        }
        updateSourceButton()
        needsLayout = true
    }
    @objc private func refresh() { onRefresh?() }
    @objc private func close() { onClose?() }
    private func canonical(_ url: URL?) -> String? { url?.standardizedFileURL.path }

    func configure(root: URL?, entries nextEntries: [SPPlaylistEntry], currentURL nextCurrentURL: URL?,
                   autoAdvance: Bool, isRefreshing: Bool, error: String?) {
        let rootChanged = canonical(rootURL) != canonical(root)
        let currentChanged = canonical(currentURL) != canonical(nextCurrentURL)
        let contentsChanged = entries != nextEntries
        let selectedKey = (outline.item(atRow: outline.selectedRow) as? SPPlaylistNode)?.key
        let oldOrigin = scrollView.contentView.bounds.origin
        rootURL = root
        currentURL = nextCurrentURL
        entries = nextEntries
        titleLabel.stringValue = root?.lastPathComponent ?? L("playlist.title")
        titleLabel.toolTip = root?.path
        if let index = entries.firstIndex(where: { canonical($0.url) == canonical(nextCurrentURL) }) {
            subtitleLabel.stringValue = L("playlist.title") + " · " + L("playlist.position", index + 1, entries.count)
        } else { subtitleLabel.stringValue = L("playlist.items", entries.count) }
        refreshButton.isEnabled = root != nil && !isRefreshing
        refreshButton.isHidden = isRefreshing
        refreshingLabel.isHidden = !isRefreshing
        if isRefreshing { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        autoAdvanceButton.state = autoAdvance ? .on : .off
        let missingCurrent = root.map { folder in
            guard let currentPath = canonical(nextCurrentURL),
                  currentPath.hasPrefix(folder.standardizedFileURL.path == "/" ? "/" : folder.standardizedFileURL.path + "/") else { return false }
            return !entries.contains { canonical($0.url) == currentPath }
        } ?? false
        statusLabel.stringValue = error ?? (missingCurrent ? L("playlist.currentMissing") : "")
        statusLabel.toolTip = error
        statusLabel.isHidden = statusLabel.stringValue.isEmpty
        emptyLabel.stringValue = root == nil ? L("playlist.chooseFolder") : L("playlist.empty")
        emptyLabel.isHidden = !entries.isEmpty
        if rootChanged { expandedKeys.removeAll() }
        if rootChanged || contentsChanged || rootNode == nil {
            buildTree()
            restoring = true
            outline.reloadData()
            if rootChanged, let rootNode { expandedKeys.insert(rootNode.key) }
            if rootChanged || currentChanged { expandCurrentAncestors() }
            for key in expandedKeys.sorted(by: { $0.count < $1.count }) {
                if let node = nodes[key] { outline.expandItem(node) }
            }
            let selection = !rootChanged ? selectedKey.flatMap { nodes[$0] } : nil
            let target = currentChanged ? nodeForCurrent() : (selection ?? nodeForCurrent())
            let row = target.map { outline.row(forItem: $0) } ?? -1
            if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            else { outline.deselectAll(nil) }
            restoring = false
        } else if currentChanged {
            restoring = true
            expandCurrentAncestors()
            if let node = nodeForCurrent() {
                let row = outline.row(forItem: node)
                if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            }
            let visibleRows = IndexSet(integersIn: 0..<outline.numberOfRows)
            outline.noteHeightOfRows(withIndexesChanged: visibleRows)
            outline.reloadData(forRowIndexes: visibleRows, columnIndexes: IndexSet(integer: 0))
            restoring = false
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        if currentChanged, let node = nodeForCurrent(), outline.row(forItem: node) >= 0 {
            outline.scrollRowToVisible(outline.row(forItem: node))
        } else if contentsChanged && !rootChanged {
            let maximumY = max(0, outline.bounds.height - scrollView.contentSize.height)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(maximumY, max(0, oldOrigin.y))))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        outline.enumerateAvailableRowViews { [weak self] rowView, row in
            guard let self, let view = rowView as? SPPlaylistRowView,
                  let node = self.outline.item(atRow: row) as? SPPlaylistNode else { return }
            view.current = self.isCurrent(node)
        }
    }

    /// Only a current catalogue can receive download observations. Updating a
    /// progress tick changes existing cells, never the outline selection/tree.
    func setTorrentFileDownloads(_ states: [URL: SPTorrentFileSavePresentation]?, sourceRoot: URL?) {
        let previousRoot = torrentFileSourceRoot
        let previous = torrentFileSaves
        let validRoot = canonical(sourceRoot)
        torrentFileSourceRoot = states != nil && validRoot == canonical(rootURL) ? validRoot : nil
        let known = Set(entries.compactMap { canonical($0.url) })
        var next: [String: SPTorrentFileSavePresentation] = [:]
        if torrentFileSourceRoot != nil {
            for (url, state) in states ?? [:] {
                if let key = canonical(url), known.contains(key) { next[key] = state }
            }
        }
        torrentFileSaves = next
        let actionsChanged = previousRoot != torrentFileSourceRoot
        let changed = actionsChanged ? known : Set(previous.keys).union(next.keys).filter { previous[$0] != next[$0] }
        guard !changed.isEmpty else { return }
        let origin = scrollView.contentView.bounds.origin
        var heightRows = IndexSet()
        for node in nodes.values {
            guard let url = node.entry?.url, let key = canonical(url), changed.contains(key) else { continue }
            let row = outline.row(forItem: node)
            guard row >= 0 else { continue }
            let old = previousRoot == canonical(rootURL) ? previous[key] : nil
            if rowHeight(node, save: old) != rowHeight(node, save: next[key]) { heightRows.insert(row) }
            if let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SPPlaylistCellView {
                configure(cell, node: node)
            }
        }
        if !heightRows.isEmpty {
            NSAnimationContext.runAnimationGroup { context in
                // A row action changes its contents at once. Keeping AppKit's
                // old animated row frame briefly clips the new progress rail.
                context.duration = 0
                context.allowsImplicitAnimation = false
                outline.noteHeightOfRows(withIndexesChanged: heightRows)
                // Recreate only rows whose structure changed; ordinary byte
                // ticks keep their existing cell, keyboard focus and scroll.
                outline.reloadData(forRowIndexes: heightRows, columnIndexes: IndexSet(integer: 0))
            }
            layoutSubtreeIfNeeded()
            let maximumY = max(0, outline.bounds.height - scrollView.contentSize.height)
            scrollView.contentView.scroll(to: NSPoint(x: origin.x, y: min(maximumY, max(0, origin.y))))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
    private var canSaveTorrentEntries: Bool {
        torrentFileSourceRoot != nil && torrentFileSourceRoot == canonical(rootURL)
    }
    private func fileSave(for node: SPPlaylistNode) -> SPTorrentFileSavePresentation? {
        guard canSaveTorrentEntries, let key = canonical(node.entry?.url) else { return nil }
        return torrentFileSaves[key]
    }
    private func configure(_ cell: SPPlaylistCellView, node: SPPlaylistNode) {
        cell.configure(node, current: isCurrent(node), canSave: canSaveTorrentEntries, save: fileSave(for: node))
        cell.onActivate = { [weak self, weak node] in
            guard let self, let node, self.nodes[node.key] === node,
                  let url = node.entry?.url else { return }
            self.onSelect?(url)
        }
        cell.onFileAction = { [weak self, weak node] in
            guard let self, let node, self.nodes[node.key] === node,
                  self.canSaveTorrentEntries, let url = node.entry?.url else { return }
            switch self.fileSave(for: node)?.phase {
            case .saving: self.onCancelTorrentEntrySave?(url)
            case .cancelling: break
            case .saved: self.onRevealTorrentEntrySave?(url)
            case .failed, .cancelled, nil: self.onSaveTorrentEntry?(url)
            }
        }
    }
    private func rowHeight(_ node: SPPlaylistNode, save: SPTorrentFileSavePresentation?) -> CGFloat {
        if node.isFolder { return 34 }
        let details = (isCurrent(node) ? 1 : 0) + (node.entry?.isGrowing == true ? 1 : 0)
        let base: CGFloat = details == 0 ? 40 : (details == 1 ? 58 : 72)
        guard let save else { return base }
        return max(base, 28 + CGFloat(details) * 14 + 17 + (save.hasProgress ? 16 : 11))
    }

    private func buildTree() {
        nodes.removeAll(keepingCapacity: true)
        guard let rootURL else { rootNode = nil; return }
        let root = SPPlaylistNode(key: "folder:", name: rootURL.lastPathComponent)
        rootNode = root
        nodes[root.key] = root
        for entry in entries {
            let components = entry.relativePath.split(separator: "/").map(String.init)
            guard let last = components.last else { continue }
            var parent = root
            var relative = ""
            for name in components.dropLast() {
                relative = relative.isEmpty ? name : relative + "/" + name
                let key = "folder:" + relative
                if let existing = nodes[key] { parent = existing }
                else {
                    let child = SPPlaylistNode(key: key, name: name, parent: parent)
                    nodes[key] = child
                    parent.children.append(child)
                    parent = child
                }
            }
            let title = entry.displayName == entry.url.lastPathComponent
                ? entry.url.deletingPathExtension().lastPathComponent : entry.displayName
            let leaf = SPPlaylistNode(key: "file:" + entry.relativePath, name: title.isEmpty ? last : title,
                                      entry: entry, parent: parent)
            parent.children.append(leaf)
            nodes[leaf.key] = leaf
        }
        func sort(_ node: SPPlaylistNode) {
            node.children.sort {
                SPPlaylistOrder.nodeLess($0.name, $1.name,
                    leftIsFolder: $0.isFolder, rightIsFolder: $1.isFolder,
                    leftKey: $0.key, rightKey: $1.key)
            }
            node.children.filter(\.isFolder).forEach(sort)
        }
        sort(root)
    }
    private func nodeForCurrent() -> SPPlaylistNode? {
        guard let path = canonical(currentURL) else { return nil }
        return nodes.values.first { canonical($0.entry?.url) == path }
    }
    private func isCurrent(_ node: SPPlaylistNode) -> Bool {
        guard let url = node.entry?.url else { return false }
        return canonical(url) == canonical(currentURL)
    }
    private func expandCurrentAncestors() {
        var parent = nodeForCurrent()?.parent
        var ancestors: [SPPlaylistNode] = []
        while let node = parent { ancestors.append(node); parent = node.parent }
        for node in ancestors.reversed() {
            expandedKeys.insert(node.key)
            outline.expandItem(node)
        }
    }
    private func activate(_ row: Int) {
        guard let node = outline.item(atRow: row) as? SPPlaylistNode else { return }
        if let url = node.entry?.url { onSelect?(url) }
        else if outline.isItemExpanded(node) { outline.collapseItem(node) }
        else { outline.expandItem(node) }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? SPPlaylistNode { return node.children.count }
        return rootNode == nil ? 0 : 1
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? SPPlaylistNode { return node.children[index] }
        return rootNode!
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SPPlaylistNode)?.isFolder == true
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SPPlaylistNode else { return nil }
        let cell = (outlineView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("playlist.cell"), owner: self) as? SPPlaylistCellView)
            ?? SPPlaylistCellView(frame: .zero)
        configure(cell, node: node)
        return cell
    }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = SPPlaylistRowView()
        if let node = item as? SPPlaylistNode { row.current = isCurrent(node) }
        return row
    }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? SPPlaylistNode else { return 42 }
        return rowHeight(node, save: fileSave(for: node))
    }
    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !restoring, let node = notification.userInfo?["NSObject"] as? SPPlaylistNode else { return }
        expandedKeys.insert(node.key)
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !restoring, let node = notification.userInfo?["NSObject"] as? SPPlaylistNode else { return }
        expandedKeys.remove(node.key)
    }

    override func layout() {
        super.layout()
        titleLabel.frame = NSRect(x: 18, y: 15, width: max(0, bounds.width - 76), height: 26)
        subtitleLabel.frame = NSRect(x: 18, y: 45, width: max(0, bounds.width - 36), height: 18)
        closeButton.frame = NSRect(x: max(0, bounds.width - 48), y: 13, width: 32, height: 32)
        openFolderButton.frame = NSRect(x: 14, y: 73, width: max(0, bounds.width - 78), height: 31)
        refreshButton.frame = NSRect(x: max(0, bounds.width - 48), y: 73, width: 32, height: 31)
        spinner.frame = NSRect(x: max(0, bounds.width - 41), y: 81, width: 16, height: 16)
        refreshingLabel.frame = NSRect(x: 20, y: 111, width: max(0, bounds.width - 40), height: 16)
        let baseBodyTop: CGFloat = bounds.height < 340 ? 110 : 132
        refreshingLabel.alphaValue = bounds.height < 340 ? 0 : 1
        let availableStatus = max(0, min(62, bounds.height - baseBodyTop - footerHeight - 30))
        if statusLabel.isHidden { statusHeight = 0 }
        else {
            let height = (statusLabel.stringValue as NSString).boundingRect(
                with: NSSize(width: max(1, bounds.width - 36), height: 1000),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: NSFont.systemFont(ofSize: 11)]).height
            statusHeight = min(availableStatus, ceil(height) + 14)
        }
        statusLabel.frame = NSRect(x: 18, y: baseBodyTop, width: max(0, bounds.width - 36), height: max(0, statusHeight - 8))
        let bodyTop = baseBodyTop + statusHeight
        let footer = footerHeight
        scrollView.frame = NSRect(x: 8, y: bodyTop, width: max(0, bounds.width - 16), height: max(0, bounds.height - bodyTop - footer))
        outline.tableColumns.first?.width = scrollView.contentSize.width
        emptyLabel.frame = NSRect(x: 30, y: bodyTop + max(0, scrollView.frame.height - 58) / 2,
                                 width: max(0, bounds.width - 60), height: min(58, scrollView.frame.height))
        let footerTop = bounds.height - footer
        autoAdvanceButton.frame = NSRect(x: 18, y: max(0, footerTop + torrentContentHeight + 6), width: max(0, bounds.width - 36), height: 42)
        preferencesHint.isHidden = torrentPresentation != nil || footer < 78
        preferencesHint.frame = NSRect(x: 18, y: max(0, bounds.height - 23), width: max(0, bounds.width - 36), height: 15)
        if torrentPresentation?.bufferStatus != nil {
            bufferStatusView.isCompact = compactTorrentFooter
            bufferStatusView.frame = NSRect(x: 18, y: footerTop, width: max(0, bounds.width - 36), height: torrentContentHeight)
        } else if torrentPresentation != nil {
            if compactTorrentFooter {
                if torrentPresentation?.isSaving == true || torrentPresentation?.isResolving == true {
                    torrentActionButton.title = L("torrent.cancel")
                }
                torrentStatus.frame = NSRect(x: 18, y: footerTop + 7, width: max(0, bounds.width - (hasTorrentAction ? 160 : 36)), height: 20)
                torrentDetails.isHidden = true
                torrentActionButton.frame = NSRect(x: max(18, bounds.width - 138), y: footerTop + 3, width: 120, height: 27)
                torrentProgress.frame = NSRect(x: 18, y: footerTop + 36, width: max(0, bounds.width - 36), height: 5)
                pauseBufferButton.frame = NSRect(x: 18, y: footerTop + 47, width: max(0, bounds.width - 36), height: 28)
            } else {
                if let presentation = torrentPresentation {
                    torrentActionButton.title = presentation.isResolving ? L("torrent.cancel")
                        : (presentation.isSaving ? L("torrent.cancelSave") : L("torrent.saveFile"))
                }
                torrentStatus.frame = NSRect(x: 18, y: footerTop + 10, width: max(0, bounds.width - 36), height: 20)
                var y = footerTop + 32
                torrentDetails.isHidden = !hasTorrentDetails
                if hasTorrentDetails {
                    torrentDetails.frame = NSRect(x: 18, y: y, width: max(0, bounds.width - 36), height: torrentDetailsHeight)
                    y += torrentDetailsHeight + 2
                }
                if hasTorrentProgress {
                    torrentProgress.frame = NSRect(x: 18, y: y + 3, width: max(0, bounds.width - 36), height: 5)
                    y += 12
                }
                if hasPauseBufferAction {
                    pauseBufferButton.frame = NSRect(x: 18, y: y + 3, width: max(0, bounds.width - 36), height: 28)
                    y += 34
                }
                torrentActionButton.frame = NSRect(x: 18, y: y + 3, width: max(0, bounds.width - 36), height: 28)
            }
        }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSRect(x: 18, y: bounds.height - footerHeight, width: max(0, bounds.width - 36), height: 0.5).fill()
        if torrentPresentation != nil {
            NSRect(x: 18, y: bounds.height - 55, width: max(0, bounds.width - 36), height: 0.5).fill()
        }
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(outline) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?(); return }
        if routePlaybackKeyDown(event) { return }
        // NSOutlineView forwards unhandled keys through its superviews. Never
        // send those events back down into the outline: that creates a cycle
        // ending in stack overflow (including Space and navigation at bounds).
        guard !forwardingKeyDown,
              window == nil || window?.firstResponder === self else {
            super.keyDown(with: event)
            return
        }
        forwardingKeyDown = true
        defer { forwardingKeyDown = false }
        window?.makeFirstResponder(outline)
        outline.keyDown(with: event)
    }
    override func keyUp(with event: NSEvent) {
        if !routePlaybackKeyUp(event) { super.keyUp(with: event) }
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { checkPlaybackFocusAfterChange() }
        return resigned
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { cancelPlaybackKey() }
        super.viewWillMove(toWindow: newWindow)
    }
    private func routePlaybackKeyDown(_ event: NSEvent) -> Bool {
        let modifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        guard event.keyCode == 49, event.modifierFlags.intersection(modifiers).isEmpty,
              let onPlaybackKeyDown else { return false }
        playbackSpaceIsDown = true
        onPlaybackKeyDown(event)
        return true
    }
    private func routePlaybackKeyUp(_ event: NSEvent) -> Bool {
        // A modifier may have changed while Space was held. Its release must
        // still terminate the already delegated hold.
        guard event.keyCode == 49, playbackSpaceIsDown else { return false }
        playbackSpaceIsDown = false
        onPlaybackKeyUp?(event)
        return true
    }
    private func cancelPlaybackKey() {
        guard playbackSpaceIsDown else { return }
        playbackSpaceIsDown = false
        onPlaybackFocusLost?()
    }
    private func checkPlaybackFocusAfterChange() {
        // AppKit publishes the new first responder after resignFirstResponder.
        // Moving panel -> tree keeps the hold; focusing a button/field or
        // leaving the panel cancels it instead of depending on a later keyUp.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let responder = self.window?.firstResponder
            if responder !== self && responder !== self.outline { self.cancelPlaybackKey() }
        }
    }
    override func cancelOperation(_ sender: Any?) { onClose?() }
}

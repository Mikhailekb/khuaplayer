import AppKit

@MainActor
private func SPTorrentSettingsLabel(_ text: String, size: CGFloat = 12,
                                    secondary: Bool = true) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: size)
    label.textColor = secondary ? NSColor(white: 0.69, alpha: 1) : .white
    label.maximumNumberOfLines = 0
    label.lineBreakMode = .byWordWrapping
    return label
}

/// Pure settings content, also renderable without opening a window or worker.
@MainActor
final class SPTorrentSettingsContentView: NSView {
    var onApply: ((Int) -> Void)?
    private let scrollView = NSScrollView()
    private let document = SPTorrentSettingsDocumentView()
    private let footerLine = NSBox()
    private let footerStatus = SPTorrentSettingsLabel("")
    let applyButton = NSButton(title: L("torrent.settings.apply"), target: nil, action: nil)
    private var savedMiB = 128
    private(set) var draftCacheSizeMiB = 128
    private var configured = false
    private var effectiveBytes: Int64?
    private var pending = false
    private var hasActiveSaves = false
    private var applyError: String?
    private(set) var isApplying = false
    var hasUnsavedChanges: Bool { draftCacheSizeMiB != savedMiB }
    private var needsApply: Bool {
        hasUnsavedChanges || applyError != nil
            || effectiveBytes.map { $0 != Int64(draftCacheSizeMiB) * 1_024 * 1_024 } == true
    }
    var cacheSizeControl: NSPopUpButton { document.cacheSize }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.075, alpha: 1).cgColor
        identifier = NSUserInterfaceItemIdentifier("torrent.settings.content")
        setAccessibilityRole(.group)
        setAccessibilityLabel(L("torrent.settings.title"))
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = document
        addSubview(scrollView)
        footerLine.boxType = .separator
        addSubview(footerLine)
        footerStatus.identifier = NSUserInterfaceItemIdentifier("torrent.settings.footer.status")
        addSubview(footerStatus)
        applyButton.bezelStyle = .rounded
        applyButton.font = .systemFont(ofSize: 13)
        applyButton.keyEquivalent = "\r"
        applyButton.identifier = NSUserInterfaceItemIdentifier("torrent.settings.apply")
        applyButton.setAccessibilityElement(true)
        applyButton.setAccessibilityRole(.button)
        applyButton.setAccessibilityLabel(L("torrent.settings.apply"))
        applyButton.target = self
        applyButton.action = #selector(applyRequested)
        applyButton.isEnabled = false
        addSubview(applyButton)
        document.onCacheSizeChanged = { [weak self] value in
            guard let self, !self.isApplying,
                  SPTorrentPreferences.allowedCacheSizesMiB.contains(value) else { return }
            self.draftCacheSizeMiB = value
            self.applyError = nil
            self.render()
        }
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SPTorrentSettingsContentView: no coder path") }

    func configure(selectedMiB: Int, effectiveBytes: Int64?, pending: Bool, hasActiveSaves: Bool = false) {
        let preservedDraft = configured && (hasUnsavedChanges || isApplying || applyError != nil)
        savedMiB = selectedMiB
        if !preservedDraft { draftCacheSizeMiB = selectedMiB }
        configured = true
        self.effectiveBytes = effectiveBytes
        self.pending = pending
        self.hasActiveSaves = hasActiveSaves
        render()
    }
    func discardUnappliedChanges() {
        guard !isApplying else { return }
        draftCacheSizeMiB = savedMiB
        applyError = nil
        render()
    }
    func setApplying(_ applying: Bool) {
        isApplying = applying
        if applying { applyError = nil }
        render()
    }
    func setApplyError(_ message: String?) { applyError = message; render() }
    private func render() {
        document.configure(draftMiB: draftCacheSizeMiB, savedMiB: savedMiB,
                           effectiveBytes: effectiveBytes, pending: pending && !isApplying,
                           dirty: hasUnsavedChanges)
        document.cacheSize.isEnabled = !isApplying
        applyButton.isEnabled = needsApply && !isApplying && !hasActiveSaves
        if isApplying { footerStatus.stringValue = L("torrent.settings.applying") }
        else if let applyError { footerStatus.stringValue = applyError }
        else if hasActiveSaves && needsApply { footerStatus.stringValue = L("torrent.settings.applyBlockedSave") }
        else if hasUnsavedChanges { footerStatus.stringValue = L("torrent.settings.unsaved") }
        else { footerStatus.stringValue = "" }
        footerStatus.toolTip = footerStatus.stringValue
        footerStatus.isHidden = footerStatus.stringValue.isEmpty
        applyButton.setAccessibilityHelp(footerStatus.stringValue.isEmpty ? L("torrent.settings.restartHelp") : footerStatus.stringValue)
        needsLayout = true
    }
    @objc private func applyRequested() {
        guard applyButton.isEnabled,
              SPTorrentPreferences.allowedCacheSizesMiB.contains(draftCacheSizeMiB) else { return }
        onApply?(draftCacheSizeMiB)
    }
    private var buttonWidth: CGFloat { min(200, max(96, applyButton.intrinsicContentSize.width)) }
    private func footerHeight(for width: CGFloat) -> CGFloat {
        guard !footerStatus.isHidden else { return 64 }
        let available = max(1, width - 48 - buttonWidth - 16)
        let measure = footerStatus.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: available, height: 10_000)).height ?? 18
        return max(64, ceil(measure) + 24)
    }
    func preferredHeight(for width: CGFloat) -> CGFloat {
        document.preferredHeight(for: width) + footerHeight(for: width)
    }
    override func layout() {
        super.layout()
        let height = min(bounds.height, footerHeight(for: bounds.width))
        let top = max(0, bounds.height - height)
        scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: top)
        footerLine.frame = NSRect(x: 0, y: top, width: bounds.width, height: 1)
        applyButton.frame = NSRect(x: bounds.width - 24 - buttonWidth, y: top + (height - 30) / 2,
                                   width: buttonWidth, height: 30)
        footerStatus.frame = NSRect(x: 24, y: top + 12,
                                    width: max(0, applyButton.frame.minX - 40), height: max(0, height - 24))
        let width = scrollView.contentSize.width
        document.frame = NSRect(x: 0, y: 0, width: width,
                                height: max(scrollView.contentSize.height, document.preferredHeight(for: width)))
        document.needsLayout = true
    }
}

@MainActor
private final class SPTorrentSettingsDocumentView: NSView {
    var onCacheSizeChanged: ((Int) -> Void)?
    private let cacheLabel = SPTorrentSettingsLabel(L("torrent.settings.cacheSize"), size: 14, secondary: false)
    let cacheSize = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cacheHelp = SPTorrentSettingsLabel(L("torrent.settings.cacheHelp"))
    private let restartHelp = SPTorrentSettingsLabel(L("torrent.settings.restartHelp"))
    private let currentStatus = SPTorrentSettingsLabel("", size: 13, secondary: false)
    private let pendingStatus = SPTorrentSettingsLabel("")
    private let memoryBudget = SPTorrentSettingsLabel("")
    private let lifecycle = SPTorrentSettingsLabel(L("torrent.settings.lifecycle"))
    private let firstSeparator = NSBox()
    private let secondSeparator = NSBox()
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        cacheLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        cacheSize.font = .systemFont(ofSize: 13)
        cacheSize.identifier = NSUserInterfaceItemIdentifier("torrent.settings.cacheSize")
        cacheSize.setAccessibilityElement(true)
        cacheSize.setAccessibilityRole(.popUpButton)
        cacheSize.setAccessibilityLabel(L("torrent.settings.cacheSize"))
        cacheSize.setAccessibilityHelp(L("torrent.settings.cacheHelp"))
        cacheSize.target = self
        cacheSize.action = #selector(cacheSizeSelected)
        for value in SPTorrentPreferences.allowedCacheSizesMiB {
            cacheSize.addItem(withTitle: Self.memoryText(Int64(value) * 1_024 * 1_024))
            cacheSize.lastItem?.tag = value
        }
        for (label, identifier) in [(cacheLabel, "cacheSize.label"), (cacheHelp, "description"), (restartHelp, "restartHelp"),
                                    (currentStatus, "status.current"), (pendingStatus, "status.pending"),
                                    (memoryBudget, "memoryBudget"), (lifecycle, "policy")] {
            label.identifier = NSUserInterfaceItemIdentifier("torrent.settings." + identifier)
            addSubview(label)
        }
        addSubview(cacheSize)
        for separator in [firstSeparator, secondSeparator] {
            separator.boxType = .separator
            addSubview(separator)
        }
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SPTorrentSettingsDocumentView: no coder path") }

    private static func memoryText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }
    func configure(draftMiB: Int, savedMiB: Int, effectiveBytes: Int64?, pending: Bool, dirty: Bool) {
        cacheSize.selectItem(withTag: draftMiB)
        let saved = Self.memoryText(Int64(savedMiB) * 1_024 * 1_024)
        if let effectiveBytes {
            currentStatus.stringValue = L("torrent.settings.currentFmt", Self.memoryText(effectiveBytes))
        } else {
            currentStatus.stringValue = L("torrent.settings.idleFmt", saved)
        }
        pendingStatus.stringValue = pending && effectiveBytes != nil ? L("torrent.settings.pendingFmt", saved) : ""
        pendingStatus.isHidden = pendingStatus.stringValue.isEmpty
        let total = Int64(draftMiB) * 1_024 * 1_024 * Int64(SPTorrentServer.maximumActiveTorrents)
        memoryBudget.stringValue = dirty
            ? L("torrent.settings.draftBudgetFmt", Self.memoryText(total))
            : L("torrent.settings.memoryBudgetFmt", Self.memoryText(total))
        for label in [currentStatus, pendingStatus, memoryBudget] { label.toolTip = label.stringValue }
        needsLayout = true
    }
    @objc private func cacheSizeSelected() {
        guard let value = cacheSize.selectedItem?.tag,
              SPTorrentPreferences.allowedCacheSizesMiB.contains(value) else { return }
        onCacheSizeChanged?(value)
    }
    private func textHeight(_ label: NSTextField, width: CGFloat) -> CGFloat {
        guard !label.stringValue.isEmpty else { return 0 }
        let bounds = NSRect(x: 0, y: 0, width: max(1, width), height: 10_000)
        return max(18, ceil(label.cell?.cellSize(forBounds: bounds).height ?? 18))
    }
    private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        let padding: CGFloat = 24
        let textWidth = max(1, width - padding * 2)
        let popupWidth = min(150, textWidth * 0.40)
        let labelWidth = max(1, textWidth - popupWidth - 16)
        let rowHeight = max(28, textHeight(cacheLabel, width: labelWidth))
        var y = padding
        if apply {
            cacheLabel.frame = NSRect(x: padding, y: y + (rowHeight - textHeight(cacheLabel, width: labelWidth)) / 2,
                                      width: labelWidth, height: textHeight(cacheLabel, width: labelWidth))
            cacheSize.frame = NSRect(x: width - padding - popupWidth, y: y + (rowHeight - 28) / 2,
                                     width: popupWidth, height: 28)
        }
        y += rowHeight + 12
        func place(_ label: NSTextField, gap: CGFloat = 0) {
            let height = textHeight(label, width: textWidth)
            if apply { label.frame = NSRect(x: padding, y: y, width: textWidth, height: height) }
            y += height + gap
        }
        place(cacheHelp, gap: 12)
        place(restartHelp, gap: 20)
        if apply { firstSeparator.frame = NSRect(x: padding, y: y, width: textWidth, height: 1) }
        y += 17
        place(currentStatus)
        if !pendingStatus.isHidden { y += 6; place(pendingStatus) }
        else if apply { pendingStatus.frame = NSRect(x: padding, y: y, width: textWidth, height: 0) }
        y += 16
        place(memoryBudget, gap: 20)
        if apply { secondSeparator.frame = NSRect(x: padding, y: y, width: textWidth, height: 1) }
        y += 17
        place(lifecycle)
        return y + padding
    }
    func preferredHeight(for width: CGFloat) -> CGFloat { arrange(width: width, apply: false) }
    override func layout() { super.layout(); _ = arrange(width: bounds.width, apply: true) }
}

/// A retained native, nonmodal settings window. Reading the server's cache
/// snapshot never launches a worker or constructs a playback Core.
@MainActor
final class SPTorrentSettingsWindowController: NSWindowController {
    static let shared = SPTorrentSettingsWindowController()
    var onApply: (@MainActor (Int) async throws -> Void)?
    let settingsContentView: SPTorrentSettingsContentView
    private var presented = false
    private var applyTask: Task<Void, Never>?
    private var closedDuringApply = false

    init() {
        let content = SPTorrentSettingsContentView(frame: NSRect(x: 0, y: 0, width: 540, height: 460))
        settingsContentView = content
        let window = NSWindow(contentRect: content.frame,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = L("torrent.settings.title")
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 440, height: 300)
        window.contentView = content
        content.onApply = { [weak self] value in self?.applyRequested(value) }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(settingsChanged(_:)),
                           name: SPTorrentPreferences.changedNotification, object: nil)
        center.addObserver(self, selector: #selector(settingsChanged(_:)),
                           name: SPTorrentServer.cacheConfigurationDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(settingsChanged(_:)),
                           name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(self, selector: #selector(settingsWillClose(_:)),
                           name: NSWindow.willCloseNotification, object: window)
        refreshSettings()
        window.initialFirstResponder = content.cacheSizeControl
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SPTorrentSettingsWindowController: no coder path") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func showSettings() {
        refreshSettings()
        closedDuringApply = false
        guard let window else { return }
        if !presented {
            let maximumHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
            let height = min(settingsContentView.preferredHeight(for: 540), max(300, maximumHeight - 96))
            window.setContentSize(NSSize(width: 540, height: height))
            window.center()
            presented = true
        }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    func refreshSettings() {
        let server = SPTorrentServer.shared
        settingsContentView.configure(selectedMiB: SPTorrentPreferences.cacheSizeMiB,
                                      effectiveBytes: server.effectiveCacheSizeBytes,
                                      pending: server.hasPendingCacheChange,
                                      hasActiveSaves: server.activeDownloadCount > 0)
    }
    private func applyRequested(_ value: Int) {
        guard applyTask == nil, SPTorrentPreferences.allowedCacheSizesMiB.contains(value) else { return }
        guard SPTorrentServer.shared.activeDownloadCount == 0 else { refreshSettings(); return }
        guard let onApply else {
            settingsContentView.setApplyError(L("torrent.settings.applyUnavailable"))
            return
        }
        settingsContentView.setApplying(true)
        applyTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await onApply(value)
                self.refreshSettings()
                self.settingsContentView.setApplying(false)
                self.settingsContentView.discardUnappliedChanges()
            } catch {
                self.refreshSettings()
                self.settingsContentView.setApplying(false)
                self.settingsContentView.setApplyError(L("torrent.settings.applyFailedFmt", error.localizedDescription))
            }
            self.applyTask = nil
            if self.closedDuringApply { self.settingsContentView.discardUnappliedChanges() }
        }
    }
    @objc private func settingsChanged(_ notification: Notification) { refreshSettings() }
    @objc private func settingsWillClose(_ notification: Notification) {
        closedDuringApply = true
        refreshSettings()
        settingsContentView.discardUnappliedChanges()
    }
}

import AppKit

/// Decoder-independent presentation of real torrent activity. Progress is
/// optional because metadata discovery and playback buffering are not a file
/// download percentage.
struct SPTorrentPlaylistPresentation: Equatable {
    var status: String
    var details: String? = nil
    var downloadProgress: Double? = nil
    var isSaving = false
    var canSave = false
    var isResolving = false
    var pauseBufferAction: String? = nil
    var pauseBufferEnabled = true
}

private final class SPTorrentFlippedView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

@MainActor private func SPTorrentLabel(_ text: String, size: CGFloat = 13,
                                     secondary: Bool = false) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: size)
    label.textColor = secondary ? NSColor(white: 0.67, alpha: 1) : .white
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 0
    return label
}

/// The sheet accepts a magnet URI, then delegates all torrent/hash validation
/// and networking to its owner. It never follows arbitrary pasted URLs.
@MainActor
final class SPTorrentMagnetSheet: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    var onOpen: ((String) -> Void)?
    private let input = NSTextField()
    private let errorLabel = SPTorrentLabel("", size: 12, secondary: true)
    private let openButton = NSButton()
    private let cancelButton = NSButton()
    private var submitted = false

    init() {
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 214),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: sheet)
        sheet.title = L("torrent.openMagnet")
        sheet.appearance = NSAppearance(named: .darkAqua)
        sheet.isReleasedWhenClosed = false
        sheet.delegate = self
        let content = SPTorrentFlippedView(frame: NSRect(x: 0, y: 0, width: 520, height: 214))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0.075, alpha: 1).cgColor
        sheet.contentView = content
        let title = SPTorrentLabel(L("torrent.openMagnet"), size: 17)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.frame = NSRect(x: 22, y: 20, width: 476, height: 24)
        content.addSubview(title)
        let hint = SPTorrentLabel(L("torrent.magnetHint"), size: 12, secondary: true)
        hint.frame = NSRect(x: 22, y: 51, width: 476, height: 30)
        content.addSubview(hint)
        input.font = .systemFont(ofSize: 13)
        input.placeholderString = "magnet:?xt=urn:btih:…"
        input.usesSingleLineMode = true
        input.lineBreakMode = .byTruncatingMiddle
        input.delegate = self
        input.identifier = NSUserInterfaceItemIdentifier("torrent.magnet.input")
        input.setAccessibilityLabel(L("torrent.magnetLink"))
        input.frame = NSRect(x: 22, y: 87, width: 476, height: 27)
        content.addSubview(input)
        errorLabel.identifier = NSUserInterfaceItemIdentifier("torrent.magnet.error")
        errorLabel.frame = NSRect(x: 22, y: 121, width: 476, height: 30)
        content.addSubview(errorLabel)
        for (button, text, name, action) in [
            (cancelButton, L("torrent.cancel"), "torrent.magnet.cancel", #selector(cancel)),
            (openButton, L("torrent.open"), "torrent.magnet.open", #selector(openMagnet))] {
            button.title = text
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 13)
            button.target = self
            button.action = action
            button.identifier = NSUserInterfaceItemIdentifier(name)
            button.setAccessibilityLabel(text)
            content.addSubview(button)
        }
        cancelButton.frame = NSRect(x: 294, y: 164, width: 96, height: 30)
        cancelButton.keyEquivalent = "\u{1b}"
        openButton.frame = NSRect(x: 398, y: 164, width: 100, height: 30)
        openButton.keyEquivalent = "\r"
        updateValidation()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SPTorrentMagnetSheet: no coder path") }

    static func isValidMagnet(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let components = URLComponents(string: value),
              components.scheme?.lowercased() == "magnet" else { return false }
        return components.queryItems?.contains(where: {
            $0.name.lowercased() == "xt" && !($0.value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }) == true
    }
    func present(over parent: NSWindow) {
        guard let window, window.sheetParent == nil else { return }
        submitted = false
        input.stringValue = ""
        updateValidation()
        parent.beginSheet(window)
        window.makeFirstResponder(input)
    }
    func dismiss() {
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) }
        window.orderOut(nil)
    }
    func controlTextDidChange(_ obj: Notification) { updateValidation() }
    private func updateValidation() {
        let empty = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let valid = Self.isValidMagnet(input.stringValue)
        openButton.isEnabled = valid && !submitted
        errorLabel.stringValue = empty || valid ? "" : L("torrent.invalidMagnet")
        input.setAccessibilityHelp(errorLabel.stringValue.isEmpty ? nil : errorLabel.stringValue)
    }
    @objc private func openMagnet() {
        guard !submitted, Self.isValidMagnet(input.stringValue) else { updateValidation(); return }
        let magnet = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        submitted = true
        openButton.isEnabled = false
        dismiss()
        onOpen?(magnet)
    }
    @objc private func cancel() { dismiss() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(); return false }
}

/// Small pending-metadata overlay with an explicit cancel action. Its text is
/// supplied by the torrent owner and never simulates metadata or progress.
@MainActor
final class SPTorrentLoadingView: NSView {
    var onCancel: (() -> Void)?
    var preferredMenuSize: NSSize { NSSize(width: 320, height: 152) }
    private let spinner = NSProgressIndicator()
    private let statusLabel = SPTorrentLabel("", size: 14)
    private let detailLabel = SPTorrentLabel("", size: 11, secondary: true)
    private let cancelButton = NSButton()
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.055, alpha: 0.94).cgColor
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        identifier = NSUserInterfaceItemIdentifier("torrent.loading")
        setAccessibilityRole(.group)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
        statusLabel.alignment = .center
        statusLabel.identifier = NSUserInterfaceItemIdentifier("torrent.loading.status")
        detailLabel.alignment = .center
        detailLabel.identifier = NSUserInterfaceItemIdentifier("torrent.loading.details")
        addSubview(statusLabel)
        addSubview(detailLabel)
        cancelButton.title = L("torrent.cancel")
        cancelButton.isBordered = false
        cancelButton.font = .systemFont(ofSize: 12)
        cancelButton.contentTintColor = .white
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.identifier = NSUserInterfaceItemIdentifier("torrent.loading.cancel")
        cancelButton.setAccessibilityLabel(L("torrent.cancel"))
        addSubview(cancelButton)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SPTorrentLoadingView: no coder path") }
    func setStatus(_ status: String, detail: String? = nil) {
        statusLabel.stringValue = status
        detailLabel.stringValue = detail ?? ""
        detailLabel.isHidden = detailLabel.stringValue.isEmpty
        setAccessibilityLabel(status)
        setAccessibilityHelp(detail)
        needsLayout = true
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
    }
    override func layout() {
        spinner.frame = NSRect(x: bounds.midX - 8, y: 17, width: 16, height: 16)
        statusLabel.frame = NSRect(x: 20, y: 43, width: max(0, bounds.width - 40), height: 36)
        detailLabel.frame = NSRect(x: 20, y: 81, width: max(0, bounds.width - 40), height: 29)
        cancelButton.frame = NSRect(x: bounds.midX - 60, y: max(0, bounds.height - 37), width: 120, height: 26)
    }
    @objc private func cancel() { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
        else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

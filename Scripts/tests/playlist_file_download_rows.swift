import AppKit
import Darwin

// Only external catalogue/localization inputs are fixture definitions. The
// production playlist, file presentation and footer views run in native AppKit.
struct SPPlaylistEntry: Equatable, Sendable {
    let url: URL
    let relativePath: String
    let displayName: String
    let isGrowing: Bool
}
@MainActor private var SPFileRowCaptureStrings: [String: String]?
@MainActor func L(_ key: String, _ arguments: CVarArg...) -> String {
    if let strings = SPFileRowCaptureStrings {
        return String(format: strings[key] ?? key, locale: Locale(identifier: "ru_RU"), arguments: arguments)
    }
    if key == "torrent.fileSaveProgress" {
        return String(format: "%@ · %@ / %@", arguments: arguments)
    }
    if key == "playlist.items", let first = arguments.first { return "\(first) files" }
    if key == "playlist.position", arguments.count == 2 { return "\(arguments[0]) of \(arguments[1])" }
    return key
}

@main struct SPPlaylistFileDownloadRowChecks {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 760),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSView(frame: window.contentLayoutRect)
        window.contentView = host
        let panel = SPPlaylistView(frame: NSRect(x: 0, y: 0, width: 360, height: 700))
        host.addSubview(panel)
        var checks = 0
        var failures = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            checks += 1
            if !condition() { failures += 1; print("FAIL: \(name)") }
        }
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        guard let tree = descendants(panel).first(where: { $0 is NSOutlineView }) as? NSOutlineView,
              let scroll = tree.enclosingScrollView else { exit(2) }
        let root = URL(fileURLWithPath: "/Fixture/Show", isDirectory: true)
        let entries = (1...9).map { number in
            let name = String(format: "Episode %02d.mkv", number)
            return SPPlaylistEntry(url: root.appendingPathComponent(name), relativePath: name,
                displayName: name, isGrowing: false)
        }
        func configure(root next: URL = root, current: URL? = entries[0].url) {
            panel.configure(root: next, entries: entries, currentURL: current,
                autoAdvance: true, isRefreshing: false, error: nil)
            panel.layoutSubtreeIfNeeded()
        }
        var selected: [URL] = []
        var saved: [URL] = []
        var cancelled: [URL] = []
        var revealed: [URL] = []
        panel.onSelect = { selected.append($0) }
        panel.onSaveTorrentEntry = { saved.append($0) }
        panel.onCancelTorrentEntrySave = { cancelled.append($0) }
        panel.onRevealTorrentEntrySave = { revealed.append($0) }
        configure()
        func cell(_ index: Int) -> NSView? {
            // Expanded root is row0; the nine media leaves follow it.
            tree.view(atColumn: 0, row: index + 1, makeIfNecessary: true)
        }
        func action(_ index: Int) -> NSButton? {
            cell(index).flatMap { descendants($0).first { $0.identifier?.rawValue == "torrent.playlist.file.action" } as? NSButton }
        }
        func status(_ index: Int) -> NSTextField? {
            cell(index).flatMap { descendants($0).first { $0.identifier?.rawValue == "torrent.playlist.file.status" } as? NSTextField }
        }
        func progress(_ index: Int) -> NSView? {
            cell(index).flatMap { descendants($0).first { $0.identifier?.rawValue == "torrent.playlist.file.progress" } }
        }
        check(tree.numberOfRows == 10, "real outline has folder and nine files")
        check(action(0)?.isHidden == true, "local playlist has no download controls")
        panel.setTorrentFileDownloads([:], sourceRoot: root)
        panel.layoutSubtreeIfNeeded()
        check(action(0)?.isHidden == false, "current torrent item offers save")
        check(action(1)?.isHidden == false, "unplayed torrent item offers save")
        check(action(1)?.isEnabled == true, "unplayed item save action enabled")
        let initialSelection = tree.selectedRow
        action(1)?.performClick(nil)
        check(saved == [entries[1].url], "save callback resolves exact unplayed file URL")
        check(selected.isEmpty, "download action never opens media")
        check(tree.selectedRow == initialSelection, "download action preserves keyboard selection")
        check(action(1)?.accessibilityLabel()?.contains("Episode 02") == true, "save action accessibility names target file")
        if let button = action(2) {
            let location = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            let timestamp = ProcessInfo.processInfo.systemUptime
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
                timestamp: timestamp, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1)!
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
                timestamp: timestamp + 0.01, windowNumber: window.windowNumber, context: nil,
                eventNumber: 2, clickCount: 1, pressure: 0)!
            NSApplication.shared.postEvent(up, atStart: true)
            // Exercise NSOutlineView's own mouse tracking path, as well as the
            // direct child-button action above. It must not activate media.
            tree.mouseDown(with: down)
            check(selected.isEmpty, "native pointer tracking over row action never activates media")
            check(tree.selectedRow == initialSelection, "native row-action tracking preserves selection")
        }

        let first = SPTorrentFileSavePresentation(phase: .saving, receivedBytes: 250, expectedBytes: 1_000)
        let second = SPTorrentFileSavePresentation(phase: .saving, receivedBytes: 750, expectedBytes: 1_000)
        panel.setTorrentFileDownloads([entries[0].url: first, entries[1].url: second], sourceRoot: root)
        panel.layoutSubtreeIfNeeded()
        check(progress(0)?.isHidden == false, "current save displays its progress rail")
        check(progress(1)?.isHidden == false, "second save displays independent progress rail")
        check((progress(0)?.accessibilityValue() as? Double) == 0.25, "first progress exposes actual fraction")
        check((progress(1)?.accessibilityValue() as? Double) == 0.75, "second progress exposes independent actual fraction")
        for index in 0...1 {
            if let rowCell = cell(index), let rail = progress(index) {
                check(rowCell.bounds.contains(rail.frame), "visible progress rail fits actual cell bounds, row \(index)")
                let rowRect = tree.rect(ofRow: index + 1)
                check(rowCell.frame.height >= rail.frame.maxY && rowRect.height >= rail.frame.maxY,
                    "visible progress rail fits actual cell and outline row heights, row \(index)")
                if let rowView = tree.rowView(atRow: index + 1, makeIfNecessary: false) {
                    check(rowView.bounds.contains(rail.convert(rail.bounds, to: rowView)),
                        "visible progress rail fits actual native row view bounds, row \(index)")
                } else { check(false, "actual native row view exists, row \(index)") }
            } else { check(false, "visible progress rail exists, row \(index)") }
        }
        check(status(0)?.stringValue.contains("25") == true, "first row reports first percentage")
        check(status(1)?.stringValue.contains("75") == true, "second row reports second percentage")
        check(action(1)?.toolTip == "torrent.cancelSave", "active row offers individual cancel")
        action(1)?.performClick(nil)
        check(cancelled == [entries[1].url], "cancel resolves exact saving file")
        check(selected.isEmpty, "cancel never opens media")
        let firstCell = cell(0)
        let secondCell = cell(1)
        let beforeRows = tree.numberOfRows
        let beforeSelection = tree.selectedRow
        let beforeOrigin = scroll.contentView.bounds.origin
        panel.setTorrentFileDownloads([entries[0].url: .init(phase: .saving, receivedBytes: 300, expectedBytes: 1_000),
            entries[1].url: .init(phase: .saving, receivedBytes: 850, expectedBytes: 1_000)], sourceRoot: root)
        panel.layoutSubtreeIfNeeded()
        check(cell(0) === firstCell && cell(1) === secondCell, "progress tick updates existing native cells without reload")
        check(tree.numberOfRows == beforeRows, "progress tick preserves expanded tree")
        check(tree.selectedRow == beforeSelection, "progress tick preserves selection")
        check(scroll.contentView.bounds.origin == beforeOrigin, "progress tick preserves scroll offset")
        check((progress(0)?.accessibilityValue() as? Double) == 0.3, "existing first rail advances")
        check((progress(1)?.accessibilityValue() as? Double) == 0.85, "existing second rail advances independently")

        panel.setTorrentFileDownloads([entries[1].url: .init(phase: .cancelling, receivedBytes: 850, expectedBytes: 1_000)], sourceRoot: root)
        panel.layoutSubtreeIfNeeded()
        check(action(1)?.isEnabled == false, "pending cancellation cannot start overlapping retry")
        check(progress(1)?.isHidden == false, "pending cancellation retains last known progress")
        action(1)?.performClick(nil)
        check(cancelled.count == 1 && saved.count == 1, "pending cancel does not duplicate action")
        panel.setTorrentFileDownloads([entries[1].url: .init(phase: .saved, receivedBytes: 1_000, expectedBytes: 1_000)], sourceRoot: root)
        panel.layoutSubtreeIfNeeded()
        check(progress(1)?.isHidden == true, "completed row replaces active rail with saved status")
        check(action(1)?.toolTip == "torrent.showSavedFile", "completed file offers reveal")
        action(1)?.performClick(nil)
        check(revealed == [entries[1].url], "completed row reveals exact saved file")
        check(selected.isEmpty, "reveal never opens media")
        panel.setTorrentFileDownloads([entries[1].url: .init(phase: .failed, receivedBytes: 420, expectedBytes: 1_000,
            failureDescription: "owned fixture failure")], sourceRoot: root)
        panel.layoutSubtreeIfNeeded()
        check(status(1)?.toolTip == "owned fixture failure", "failure tooltip preserves useful per-file reason")
        check(action(1)?.toolTip == "torrent.retrySave", "failed file offers retry")
        action(1)?.performClick(nil)
        check(saved.count == 2 && saved.last == entries[1].url, "retry resolves same file without playback")
        panel.setTorrentFileDownloads([entries[1].url: .init(phase: .cancelled, receivedBytes: 420, expectedBytes: 1_000)], sourceRoot: root)
        panel.layoutSubtreeIfNeeded()
        check(status(1)?.stringValue == "torrent.fileSaveCancelled", "cancelled row has explicit status")
        check(action(1)?.isEnabled == true, "acknowledged cancellation allows retry")
        check(SPTorrentFileSavePresentation(phase: .saving, receivedBytes: -100, expectedBytes: 100).fraction == 0,
            "negative progress is clamped")
        check(SPTorrentFileSavePresentation(phase: .saving, receivedBytes: 200, expectedBytes: 100).fraction == 1,
            "overflow progress is clamped")

        // A stale action captured before a catalogue rebuild must never dispatch
        // to a new file that happens to occupy the same row position.
        let oldAction = action(1)
        let otherRoot = URL(fileURLWithPath: "/Fixture/Other", isDirectory: true)
        panel.configure(root: otherRoot, entries: [], currentURL: nil, autoAdvance: true, isRefreshing: false, error: nil)
        panel.setTorrentFileDownloads([entries[1].url: second], sourceRoot: root)
        oldAction?.performClick(nil)
        check(saved.count == 2 && cancelled.count == 1, "stale recycled-row action is rejected after source change")
        check(selected.isEmpty, "source changes and stale download actions never open media")
        configure()
        panel.setTorrentFileDownloads([entries[0].url: first], sourceRoot: otherRoot)
        panel.layoutSubtreeIfNeeded()
        check(action(0)?.isHidden == true, "wrong-source snapshot cannot expose controls or old progress")
        panel.setTorrentFileDownloads([entries[0].url: first], sourceRoot: root)
        panel.layoutSubtreeIfNeeded()
        check(action(0)?.isHidden == false && progress(0)?.isHidden == false, "current-source snapshot restores valid controls")
        panel.setTorrentFileDownloads(nil, sourceRoot: nil)
        panel.layoutSubtreeIfNeeded()
        check(action(0)?.isHidden == true && progress(0)?.isHidden == true, "clearing torrent source removes controls and progress")
        check(selected.isEmpty, "entire download lifecycle is playback-independent")

        // Recreate an offscreen cell after scrolling. Its observation comes from
        // the current snapshot rather than stale state held by a reused cell.
        panel.frame.size.height = 350
        panel.layoutSubtreeIfNeeded()
        panel.setTorrentFileDownloads([entries[8].url: second], sourceRoot: root)
        tree.scrollRowToVisible(9)
        panel.layoutSubtreeIfNeeded()
        check((progress(8)?.accessibilityValue() as? Double) == 0.75, "newly visible row receives saved snapshot")
        check(status(8)?.stringValue.contains("75") == true, "newly visible row receives matching status")

        // Production footer integration must no longer offer a global current-
        // file save/progress action; per-file download state stays in the tree.
        var presentation = SPTorrentPlaylistPresentation(status: "legacy", downloadProgress: 0.25, isSaving: true, canSave: true)
        presentation.bufferStatus = SPTorrentBufferPresentation(title: "Buffer", state: .ready,
            primaryValue: "35 seconds", secondaryValue: "128 MB", progress: 0.5,
            detailsTitle: "Details", action: .stopBuffering, actionTitle: "Stop")
        panel.setTorrentPresentation(presentation)
        panel.frame.size.height = 700
        panel.layoutSubtreeIfNeeded()
        let oldFooterAction = descendants(panel).first { $0.identifier?.rawValue == "torrent.playlist.action" }
        let oldFooterProgress = descendants(panel).first { $0.identifier?.rawValue == "torrent.playlist.progress" }
        check(oldFooterAction?.isHidden == true, "modern buffer footer hides global file-save CTA")
        check(oldFooterProgress?.isHidden == true, "modern buffer footer hides unrelated file download percentage")
        check(panel.preferredMenuSize.width == 360, "download controls preserve approved panel width")
        if let output = ProcessInfo.processInfo.environment["SP_PLAYLIST_ROW_CAPTURE_DIR"],
           let catalog = ProcessInfo.processInfo.environment["SP_PLAYLIST_ROW_CATALOG"] {
            do {
                let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: catalog))) as? [String: Any]
                let strings = json?["strings"] as? [String: [String: Any]] ?? [:]
                var localized: [String: String] = [:]
                for (key, item) in strings {
                    if let variants = item["localizations"] as? [String: [String: Any]],
                       let unit = variants["ru"]?["stringUnit"] as? [String: Any], let value = unit["value"] as? String {
                        localized[key] = value
                    }
                }
                SPFileRowCaptureStrings = localized
                let capture = SPPlaylistView(frame: NSRect(x: 0, y: 0, width: 360, height: 700))
                host.addSubview(capture)
                capture.onOpenTorrent = {}
                let captureRoot = URL(fileURLWithPath: "/Fixture/Сериал", isDirectory: true)
                let names = ["Начало", "Неожиданная встреча", "Новый путь", "Возвращение", "Развязка", "Продолжение"]
                let captureEntries = names.enumerated().map { index, name in
                    let filename = String(format: "S01E%02d — %@.mkv", index + 1, name)
                    return SPPlaylistEntry(url: captureRoot.appendingPathComponent(filename), relativePath: filename,
                        displayName: filename, isGrowing: false)
                }
                capture.configure(root: captureRoot, entries: captureEntries, currentURL: captureEntries[0].url,
                    autoAdvance: true, isRefreshing: false, error: nil)
                capture.setTorrentFileDownloads([
                    captureEntries[0].url: .init(phase: .saving, receivedBytes: 268_435_456, expectedBytes: 1_073_741_824),
                    captureEntries[1].url: .init(phase: .saving, receivedBytes: 805_306_368, expectedBytes: 1_073_741_824),
                    captureEntries[2].url: .init(phase: .saved, receivedBytes: 1_073_741_824, expectedBytes: 1_073_741_824),
                    captureEntries[3].url: .init(phase: .failed, receivedBytes: 120_000, expectedBytes: 1_073_741_824,
                        failureDescription: "Сетевая ошибка")], sourceRoot: captureRoot)
                var presentation = SPTorrentPlaylistPresentation(status: "На паузе")
                presentation.bufferStatus = SPTorrentBufferPresentation(title: "Загружено впереди", state: .paused,
                    primaryValue: "84 МБ", secondaryValue: "На паузе", progress: 84 / 477.5,
                    networkRateText: "Торрент · 2,5 МБ/с", details: "Кэш в памяти: 128 МБ из 512 МБ. Пиры: 6.",
                    detailsTitle: "Сведения о подкачке", action: .stopBuffering,
                    actionTitle: "Остановить подкачку")
                capture.setTorrentPresentation(presentation)
                let directory = URL(fileURLWithPath: output, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for (name, size) in [("playlist-downloads-360x700", NSSize(width: 360, height: 700)),
                                     ("playlist-downloads-300x560", NSSize(width: 300, height: 560))] {
                    capture.frame.size = size
                    capture.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
                    capture.displayIfNeeded()
                    if let captureTree = descendants(capture).first(where: { $0 is NSOutlineView }) as? NSOutlineView {
                        for row in 1...2 {
                            if let cell = captureTree.view(atColumn: 0, row: row, makeIfNecessary: true),
                               let rail = descendants(cell).first(where: { $0.identifier?.rawValue == "torrent.playlist.file.progress" }) {
                                print("CAPTURE GEO \(name) row\(row) rect=\(captureTree.rect(ofRow: row)) rowview=\(String(describing: captureTree.rowView(atRow: row, makeIfNecessary: false)?.frame)) cell=\(cell.frame) rail=\(rail.frame) hidden=\(rail.isHidden)")
                            }
                        }
                    }
                    guard let bitmap = capture.bitmapImageRepForCachingDisplay(in: capture.bounds) else { throw CocoaError(.fileWriteUnknown) }
                    capture.cacheDisplay(in: capture.bounds, to: bitmap)
                    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                    try data.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
                }
                print("Saved owned integrated playlist captures to \(output)")
            } catch {
                failures += 1
                print("FAIL: owned capture: \(error)")
            }
        }
        window.orderOut(nil)
        print("PASS \(checks - failures)/\(checks) actual AppKit playlist file-download row checks")
        exit(failures == 0 ? 0 : 1)
    }
}

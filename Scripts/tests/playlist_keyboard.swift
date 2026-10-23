import AppKit
import Darwin

// Presentation dependencies only; the actual production NSView/NSOutlineView
// and their AppKit responder chain are compiled into this executable.
struct SPPlaylistEntry: Equatable, Sendable {
    let url: URL
    let relativePath: String
    let displayName: String
    let isGrowing: Bool
}
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
@MainActor func L(_ key: String, _ arguments: CVarArg...) -> String { key }

@MainActor private final class SPKeyboardHost: NSView {
    var received: [UInt16] = []
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { received.append(event.keyCode) }
    override func keyUp(with event: NSEvent) {}
}

@main struct SPPlaylistKeyboardChecks {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let host = SPKeyboardHost(frame: window.contentLayoutRect)
        window.contentView = host
        let panel = SPPlaylistView(frame: NSRect(x: 0, y: 0, width: 360, height: 650))
        host.addSubview(panel)
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        guard let tree = descendants(panel).first(where: { $0 is NSOutlineView }) as? NSOutlineView else { exit(2) }
        var passed = 0
        var failures = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            if condition() { passed += 1 } else { failures += 1; print("FAIL: \(name)") }
        }
        func event(_ code: UInt16, _ characters: String = "", flags: NSEvent.ModifierFlags = [],
                   up: Bool = false, repeatKey: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: up ? .keyUp : .keyDown, location: .zero,
                             modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window.windowNumber, context: nil, characters: characters,
                             charactersIgnoringModifiers: characters, isARepeat: repeatKey, keyCode: code)!
        }
        func send(_ value: NSEvent) {
            if value.type == .keyUp { window.firstResponder?.keyUp(with: value) }
            else { window.firstResponder?.keyDown(with: value) }
        }
        let root = URL(fileURLWithPath: "/Fixture/Show", isDirectory: true)
        let entries = ["Season 1/E01 Alpha.mkv", "Season 1/E02 Beta.mkv", "Season 2/E01 Gamma.mkv"].map {
            SPPlaylistEntry(url: root.appendingPathComponent($0), relativePath: $0,
                            displayName: URL(fileURLWithPath: $0).lastPathComponent, isGrowing: false)
        }
        panel.configure(root: root, entries: entries, currentURL: entries[0].url,
                        autoAdvance: true, isRefreshing: false, error: nil)
        panel.layoutSubtreeIfNeeded()
        check(window.makeFirstResponder(panel), "initial panel keyboard focus")
        send(event(49, " "))
        #if PLAYLIST_KEYBOARD_BASELINE
        if SPPlaylistKeyboardProbe.tripped > 0 {
            print("BASELINE FAILURE: responder recursion stopped safely at depth \(SPPlaylistKeyboardProbe.maximumDepth)")
            exit(1)
        }
        print("FAIL: baseline did not reproduce the responder cycle")
        exit(2)
        #else
        check(window.firstResponder === tree, "initial unhandled key moves focus into native tree")
        check(host.received == [49], "Space without playback callback leaves tree exactly once")
        for focus in [panel, tree] as [NSView] {
            _ = window.makeFirstResponder(focus)
            host.received.removeAll()
            send(event(51, "\u{7f}"))
            check(host.received == [51], "unhandled Delete leaves responder chain once from \(type(of: focus))")
            _ = window.makeFirstResponder(focus)
            host.received.removeAll()
            send(event(40, "k", flags: [.command]))
            check(host.received.count <= 1, "modified shortcut is bounded from \(type(of: focus))")
            for (code, character) in [(UInt16(123), "\u{f702}"), (124, "\u{f703}"), (125, "\u{f701}"), (126, "\u{f700}")] {
                _ = window.makeFirstResponder(focus)
                host.received.removeAll()
                send(event(code, character))
                check(host.received.count <= 1, "native arrow is bounded from \(type(of: focus))")
            }
        }
        tree.expandItem(tree.item(atRow: 0), expandChildren: true)
        tree.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        _ = window.makeFirstResponder(tree)
        send(event(126, "\u{f700}"))
        check(tree.selectedRow == 0, "Up at first row stays at the boundary")
        send(event(125, "\u{f701}"))
        check(tree.selectedRow == 1, "Down retains native row navigation")
        tree.selectRowIndexes(IndexSet(integer: tree.numberOfRows - 1), byExtendingSelection: false)
        let lastRow = tree.selectedRow
        send(event(125, "\u{f701}"))
        check(tree.selectedRow == lastRow, "Down at last row stays at the boundary")
        tree.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let season = tree.item(atRow: 1)!
        tree.collapseItem(season)
        send(event(124, "\u{f703}"))
        check(tree.isItemExpanded(season), "Right expands selected folder")
        send(event(123, "\u{f702}"))
        check(!tree.isItemExpanded(season), "Left collapses selected folder")
        tree.expandItem(season)
        tree.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        var opened: [URL] = []
        var closed = 0
        panel.onSelect = { opened.append($0) }
        panel.onClose = { closed += 1 }
        send(event(36, "\r"))
        check(opened == [entries[0].url], "Return opens selected episode once")
        send(event(53, "\u{1b}"))
        check(closed == 1, "Escape closes tree once")
        _ = window.makeFirstResponder(panel)
        send(event(53, "\u{1b}"))
        check(closed == 2, "Escape closes initially focused panel once")
        _ = window.makeFirstResponder(tree)
        host.received.removeAll()
        send(event(6, "z"))
        check(host.received.count <= 1, "native typeahead miss is bounded")

        var down: [Bool] = []
        var up = 0
        var lost = 0
        panel.onPlaybackKeyDown = { down.append($0.isARepeat) }
        panel.onPlaybackKeyUp = { _ in up += 1 }
        panel.onPlaybackFocusLost = { lost += 1 }
        for focus in [panel, tree] as [NSView] {
            _ = window.makeFirstResponder(focus)
            let before = down.count
            send(event(49, " "))
            send(event(49, " ", repeatKey: true))
            send(event(49, " ", flags: [.shift], up: true))
            check(down.count == before + 2 && down.suffix(2) == [false, true], "Space press/repeat delegated exactly once")
            check(window.firstResponder === focus, "playback Space leaves native focus unchanged")
        }
        check(up == 2 && lost == 0, "Space release with changed modifiers is delivered once")
        _ = window.makeFirstResponder(panel)
        send(event(49, " "))
        _ = window.makeFirstResponder(tree)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        check(lost == 0, "panel-to-tree focus transition preserves an active hold")
        send(event(49, " ", up: true))
        check(up == 3, "hold started on panel releases once from tree")
        let beforeModified = down.count
        for flag: NSEvent.ModifierFlags in [.command, .option, .control, .shift] {
            send(event(49, " ", flags: flag))
        }
        check(down.count == beforeModified, "modified Space is not a playback gesture")
        _ = window.makeFirstResponder(tree)
        send(event(49, " "))
        _ = window.makeFirstResponder(host)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        check(lost == 1, "leaving tree cancels an active playback hold")
        _ = window.makeFirstResponder(tree)
        send(event(49, " ", up: true))
        check(up == 3, "release after cancellation cannot create a tap")
        send(event(49, " "))
        if let button = descendants(panel).first(where: { $0.identifier?.rawValue == "playlist.autoAdvance" }) {
            _ = window.makeFirstResponder(button)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            check(lost == 2, "focus on a panel control cancels playback hold")
        } else { check(false, "auto-advance button exists") }
        _ = window.makeFirstResponder(panel)
        send(event(49, " "))
        panel.isHidden = true
        check(lost == 3, "hiding panel cancels active hold synchronously")
        panel.isHidden = false
        _ = window.makeFirstResponder(tree)
        send(event(49, " "))
        panel.removeFromSuperview()
        check(lost == 4, "removing panel cancels active hold synchronously")
        panel.onPlaybackKeyDown = nil
        panel.onPlaybackKeyUp = nil
        host.received.removeAll()
        panel.keyDown(with: event(49, " "))
        check(true, "detached panel Space returns without a responder cycle")
        var bufferActions = 0
        panel.onTogglePauseBuffer = { bufferActions += 1 }
        for height: CGFloat in [650, 300] {
            panel.frame.size = NSSize(width: 360, height: height)
            panel.setTorrentPresentation(.init(status: "Paused", details: "Peers: 7\nCache used: 94 / 128 MB\nBuffering: 10 / 100 MB",
                canSave: true, pauseBufferAction: "Stop buffering"))
            panel.layoutSubtreeIfNeeded()
            guard let buffer = descendants(panel).first(where: { $0.identifier?.rawValue == "torrent.playlist.pauseBuffer" }) as? NSButton,
                  let save = descendants(panel).first(where: { $0.identifier?.rawValue == "torrent.playlist.action" }) as? NSButton else { exit(2) }
            check(!buffer.isHidden && buffer.isEnabled, "paused buffer action is available at \(height)pt")
            check(panel.bounds.contains(buffer.frame) && !buffer.frame.intersects(save.frame), "buffer and save controls fit separately at \(height)pt")
            let before = bufferActions
            buffer.performClick(nil)
            check(bufferActions == before + 1, "separate buffer control delivers exactly one action")
        }
        panel.setTorrentPresentation(.init(status: "Paused", pauseBufferAction: "Buffering complete", pauseBufferEnabled: false))
        if let buffer = descendants(panel).first(where: { $0.identifier?.rawValue == "torrent.playlist.pauseBuffer" }) as? NSButton {
            let before = bufferActions
            buffer.performClick(nil)
            check(!buffer.isEnabled && bufferActions == before, "completed buffer cannot start an accidental duplicate read")
            panel.setTorrentPresentation(nil)
            check(buffer.isHidden, "buffer action disappears for a non-torrent playlist")
        }
        check(!window.isVisible, "native test never orders or shares a window")
        print("\(failures == 0 ? "PASS" : "FAIL"): \(passed) native playlist keyboard checks; \(failures) failures")
        exit(failures == 0 ? 0 : 1)
        #endif
    }
}

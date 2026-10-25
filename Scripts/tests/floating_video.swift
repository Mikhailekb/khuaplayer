import AppKit

@main @MainActor
struct FloatingVideoChecks {
    static var checks = 0
    static func expect(_ value: Bool, _ message: String) {
        precondition(value, message)
        checks += 1
    }

    static func button(_ window: NSWindow, _ identifier: String) -> NSButton {
        window.contentView!.subviews.compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == identifier
        }!
    }

    static func main() {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let source = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 640, height: 360),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        source.isReleasedWhenClosed = false
        let host = source.contentView!
        let video = NSView(frame: NSRect(x: 8, y: 12, width: 620, height: 340))
        video.autoresizingMask = [.width, .height]
        video.wantsLayer = true
        let originalLayer = video.layer
        let chrome = NSView(frame: .zero)
        host.addSubview(video)
        host.addSubview(chrome)
        let originalFrame = video.frame
        let controller = SPFloatingVideoController()
        var toggles = 0, restored = 0, layouts = 0, focusLosses = 0
        controller.onTogglePlayback = { toggles += 1 }
        controller.onFocusLoss = { focusLosses += 1 }
        controller.onDidRestore = { restored += 1 }
        controller.onLayoutChange = { layouts += 1 }
        expect(!controller.isActive && controller.window == nil, "Starts without another window")
        expect(controller.present(videoView: video, aspectRatio: 16 / 9, sourceWindow: source, showWindow: false), "Existing video enters floating mode")
        let panel = controller.window!
        expect(controller.isActive && video.window === panel && video.superview !== host, "Same view and decoder surface move to the panel")
        expect(!source.isVisible && !panel.isVisible, "The test never orders either window onto the user's screen")
        expect(panel.level == .floating && panel.collectionBehavior.contains(.canJoinAllSpaces) && panel.collectionBehavior.contains(.fullScreenAuxiliary), "Floating window supports other apps and spaces")
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: source))
        expect(focusLosses == 0, "Foreign window focus loss does not end floating input")
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel))
        expect(focusLosses == 1, "Floating focus loss informs the playback input owner")
        expect(video.autoresizingMask.isEmpty, "Floating content owns video layout")
        expect(video.layer === originalLayer, "The existing rendered layer is preserved")
        expect(abs(video.bounds.width / video.bounds.height - 16 / 9) < 0.001, "Video uses its source aspect excluding controls")
        button(panel, "sp.floatingVideo.playPause").performClick(nil)
        expect(toggles == 1, "Play control calls the existing playback owner")
        controller.update(isPlaying: true)
        expect(button(panel, "sp.floatingVideo.playPause").image != nil, "Play state updates the real button image")
        let proposed = controller.windowWillResize(panel, to: NSSize(width: 480, height: 400))
        panel.setFrame(NSRect(origin: panel.frame.origin, size: proposed), display: false)
        panel.contentView?.needsLayout = true
        panel.contentView?.layoutSubtreeIfNeeded()
        expect(abs(video.bounds.width - video.bounds.height * 16 / 9) <= 1, "Resizing preserves aspect within native integral window rounding")
        expect(layouts > 0, "Owner is told to update the existing renderer's viewport")
        expect(controller.present(videoView: video, aspectRatio: 16 / 9, sourceWindow: source, showWindow: false), "Entering twice is idempotent")
        let otherVideo = NSView(frame: .zero)
        host.addSubview(otherVideo)
        expect(!controller.present(videoView: otherVideo, aspectRatio: 1, sourceWindow: source, showWindow: false), "Another source cannot silently replace an active video")
        button(panel, "sp.floatingVideo.return").performClick(nil)
        expect(!controller.isActive && controller.window == nil, "Return ends floating mode")
        expect(video.superview === host && video.window === source, "Return restores the original view hierarchy")
        expect(video.frame == originalFrame && video.autoresizingMask == [.width, .height], "Return restores layout ownership")
        expect(host.subviews.firstIndex(of: video)! < host.subviews.firstIndex(of: chrome)!, "Video returns underneath playback chrome")
        expect(restored == 1 && toggles == 1, "Returning does not pause or recreate playback")
        expect(focusLosses == 2, "Return cancels held input before panel teardown")
        controller.restore()
        expect(restored == 1 && focusLosses == 2, "Repeated teardown is harmless and sends no extra input cancellation")
        expect(controller.present(videoView: video, aspectRatio: 0, sourceWindow: source, showWindow: false), "Invalid aspect safely uses the default")
        button(controller.window!, "sp.floatingVideo.close").performClick(nil)
        expect(video.superview === host && restored == 2 && toggles == 1, "Closing returns the video without stopping playback")
        expect(focusLosses == 3, "Close control also cancels held input")
        expect(controller.present(videoView: video, aspectRatio: 1, sourceWindow: source, showWindow: false), "Floating mode can be entered again")
        let closing = controller.window!
        closing.close()
        expect(!controller.isActive && video.superview === host && restored == 3, "Real system close restores the video without recursive window closing")
        expect(video.layer === originalLayer, "Restore preserves the same rendered layer")
        expect(focusLosses == 4, "System close cancels input even while its delegate is removed")
        expect(!controller.present(videoView: NSView(), aspectRatio: 1, sourceWindow: nil, showWindow: false), "A detached view cannot lose its restoration owner")
        source.close()
        print("Floating video checks passed (\(checks) assertions; owned hidden windows only).")
    }
}

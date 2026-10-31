import AppKit

@main @MainActor
struct FloatingVideoChecks {
    static var checks = 0
    static func expect(_ value: Bool, _ message: String) {
        precondition(value, message)
        checks += 1
    }

    static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    static func find<T: NSView>(_ window: NSWindow, _ identifier: String, as type: T.Type) -> T {
        descendants(window.contentView!).first { $0.accessibilityIdentifier() == identifier }! as! T
    }
    static func button(_ window: NSWindow, _ identifier: String) -> NSButton {
        find(window, identifier, as: NSButton.self)
    }
    static func hover(_ window: NSWindow, entered: Bool) {
        let event = NSEvent.enterExitEvent(with: entered ? .mouseEntered : .mouseExited,
            location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        if entered { window.contentView!.mouseEntered(with: event) }
        else { window.contentView!.mouseExited(with: event) }
    }
    static func runLoop(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func preservesAspect(_ size: NSSize, ratio: CGFloat, backingScale: CGFloat) -> Bool {
        guard size.width.isFinite, size.height.isFinite, ratio.isFinite, backingScale.isFinite,
              size.width > 0, size.height > 0, ratio > 0, backingScale > 0 else { return false }
        // NSWindow can align its content size to physical pixels. For example,
        // 420 x 236.25 at 16:9 becomes 420 x 236 on a 1x CI display. A ratio
        // epsilon over-penalizes these small windows; compare native geometry.
        return abs(size.height - size.width / ratio) <= 1 / backingScale
    }

    static func aspectRoundingChecks() {
        expect(preservesAspect(NSSize(width: 420, height: 236.25), ratio: 16 / 9, backingScale: 1),
               "Exact 16:9 content keeps its aspect")
        expect(preservesAspect(NSSize(width: 420, height: 236), ratio: 16 / 9, backingScale: 1),
               "One-times native display rounding is accepted")
        expect(preservesAspect(NSSize(width: 420, height: 236.5), ratio: 16 / 9, backingScale: 2),
               "Retina native display rounding is accepted")
        expect(!preservesAspect(NSSize(width: 420, height: 234), ratio: 16 / 9, backingScale: 1),
               "More than a physical pixel of aspect distortion is rejected")
        expect(!preservesAspect(NSSize(width: 620, height: 340), ratio: 16 / 9, backingScale: 2),
               "An unresized source view cannot pass the floating aspect check")
        expect(!preservesAspect(.zero, ratio: 16 / 9, backingScale: 1) &&
               !preservesAspect(NSSize(width: CGFloat.nan, height: 236), ratio: 16 / 9, backingScale: 1),
               "Missing or non-finite content dimensions are rejected")
        expect(!preservesAspect(NSSize(width: 420, height: 236), ratio: 0, backingScale: 1) &&
               !preservesAspect(NSSize(width: 420, height: 236), ratio: 16 / 9, backingScale: 0),
               "Invalid aspect or backing scale is rejected")
    }
    static func render(_ window: NSWindow, path: URL) throws {
        let view = window.contentView!
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: path)
    }

    static func barWhite(_ slider: NSSlider, at fraction: Double) -> Double {
        let originalFrame = slider.frame
        slider.setFrameSize(NSSize(width: 400, height: 20))
        defer { slider.frame = originalFrame }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 20,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: 400, height: 20).fill()
        (slider.cell as! NSSliderCell).draw(withFrame: slider.bounds, in: slider)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.colorAt(x: Int(fraction * 400), y: 10)!.usingColorSpace(.deviceRGB)!.redComponent
    }

    static func sliderGeometryChecks() {
        for width: CGFloat in [60, 100, 200, 400] {
            let slider = SPFloatingVideoSlider(frame: NSRect(x: 0, y: 0, width: width, height: 20))
            slider.minValue = 0; slider.maxValue = 100
            let cell = slider.cell as! NSSliderCell
            for value: Double in [72, 0, 25, 50, 90, 100] {
                slider.doubleValue = value
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 4), pixelsHigh: 80,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)!
                NSGraphicsContext.current!.cgContext.scaleBy(x: 4, y: 4)
                NSColor.black.setFill(); slider.bounds.fill()
                // Use native drawing dispatch so AppKit publishes this frame's
                // knob geometry before the overridden bar is painted.
                cell.draw(withFrame: slider.bounds, in: slider)
                // Inspect the filled bar without the circular thumb covering
                // its endpoint; the native layout above remains unchanged.
                NSColor.black.setFill(); slider.bounds.fill()
                cell.drawBar(inside: cell.barRect(flipped: slider.isFlipped), flipped: slider.isFlipped)
                NSGraphicsContext.restoreGraphicsState()
                let knob = cell.knobRect(flipped: false)
                let center = knob.midX
                if value > 0 {
                    let before = bitmap.colorAt(x: Int((center - 2) * 4), y: 40)!.usingColorSpace(.deviceRGB)!.redComponent
                    expect(before > 0.95, "White fill reaches the native thumb centre at \(value)% / \(width)pt")
                }
                if center + 2 < width {
                    let after = bitmap.colorAt(x: Int((center + 2) * 4), y: 40)!.usingColorSpace(.deviceRGB)!.redComponent
                    expect(after < 0.45, "White fill never extends beyond the native thumb centre at \(value)% / \(width)pt")
                }
                expect(center >= knob.width / 2 && center <= width - knob.width / 2,
                       "Thumb travel keeps the native endpoint insets")
            }
        }
    }

    static func main() throws {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.prohibited)
        aspectRoundingChecks()
        sliderGeometryChecks()
        let source = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 640, height: 360),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        source.isReleasedWhenClosed = false
        let host = source.contentView!
        let video = NSView(frame: NSRect(x: 8, y: 12, width: 620, height: 340))
        video.autoresizingMask = [.width, .height]
        video.wantsLayer = true
        video.layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.19, blue: 0.23, alpha: 1).cgColor
        let originalLayer = video.layer
        let chrome = NSView(frame: .zero)
        host.addSubview(video)
        host.addSubview(chrome)
        let originalFrame = video.frame
        let controller = SPFloatingVideoController()
        var toggles = 0, restored = 0, layouts = 0, focusLosses = 0, muteToggles = 0
        var seeks: [Double] = [], volumes: [Double] = []
        controller.onTogglePlayback = { toggles += 1 }
        controller.onSeek = { seeks.append($0) }
        controller.onVolumeChange = { volumes.append($0) }
        controller.onToggleMute = { muteToggles += 1 }
        controller.onFocusLoss = { focusLosses += 1 }
        controller.onDidRestore = { restored += 1 }
        controller.onLayoutChange = { layouts += 1 }
        controller.update(isPlaying: false, position: 394, duration: 1014, volumePercent: 72, muted: false)
        controller.setBufferedRanges([0.2...0.4, 0.5...0.6, 0.8...0.9], visible: true)
        expect(!controller.isActive && controller.window == nil, "Starts without another window")
        expect(controller.present(videoView: video, aspectRatio: 16 / 9, sourceWindow: source, showWindow: false), "Existing video enters floating mode")
        let panel = controller.window!
        let content = panel.contentView!
        let controls = find(panel, "sp.floatingVideo.controls", as: NSView.self)
        let timeline = find(panel, "sp.floatingVideo.timeline", as: SPFloatingVideoSlider.self)
        let volume = find(panel, "sp.floatingVideo.volume", as: SPFloatingVideoSlider.self)
        let current = find(panel, "sp.floatingVideo.currentTime", as: NSTextField.self)
        let total = find(panel, "sp.floatingVideo.totalTime", as: NSTextField.self)
        expect(controller.isActive && video.window === panel && video.superview !== host, "Same view and decoder surface move to the panel")
        expect(!source.isVisible && !panel.isVisible, "The test never orders either window onto the user's screen")
        expect(panel.level == .floating && panel.collectionBehavior.contains(.canJoinAllSpaces) && panel.collectionBehavior.contains(.fullScreenAuxiliary), "Floating window supports other apps and spaces")
        expect(panel.acceptsMouseMovedEvents && !panel.isOpaque, "Hover tracking and rounded window composition are enabled")
        expect(content.layer?.cornerRadius == 10 && content.layer?.masksToBounds == true, "Rounded content clips the existing video and overlay together")
        expect(video.autoresizingMask.isEmpty && video.layer === originalLayer, "Floating content owns layout without replacing the rendered layer")
        expect(video.frame == content.bounds, "Video fills the entire floating window with no permanent footer")
        expect(abs(panel.contentAspectRatio.width / panel.contentAspectRatio.height - 16 / 9) < 0.000001,
               "The floating window requests the exact source aspect")
        expect(preservesAspect(video.bounds.size, ratio: 16 / 9, backingScale: panel.backingScaleFactor),
               "Video keeps its source aspect within one native pixel: video=\(video.bounds.size), content=\(content.bounds.size), frame=\(panel.frame.size), scale=\(panel.backingScaleFactor)")
        expect(controls.alphaValue == 0, "Paused video initially has no controls without hover")
        expect(barWhite(timeline, at: 0.1) > 0.95 && barWhite(timeline, at: 0.55) > 0.72 &&
               barWhite(timeline, at: 0.7) < 0.45, "PiP paints white played, gray cached and darker uncached regions")
        expect(barWhite(volume, at: 0.85) < 0.45, "The shared volume slider never inherits timeline cache coverage")
        controller.setBufferedRanges([], visible: true)
        expect(barWhite(timeline, at: 0.55) < 0.45 && controls.alphaValue == 0,
               "Cache eviction updates the hidden PiP timeline without revealing controls")
        controller.setBufferedRanges([0.2...0.4, 0.5...0.6, 0.8...0.9], visible: true)
        expect(current.stringValue == "6:34" && total.stringValue == "16:54", "Actual playback times match the provided Telegram-style example")
        expect(timeline.doubleValue == 394 && timeline.maxValue == 1014 && timeline.isEnabled, "The real seek control tracks media seconds")
        expect(!timeline.isContinuous && volume.isContinuous, "Seek commits once per completed drag while volume responds continuously")
        expect(volume.doubleValue == 72 && volume.minValue == 0 && volume.maxValue == 100, "Volume reflects the owner in percent")
        hover(panel, entered: true)
        runLoop(0.2)
        expect(controls.alphaValue == 1, "Hover reveals the controls even when paused")
        let close = button(panel, "sp.floatingVideo.close")
        let restore = button(panel, "sp.floatingVideo.return")
        let mute = button(panel, "sp.floatingVideo.mute")
        let play = button(panel, "sp.floatingVideo.playPause")
        expect(close.frame.minX < restore.frame.minX && close.frame.midY > content.bounds.midY, "Close and return are at the top left")
        expect(mute.frame.minX > content.bounds.midX && volume.frame.minX > mute.frame.minX, "Mute and volume are at the top right")
        expect(abs(play.frame.midX - content.bounds.midX) < 0.01 && abs(play.frame.midY - content.bounds.midY) < 0.01, "Play/pause is centered over the video")
        expect(timeline.frame.maxY < current.frame.midY && current.frame.midY < content.bounds.midY, "Time and seek controls overlay the bottom of the video")
        expect(content.hitTest(NSPoint(x: 110, y: content.bounds.midY)) === video, "Noninteractive overlay space passes through to the video")
        expect(content.hitTest(NSPoint(x: play.frame.midX, y: play.frame.midY)) === play, "Visible play control receives its own clicks")
        play.performClick(nil)
        expect(toggles == 1, "Play control calls the existing playback owner")
        mute.performClick(nil)
        expect(muteToggles == 1 && toggles == 1, "Mute does not pause playback")
        volume.doubleValue = 31
        volume.sendAction(volume.action, to: volume.target)
        expect(volumes == [31], "Real volume control dispatches the exact requested percent")
        timeline.doubleValue = 615
        timeline.sendAction(timeline.action, to: timeline.target)
        expect(seeks == [615] && current.stringValue == "10:15", "Seek dispatches media seconds and updates its local readout")
        controller.update(isPlaying: true, position: 616, duration: 1014, volumePercent: 31, muted: true)
        expect(timeline.doubleValue == 616 && volume.doubleValue == 31 && play.image != nil && mute.image != nil, "Owner updates refresh playback, volume and mute controls")
        runLoop(2.1)
        expect(controls.alphaValue == 1, "Controls remain visible while the pointer stays inside; there is no idle hide timer")
        hover(panel, entered: false)
        runLoop(0.2)
        expect(controls.alphaValue == 0, "Leaving the video hides the controls during playback")
        expect(content.hitTest(NSPoint(x: play.frame.midX, y: play.frame.midY)) === video, "Hidden overlay controls never intercept a video click")
        controller.update(isPlaying: false, position: 616, duration: 1014, volumePercent: 31, muted: true)
        runLoop(0.2)
        expect(controls.alphaValue == 0, "Pausing without hover does not reveal any control")
        hover(panel, entered: true)
        timeline.beginTracking()
        timeline.doubleValue = 800
        hover(panel, entered: false)
        controller.update(isPlaying: true, position: 620, duration: 1014, volumePercent: 31, muted: true)
        expect(timeline.doubleValue == 800 && controls.alphaValue == 1, "A seek drag keeps the preview and controls while outside the window")
        timeline.endTracking()
        runLoop(0.2)
        expect(controls.alphaValue == 0 && seeks == [615], "Releasing a drag outside hides controls and does not invent another seek")
        hover(panel, entered: true)
        volume.beginTracking()
        volume.doubleValue = 47
        controller.update(isPlaying: true, position: 621, duration: 1014, volumePercent: 31, muted: true)
        expect(volume.doubleValue == 47, "A metadata update cannot move the volume knob under the pointer")
        volume.endTracking()
        controller.update(isPlaying: false, position: .nan, duration: .infinity, volumePercent: .nan, muted: false)
        expect(!timeline.isEnabled && timeline.doubleValue == 0 && current.stringValue == "0:00" && total.stringValue == "0:00", "Unknown or non-finite media timing disables seeking safely")
        expect(barWhite(timeline, at: 0.55) < 0.45,
               "Unknown media timing cannot display stale cached time positions")
        expect(volume.doubleValue == 100, "Non-finite volume falls back to a finite control value")
        timeline.sendAction(timeline.action, to: timeline.target)
        expect(seeks == [615], "A disabled timeline cannot dispatch an invalid seek")
        controller.update(isPlaying: false, position: 0.2, duration: 0.5, volumePercent: 72, muted: false)
        expect(timeline.maxValue == 0.5 && timeline.doubleValue == 0.2 && timeline.isEnabled,
               "Subsecond media cannot seek beyond its actual duration")
        controller.update(isPlaying: false, position: 394, duration: 1014, volumePercent: 72, muted: false)
        if CommandLine.arguments.count == 2 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try render(panel, path: directory.appendingPathComponent("pip-hover.png"))
            hover(panel, entered: false)
            runLoop(0.2)
            try render(panel, path: directory.appendingPathComponent("pip-no-hover.png"))
        }
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: source))
        expect(focusLosses == 0, "Foreign window focus loss does not end floating input")
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel))
        expect(focusLosses == 1, "Floating focus loss informs the playback input owner")
        let proposed = controller.windowWillResize(panel, to: NSSize(width: 480, height: 400))
        panel.setFrame(NSRect(origin: panel.frame.origin, size: proposed), display: false)
        panel.contentView?.needsLayout = true
        panel.contentView?.layoutSubtreeIfNeeded()
        expect(preservesAspect(video.bounds.size, ratio: 16 / 9, backingScale: panel.backingScaleFactor),
               "Resizing preserves aspect within one native pixel: video=\(video.bounds.size), scale=\(panel.backingScaleFactor)")
        expect(video.frame == content.bounds && timeline.frame.maxX <= content.bounds.maxX, "The full video and overlay relayout after resize")
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
        expect(restored == 1 && focusLosses == 2, "Repeated teardown is harmless")
        expect(controller.present(videoView: video, aspectRatio: 0, sourceWindow: source, showWindow: false), "Invalid aspect safely uses the default")
        button(controller.window!, "sp.floatingVideo.close").performClick(nil)
        expect(video.superview === host && restored == 2 && toggles == 1, "Closing returns the video without stopping playback")
        expect(focusLosses == 3, "Close control also cancels held input")
        expect(controller.present(videoView: video, aspectRatio: 1, sourceWindow: source, showWindow: false), "Floating mode can be entered again")
        controller.window!.close()
        expect(!controller.isActive && video.superview === host && restored == 3, "Real system close restores the video without recursion")
        expect(video.layer === originalLayer && focusLosses == 4, "System close preserves the layer and cancels held input")
        expect(!controller.present(videoView: NSView(), aspectRatio: 1, sourceWindow: nil, showWindow: false), "A detached view cannot lose its restoration owner")
        source.close()
        print("Floating video checks passed (\(checks) assertions; owned hidden windows only).")
    }
}

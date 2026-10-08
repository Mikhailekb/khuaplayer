import AppKit
import UniformTypeIdentifiers

/// A window content controller that can show a one-line, self-dismissing
/// notice (welcome list or playback area) instead of a modal alert.
@MainActor
protocol SPTransientNoticePresenting: AnyObject {
    func showTransientNotice(_ text: String)
}

// ── Set as Default Player (App-menu panel, no separate settings page) ──
//
// The selected formats are associated with this app one UTI at a time through
// NSWorkspace.setDefaultApplication. Keep this list synchronized with
// CFBundleDocumentTypes in project.yml; LaunchServices only permits types that
// the app declares in Info.plist.
//
// Default selection policy: leave formats with broad built-in system support
// unchecked (MP4/MOV/M4V/3GP and MP3/M4A/AAC/WAV/AIFF). Recommend formats that
// commonly require a dedicated media player (MKV/WebM/FLV/RMVB/FLAC/OGG and
// similar). Formats already associated with this app are always selected.
// Niche production and elementary-stream formats (MXF/DV/AV1/VVC/CAVS/DNx)
// stay declared and openable but are not recommended: raw elementary streams
// have no container timeline, so duration and seeking are incomplete, and a
// one-click default should not take them over.
@MainActor
enum SPDefaultPlayer {
    struct Format: Sendable {
        let label: String        // Format names are product terms, not localized.
        let exts: [String]
        let isVideo: Bool
        let recommended: Bool    // Initial state according to the policy above.
    }

    // Keep synchronized with CFBundleDocumentTypes in project.yml.
    nonisolated static let formats: [Format] = [
        Format(label: "MKV", exts: ["mkv"], isVideo: true, recommended: true),
        Format(label: "MP4 / M4V", exts: ["mp4", "m4v"], isVideo: true, recommended: false),
        Format(label: "MOV", exts: ["mov"], isVideo: true, recommended: false),
        Format(label: "WebM", exts: ["webm"], isVideo: true, recommended: true),
        Format(label: "AVI", exts: ["avi"], isVideo: true, recommended: true),
        Format(label: "TS / M2TS", exts: ["ts", "m2ts", "mts"], isVideo: true, recommended: true),
        Format(label: "FLV", exts: ["flv"], isVideo: true, recommended: true),
        Format(label: "WMV", exts: ["wmv"], isVideo: true, recommended: true),
        Format(label: "MPG / MPEG", exts: ["mpg", "mpeg"], isVideo: true, recommended: true),
        Format(label: "3GP", exts: ["3gp"], isVideo: true, recommended: false),
        Format(label: "RM / RMVB", exts: ["rm", "rmvb"], isVideo: true, recommended: true),
        Format(label: "MXF", exts: ["mxf"], isVideo: true, recommended: false),
        Format(label: "DV", exts: ["dv"], isVideo: true, recommended: false),
        Format(label: "AV1 / OBU", exts: ["av1", "obu"], isVideo: true, recommended: false),
        Format(label: "VVC / H.266", exts: ["vvc", "h266"], isVideo: true, recommended: false),
        Format(label: "CAVS", exts: ["cavs"], isVideo: true, recommended: false),
        Format(label: "DNxHD / DNxHR", exts: ["dnxhd", "dnxhr"], isVideo: true, recommended: false),
        Format(label: "MP3", exts: ["mp3"], isVideo: false, recommended: false),
        Format(label: "M4A / AAC", exts: ["m4a", "aac"], isVideo: false, recommended: false),
        Format(label: "FLAC", exts: ["flac"], isVideo: false, recommended: true),
        Format(label: "WAV / AIFF", exts: ["wav", "aiff", "aif"], isVideo: false, recommended: false),
        Format(label: "OGG / Opus", exts: ["ogg", "opus"], isVideo: false, recommended: true),
        Format(label: "APE / WavPack / TTA", exts: ["ape", "wv", "tta"], isVideo: false, recommended: true),
        Format(label: "AC3 / DTS", exts: ["ac3", "dts"], isVideo: false, recommended: true),
        Format(label: "MKA", exts: ["mka"], isVideo: false, recommended: true),
        Format(label: "AMR", exts: ["amr"], isVideo: false, recommended: true),
    ]

    /// Resolve an extension to a UTI while anchoring its media semantics.
    /// A bare lookup for extensions such as "ts" can select an unrelated
    /// dynamic UTI; declared extensions resolve to the types imported by the
    /// app's Info.plist.
    nonisolated static func resolveType(ext: String, isVideo: Bool) -> UTType? {
        UTType(filenameExtension: ext,
               conformingTo: isVideo ? .movie : .audio)
    }

    private static func isCurrentDefault(_ format: Format) -> Bool {
        guard let type = resolveType(ext: format.exts[0], isVideo: format.isVideo),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: type)
        else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    // MARK: - Welcome-page offer

    /// Records whether the app has applied a default-format selection.
    nonisolated static let appliedDefaultsKey = "sp.defaultPlayer.applied"
    /// Representative extensions for the most recently applied selection.
    nonisolated static let appliedExtsDefaultsKey = "sp.defaultPlayer.appliedExts"
    /// Legacy video-only snapshot; read as a fallback, never written.
    nonisolated static let appliedVideoExtsDefaultsKey =
        "sp.defaultPlayer.appliedVideoExts"

    /// The stored selection, or nil when the user never completed the panel.
    nonisolated private static func appliedExtsSnapshot(
        _ defaults: UserDefaults
    ) -> [String]? {
        defaults.stringArray(forKey: appliedExtsDefaultsKey)
            ?? defaults.stringArray(forKey: appliedVideoExtsDefaultsKey)
    }
    nonisolated static let welcomeDismissedDefaultsKey =
        "sp.defaultPlayer.welcomeDismissed"
    nonisolated static let promptShownDefaultsKey = "sp.defaultPlayer.promptShown"

    static func markWelcomeDismissed() {
        UserDefaults.standard.set(true, forKey: welcomeDismissedDefaultsKey)
    }

    /// Persist the requested selection for later status checks and restoration.
    private static func recordApplied(_ picked: [Format]) {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: appliedDefaultsKey)
        defaults.set(picked.map { $0.exts[0] }, forKey: appliedExtsDefaultsKey)
    }

    /// Completion feedback shared by the panel and the first-run prompt. Full
    /// success is a transient notice in the host window: the user just chose
    /// this, an alert that only says "done" adds a click. Partial failure still
    /// needs a readable alert.
    private static func presentCompletion(ok: Int, failed: Int,
                                          over window: NSWindow?) {
        if failed == 0,
           let presenter = window?.contentViewController as? SPTransientNoticePresenting {
            presenter.showTransientNotice(L("defaultPlayer.done.message", ok))
            return
        }
        let done = NSAlert()
        done.alertStyle = failed == 0 ? .informational : .warning
        done.messageText = L("defaultPlayer.done.title")
        done.informativeText = failed == 0
            ? L("defaultPlayer.done.message", ok)
            : L("defaultPlayer.done.message", ok) + "\n"
                + L("defaultPlayer.fail.message", failed)
        done.addButton(withTitle: L("privacy.summary.ok"))
        if let window {
            done.beginSheetModal(for: window)
        } else {
            _ = done.runModal()
        }
    }

    // MARK: - First-run prompt

    /// The first-run prompt is shown at most once.
    static var shouldPresentFirstRunPrompt: Bool {
        !UserDefaults.standard.bool(forKey: promptShownDefaultsKey)
    }

    /// Present the first-run prompt and report when setup is deferred.
    static func presentFirstRunPrompt(over window: NSWindow?,
                                      onDeferred: (() -> Void)? = nil) {
        UserDefaults.standard.set(true, forKey: promptShownDefaultsKey)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L("defaultPlayer.prompt.title")
        alert.informativeText = L("defaultPlayer.prompt.message")
        alert.addButton(withTitle: L("defaultPlayer.apply"))
        alert.addButton(withTitle: L("defaultPlayer.prompt.customize"))
        alert.addButton(withTitle: L("defaultPlayer.prompt.later"))
        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn:
                recordApplied(formats)
                apply(formats: formats) { ok, failed in
                    presentCompletion(ok: ok, failed: failed, over: window)
                }
            case .alertSecondButtonReturn:
                presentDialog(over: window)
            default:
                onDeferred?()
            }
        }
        // Prefer a sheet when a visible host window is available.
        if let window, window.isVisible {
            Task { @MainActor in
                handleResponse(await alert.beginSheetModal(for: window))
            }
        } else {
            handleResponse(alert.runModal())
        }
    }

    enum WelcomeOffer: Sendable {
        case none
        case setup   // Never associated: offer initial setup.
        case restore // Applied formats were mostly taken over: offer restore.
    }

    /// How the current default handler of a video type relates to this app.
    ///
    /// LaunchServices prefers a claim that names the type (or its filename
    /// extension) over a generic public.movie claim, regardless of rank. A
    /// type that only this app names therefore resolves to this app on its
    /// own, without any user choice (for example app-private imported types,
    /// or MKV on a system with no other player that declares it). Such a
    /// binding is neither evidence that setup already happened nor a format
    /// that another app could take over.
    enum Ownership: Sendable, Equatable {
        case elsewhere    // Another app, or no app, opens the type.
        case chosen       // This app opens it although another app names it.
        case uncontested  // This app opens it because no other app names it.
    }

    /// Pure offer decision over probed ownerships; no LaunchServices access.
    /// Uncontested types are neutral: they neither mark a never-configured
    /// system as configured nor dilute the restore majority.
    nonisolated static func welcomeOffer(applied: Bool,
                                         ownerships: [Ownership]) -> WelcomeOffer {
        if applied {
            let tracked = ownerships.filter { $0 != .uncontested }
            let lost = tracked.filter { $0 == .elsewhere }.count
            return lost * 2 > tracked.count ? .restore : .none
        }
        return ownerships.contains(.chosen) ? .none : .setup
    }

    /// Whether CFBundleDocumentTypes entries name a content type directly. An
    /// entry that lists LSItemContentTypes is matched by those types only;
    /// filename extensions count only for extension-based entries.
    nonisolated static func documentTypes(_ docs: [[String: Any]],
                                          name identifier: String,
                                          extensions tags: Set<String>) -> Bool {
        docs.contains { doc in
            if let types = doc["LSItemContentTypes"] as? [String] {
                return types.contains(identifier)
            }
            let declared = doc["CFBundleTypeExtensions"] as? [String] ?? []
            return declared.contains { tags.contains($0.lowercased()) }
        }
    }

    /// Probe ownership for representative video extensions. This queries
    /// LaunchServices and may read other applications' Info.plist files, so
    /// it must run off the main thread. Registered copies are matched by
    /// bundle identifier rather than file URL.
    nonisolated static func probeOwnership(exts: [String],
                                           bundleID: String?) -> [Ownership] {
        let workspace = NSWorkspace.shared
        // Per-probe Info.plist cache. CFBundleCopyInfoDictionaryForURL does
        // not register process-wide bundle objects for other applications.
        var infoCache: [URL: [String: Any]] = [:]
        func info(_ app: URL) -> [String: Any] {
            let key = app.standardizedFileURL
            if let cached = infoCache[key] { return cached }
            let dict = CFBundleCopyInfoDictionaryForURL(key as CFURL)
                as? [String: Any] ?? [:]
            infoCache[key] = dict
            return dict
        }
        func isSelf(_ app: URL) -> Bool {
            (info(app)["CFBundleIdentifier"] as? String) == bundleID
        }
        func names(_ app: URL, _ type: UTType, _ tags: Set<String>) -> Bool {
            documentTypes(info(app)["CFBundleDocumentTypes"] as? [[String: Any]] ?? [],
                          name: type.identifier, extensions: tags)
        }
        var generic: Set<URL>?  // Applications that open public.movie itself.
        return exts.map { ext in
            guard let type = resolveType(ext: ext, isVideo: true),
                  let handler = workspace.urlForApplication(toOpen: type),
                  isSelf(handler)
            else { return .elsewhere }
            let genericApps = generic ?? Set(
                workspace.urlsForApplications(toOpen: .movie)
                    .map(\.standardizedFileURL))
            generic = genericApps
            let candidates = workspace.urlsForApplications(toOpen: type)
                .map(\.standardizedFileURL)
            // An app that opens this type but not generic movies claims the
            // type specifically; no declaration read is needed.
            if candidates.contains(where: { !genericApps.contains($0) && !isSelf($0) }) {
                return .chosen
            }
            // A generic claimant can also name the type itself (the system
            // player names AVI/MPEG/DV besides public.movie) and would then
            // win by rank unless the user chose this app.
            let tags = Set((type.tags[.filenameExtension] ?? [ext])
                .map { $0.lowercased() })
            let named = candidates.contains {
                genericApps.contains($0) && !isSelf($0) && names($0, type, tags)
            }
            return named ? .chosen : .uncontested
        }
    }

    /// Evaluate the welcome-page offer without blocking the main actor.
    /// Previously applied selections offer restoration after a majority of
    /// their contested video formats no longer resolve to this app.
    static func evaluateWelcomeOffer(
        completion: @escaping @MainActor (WelcomeOffer) -> Void
    ) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: welcomeDismissedDefaultsKey) else {
            completion(.none)
            return
        }
        let applied = defaults.bool(forKey: appliedDefaultsKey)
        // Monitor video associations; retain audio entries for restoration.
        let videoExts = Set(formats.filter(\.isVideo).map { $0.exts[0] })
        let snapshot = applied
            ? (appliedExtsSnapshot(defaults) ?? []).filter(videoExts.contains)
            : []
        if applied, snapshot.isEmpty {
            completion(.none) // Audio-only association has nothing to guard.
            return
        }
        // Never-applied systems probe the recommended video formats; applied
        // systems probe the stored selection.
        let probeExts = applied
            ? snapshot
            : formats.filter { $0.isVideo && $0.recommended }.map { $0.exts[0] }
        let bundleID = Bundle.main.bundleIdentifier
        DispatchQueue.global(qos: .utility).async {
            let ownerships = probeOwnership(exts: probeExts, bundleID: bundleID)
            let offer = welcomeOffer(applied: applied, ownerships: ownerships)
            if ProcessInfo.processInfo.environment["SP_DEBUG"] != nil {
                NSLog("[DefaultPlayer] Welcome offer: applied=%d snapshot=%d uncontested=%d result=%@",
                      applied ? 1 : 0, snapshot.count,
                      ownerships.filter { $0 == .uncontested }.count,
                      String(describing: offer))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(offer) }
            }
        }
    }

    /// Present the format-selection panel from the App menu or the welcome
    /// link. `onApplied` fires after the user confirms a non-empty selection.
    static func presentDialog(over window: NSWindow?,
                              onApplied: (() -> Void)? = nil) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L("defaultPlayer.title")
        alert.informativeText = L("defaultPlayer.message")
        alert.addButton(withTitle: L("defaultPlayer.apply"))
        alert.addButton(withTitle: L("defaultPlayer.cancel"))

        var checkboxes: [(Format, NSButton)] = []
        // Prefer the stored selection; also retain current app associations.
        let savedExts = appliedExtsSnapshot(UserDefaults.standard).map(Set.init)
        func column(video: Bool, header: String) -> NSStackView {
            let col = NSStackView()
            col.orientation = .vertical
            col.alignment = .leading
            col.spacing = 4
            let title = NSTextField(labelWithString: header)
            title.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            col.addArrangedSubview(title)
            for f in formats where f.isVideo == video {
                let box = NSButton(checkboxWithTitle: f.label, target: nil, action: nil)
                let preselected = savedExts?.contains(f.exts[0]) ?? f.recommended
                box.state = (preselected || isCurrentDefault(f)) ? .on : .off
                col.addArrangedSubview(box)
                checkboxes.append((f, box))
            }
            return col
        }
        let columns = NSStackView(views: [
            column(video: true, header: L("defaultPlayer.video")),
            column(video: false, header: L("defaultPlayer.audio")),
        ])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 24

        // Preset buttons apply either the recommended set or every format.
        final class SelectionRelay: NSObject {
            var boxes: [NSButton] = []
            var recommendedStates: [Bool] = []
            @objc func selectRecommended(_ sender: Any?) {
                for (box, on) in zip(boxes, recommendedStates) {
                    box.state = on ? .on : .off
                }
            }
            @objc func selectAll(_ sender: Any?) {
                for box in boxes { box.state = .on }
            }
        }
        let relay = SelectionRelay()
        relay.boxes = checkboxes.map(\.1)
        relay.recommendedStates = checkboxes.map(\.0.recommended)
        func presetButton(_ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: relay, action: action)
            b.controlSize = .small
            b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            return b
        }
        let hint = NSTextField(labelWithString: L("defaultPlayer.recommendedHint"))
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        let presetRow = NSStackView(views: [
            presetButton(L("defaultPlayer.recommended"),
                         #selector(SelectionRelay.selectRecommended(_:))),
            presetButton(L("defaultPlayer.selectAll"),
                         #selector(SelectionRelay.selectAll(_:))),
            hint,
        ])
        presetRow.orientation = .horizontal
        presetRow.alignment = .centerY
        presetRow.spacing = 8

        let root = NSStackView(views: [presetRow, columns])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.frame = NSRect(x: 0, y: 0, width: 420,
                            height: root.fittingSize.height)
        alert.accessoryView = root

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            withExtendedLifetime(relay) {}
            guard response == .alertFirstButtonReturn else { return }
            let picked = checkboxes.filter { $0.1.state == .on }.map(\.0)
            guard !picked.isEmpty else { return }
            recordApplied(picked)
            onApplied?()
            apply(formats: picked) { ok, failed in
                presentCompletion(ok: ok, failed: failed, over: window)
            }
        }

        if let window, window.isVisible {
            Task { @MainActor in
                handleResponse(await alert.beginSheetModal(for: window))
            }
        } else {
            handleResponse(withExtendedLifetime(relay) { alert.runModal() })
        }
    }

    /// Associate deduplicated UTIs sequentially and complete on the main actor.
    /// Some types require asynchronous user consent; serial submission avoids
    /// stacking multiple system consent prompts.
    static func apply(formats picked: [Format],
                      completion: @escaping @MainActor (Int, Int) -> Void) {
        var types: [String: UTType] = [:]
        var unresolved = 0
        for f in picked {
            for ext in f.exts {
                if let t = resolveType(ext: ext, isVideo: f.isVideo) {
                    types[t.identifier] = t
                } else {
                    unresolved += 1
                }
            }
        }
        let pending = types.sorted { $0.key < $1.key }.map(\.value)
        let appURL = Bundle.main.bundleURL
        func applyNext(index: Int, ok: Int, failed: Int) {
            guard index < pending.count else {
                completion(ok, failed)
                return
            }
            let type = pending[index]
            let identifier = type.identifier
            NSWorkspace.shared.setDefaultApplication(
                at: appURL, toOpen: type
            ) { error in
                let errorDescription = error?.localizedDescription
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let errorDescription {
                            NSLog("[DefaultPlayer] %@ failed: %@",
                                  identifier, errorDescription)
                            applyNext(index: index + 1,
                                      ok: ok,
                                      failed: failed + 1)
                        } else {
                            applyNext(index: index + 1,
                                      ok: ok + 1,
                                      failed: failed)
                        }
                    }
                }
            }
        }
        applyNext(index: 0, ok: 0, failed: unresolved)
    }

#if !SP_APP_STORE
    /// Headless test hook (`SP_SETDEFAULT_TEST=ext1,ext2`) for validating UTI
    /// resolution and LaunchServices association without presenting the panel.
    static func handleTestHook() {
        guard let spec = ProcessInfo.processInfo
            .environment["SP_SETDEFAULT_TEST"] else { return }
        let exts = spec.split(separator: ",").map(String.init)
        let picked = formats.filter { !Set($0.exts).isDisjoint(with: exts) }
        NSLog("[DefaultPlayer] test hook: exts=%@ picked=%d", spec, picked.count)
        apply(formats: picked) { ok, failed in
            NSLog("[DefaultPlayer] test hook finished: ok=%d failed=%d", ok, failed)
        }
    }
#endif
}

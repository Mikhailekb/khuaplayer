import AppKit
import UniformTypeIdentifiers

// One app-owned caption execution slot with a FIFO queue. Tasks outlive their
// presenting windows; reopening the same media reattaches its display. Stop
// discards unfinished work. Construction is deferred until the first request.
@available(macOS 26.0, *)
@MainActor
final class CaptionTaskCenter {
    static let shared = CaptionTaskCenter()

    enum Prepared {
        case ready(CaptionEngine.Configuration, note: String? = nil)
        case notNeeded(String)
    }

    /// Enqueue configuration only; detection, file reading and model preparation
    /// all belong to the same execution slot.
    @MainActor final class Task {
        let mediaURL: URL
        let mediaName: String
        let mediaKey: String
        fileprivate(set) var config: CaptionEngine.Configuration?
        fileprivate(set) var languageLabel: String
        fileprivate(set) var engine: CaptionEngine?
        fileprivate(set) var progress = 0.0
        fileprivate(set) var progressText = ""
        fileprivate(set) var phase: CaptionEngine.Phase = .preparing
        fileprivate(set) var eta: Double?
        fileprivate(set) var isFinished = false
        fileprivate(set) var isStopping = false
        fileprivate(set) var isWaitingForPlayback = false
        fileprivate(set) var error: Error?
        fileprivate(set) var hasStarted = false
        fileprivate(set) var completionMessage: String?
        /// Set when Stop Previous displaced this task, so the stopped capsule can name the successor.
        fileprivate(set) var supersededByName: String?
        var note: String?
        var preparationMessage: String?
        weak var presentationWindow: NSWindow?
        fileprivate var prepare: (@MainActor (Task) async throws -> Prepared)?
        fileprivate var preparationTask: _Concurrency.Task<Void, Never>?
        fileprivate var listeners: [ObjectIdentifier: Listener] = [:]
        fileprivate var resultEvents: [CaptionRenderEvent] = []
        fileprivate var resultSidecarURL: URL?
        fileprivate var resultTranscriptURL: URL?
        fileprivate var resultSourceTag: String?
        fileprivate var resultTargetTag: String?
        fileprivate var pendingSaves: [PendingSave] = []
        fileprivate(set) var isRetryingSave = false

        init(mediaURL: URL, languageLabel: String,
             prepare: @escaping @MainActor (Task) async throws -> Prepared) {
            self.mediaURL = mediaURL
            self.mediaName = mediaURL.lastPathComponent
            self.mediaKey = CaptionTaskCenter.key(for: mediaURL)
            self.languageLabel = languageLabel
            self.prepare = prepare
        }

        init(config: CaptionEngine.Configuration, mediaName: String, languageLabel: String) {
            self.mediaURL = config.mediaURL
            self.config = config
            self.mediaName = mediaName
            self.mediaKey = CaptionTaskCenter.key(for: config.mediaURL)
            self.languageLabel = languageLabel
        }

        /// Preparation and cancellation cleanup hold the slot until execution really finishes.
        var isRunning: Bool { hasStarted && !isFinished }
        var isSaving: Bool { isRetryingSave || (!isFinished && (engine?.isSaving ?? false)) }
        var canStop: Bool { !isFinished && !isStopping && !isSaving }
        var sidecarURL: URL? { engine?.sidecarURL ?? resultSidecarURL }
        var transcriptURL: URL? { engine?.transcriptURL ?? resultTranscriptURL }
        var targetTag: String? { config?.targetLanguage.map { CaptionLanguageTags.fileTag(forTargetLanguage: $0.minimalIdentifier) } ?? resultTargetTag }
        var committedEvents: [CaptionRenderEvent] { engine?.committedEvents ?? resultEvents }
    }

    /// Weak window subscribers receive task callbacks on the main thread.
    struct Listener {
        weak var owner: AnyObject?
        var onEvents: ([CaptionRenderEvent]) -> Void
        var onProgress: (Task) -> Void
        var onFinished: (Task, Error?) -> Void
    }

    private(set) var running: Task?
    private(set) var queue: [Task] = []
    /// The latest result completed without a visible task capsule; clear it when a new task starts.
    private(set) var lastOutcome: (name: String, error: Error?)?
    private(set) var recoverableSaves: [Task] = []
    private(set) var savingRecovery: Task?
    private static let recoveryIO = DispatchQueue(label: "dev.khuaplayer.captions.recovery", qos: .utility)

    fileprivate struct PendingSave: Sendable {
        var url: URL
        var transcript: Bool
    }

    enum RecoveryError: LocalizedError {
        case busy, superseded
        var errorDescription: String? {
            switch self {
            case .busy: return L("captions.save.busy")
            case .superseded: return L("captions.save.superseded")
            }
        }
    }

    func recoverableTask(forMedia url: URL) -> Task? {
        recoverableSaves.last { $0.mediaKey == Self.key(for: url) }
    }

    var backgroundTask: Task? { running ?? savingRecovery ?? recoverableSaves.last }

    nonisolated static func key(for url: URL) -> String { url.standardizedFileURL.path }

    func task(forMedia url: URL) -> Task? {
        let k = Self.key(for: url)
        if let r = running, r.mediaKey == k { return r }
        return queue.first { $0.mediaKey == k }
    }

    // MARK: - Submission and cancellation

    /// Enqueue; start immediately when idle. An existing task for the same media
    /// is returned instead (the caller shows its status dialog). `ahead` means the
    /// person chose Stop Previous: this request moves to the front and the running
    /// task is stopped.
    @discardableResult
    func submit(_ task: Task, ahead: Bool = false) -> Task {
        if let existing = self.task(forMedia: task.mediaURL) {
            // Another window just queued the same file: the Stop Previous choice still applies to that request.
            if ahead { jumpAhead(existing) }
            return existing
        }
        queue.append(task)
        if ahead { jumpAhead(task) }
        startNextIfIdle()
        return task
    }

    /// Stop Previous: move the queued task to the front and stop the running one. The
    /// slot is handed over only after it physically exits (same as `stop`). A running
    /// task that is saving is never interrupted; the moved task starts once it finishes.
    func jumpAhead(_ task: Task) {
        guard !task.isFinished, !task.isRunning, let current = running, current.mediaKey != task.mediaKey else { return }
        queue.removeAll { $0 === task }
        queue.insert(task, at: 0)
        guard current.canStop else { return }
        current.supersededByName = task.mediaName
        stop(current)
    }

    /// Whom a queued task waits for: the running task, otherwise the same-file save
    /// cleanup blocking the head of the queue. Shared by the dialog fallback and the capsule.
    var blockingTaskName: String { (running ?? savingRecovery)?.mediaName ?? "" }

    /// Whether a new request should ask "stop previous or wait": another file is
    /// running and can be stopped right now. Saving/stopping tasks yield within
    /// seconds, so those requests queue silently.
    func stoppablePredecessor(forMedia url: URL) -> Task? {
        guard let current = running, current.mediaKey != Self.key(for: url), current.canStop else { return nil }
        return current
    }

    /// Reflect stop immediately in the UI, but hold the slot until preparation
    /// and engine cleanup finish to prevent overlapping execution.
    func stop(_ task: Task) {
        guard task.canStop else { return }
        if running === task {
            // The engine decides under the same lock as final commit. A stale
            // enabled button must not announce cancellation that was rejected.
            if let engine = task.engine, !engine.stop() {
                task.phase = .saving
                notifyProgress(task)
                return
            }
            task.isStopping = true
            task.preparationTask?.cancel()
            notifyProgress(task)
        } else {
            queue.removeAll { $0 === task }
            finish(task, error: CancellationError())
        }
    }

    private func startNextIfIdle() {
        guard running == nil, let first = queue.first,
              savingRecovery?.mediaKey != first.mediaKey else { return }
        let task = queue.removeFirst()
        // An explicitly requested replacement supersedes an older failed save.
        recoverableSaves.removeAll { $0.mediaKey == task.mediaKey }
        running = task
        task.hasStarted = true
        lastOutcome = nil
        notifyProgress(task)
        // Queued capsules name the task they wait for: refresh them when the slot changes hands.
        for queued in queue { notifyProgress(queued) }
        guard !task.isStopping else { finish(task, error: CancellationError()); return }
        guard let prepare = task.prepare else {
            startEngine(task)
            return
        }
        task.preparationTask = _Concurrency.Task { @MainActor [weak self, weak task] in
            guard let self, let task else { return }
            do {
                try _Concurrency.Task.checkCancellation()
                let prepared = try await prepare(task)
                try _Concurrency.Task.checkCancellation()
                task.prepare = nil
                task.preparationTask = nil
                switch prepared {
                case .ready(let config, let note):
                    task.config = config
                    task.note = note
                    task.preparationMessage = nil
                    task.languageLabel = Self.languageLabel(config)
                    self.startEngine(task)
                case .notNeeded(let message):
                    task.completionMessage = message
                    self.finish(task, error: nil)
                }
            } catch {
                task.prepare = nil
                task.preparationTask = nil
                self.finish(task, error: task.isStopping ? CancellationError() : error)
            }
        }
    }

    private static func languageLabel(_ config: CaptionEngine.Configuration) -> String {
        let src = CaptionLanguageNames.speech(config.sourceLocale)
        guard let target = config.targetLanguage else { return src }
        let dst = CaptionLanguageNames.target(target)
        return "\(src) → \(dst)"
    }

    /// Preparation state updates only the UI, without extra computation or synchronous waits.
    func preparationChanged(_ task: Task, message: String) {
        guard running === task, task.engine == nil, task.prepare != nil, !task.isStopping else { return }
        task.preparationMessage = message
        notifyProgress(task)
    }

    private func notifyProgress(_ task: Task) {
        for l in task.listeners.values where l.owner != nil { l.onProgress(task) }
        menuTitleChanged()
    }

    private func startEngine(_ task: Task) {
        guard let config = task.config, running === task, !task.isFinished, !task.isStopping else { return }
        let e = CaptionEngine(configuration: config)
        task.engine = e
        e.yieldProbe = { CaptionProbeRegistry.idle() }
        e.onProgress = { [weak self, weak task] p, phase in
            guard let self, let task, self.running === task, !task.isStopping else { return }
            task.progress = p
            task.phase = phase
            task.eta = nil
            let pct = Int((p * 100).rounded())
            switch phase {
            case .transcribing(_, let eta):
                task.eta = eta
                task.progressText = "\(pct)%"
            case .downloadingModel, .translating: task.progressText = "\(pct)%"
            case .preparing, .saving, .finished, .failed: task.progressText = ""
            }
            self.notifyProgress(task)
        }
        e.onEvents = { [weak task] events in
            guard let task, !task.isStopping, !task.isFinished else { return }
            for l in task.listeners.values where l.owner != nil { l.onEvents(events) }
        }
        e.onPlaybackWaitChanged = { [weak self, weak task] waiting in
            guard let self, let task, self.running === task, !task.isStopping else { return }
            task.isWaitingForPlayback = waiting
            self.notifyProgress(task)
        }
        e.onFinished = { [weak self, weak task] error in
            guard let self, let task, !task.isFinished else { return }
            self.finish(task, error: error)
        }
        e.start()
        notifyProgress(task)
    }

    private func finish(_ task: Task, error: Error?) {
        guard !task.isFinished else { return }
        task.isFinished = true
        task.isWaitingForPlayback = false
        task.error = error
        // Finished windows need display events and output names, not the ASR
        // words, translation caches, file-source cues or executor graph.
        if let engine = task.engine {
            task.resultEvents = error is CancellationError ? [] : engine.committedEvents
            task.resultSidecarURL = engine.sidecarURL
            task.resultTranscriptURL = engine.transcriptURL
            task.resultTargetTag = task.targetTag
            task.resultSourceTag = task.config.map { CaptionLanguageTags.fileTag(forTranscriberLocale: $0.sourceLocale) }
            engine.onEvents = nil
            engine.onProgress = nil
            engine.onPlaybackWaitChanged = nil
            engine.onFinished = nil
            task.engine = nil
        }
        task.config = nil
        task.prepare = nil
        task.preparationTask = nil
        if let save = error as? CaptionSaveError, CaptionSRT.hasContent(task.resultEvents),
           let primary = task.resultSidecarURL {
            task.pendingSaves = [PendingSave(url: primary, transcript: false)]
            if let transcript = task.resultTranscriptURL {
                if save.url == transcript { task.pendingSaves.removeAll() }
                task.pendingSaves.append(PendingSave(url: transcript, transcript: true))
            }
            recoverableSaves.removeAll { $0.mediaKey == task.mediaKey }
            recoverableSaves.append(task)
        }
        if running === task { running = nil }
        let listeners = task.listeners.values.filter { $0.owner != nil }
        if listeners.isEmpty, !(error is CancellationError) {
            lastOutcome = (task.mediaName, error)
        }
        for l in listeners { l.onFinished(task, error) }
        task.listeners.removeAll()
        menuTitleChanged()
        startNextIfIdle()
    }

    /// Save preserved results without retaining or restarting an engine. A
    /// replacement for the same media queues behind this physical file write.
    func retrySave(_ task: Task, destination: URL? = nil) async throws {
        guard recoverableSaves.contains(where: { $0 === task }) else { throw RecoveryError.superseded }
        guard savingRecovery == nil, self.task(forMedia: task.mediaURL) == nil,
              !task.pendingSaves.isEmpty else { throw RecoveryError.busy }
        savingRecovery = task
        task.isRetryingSave = true
        notifyProgress(task)
        defer {
            task.isRetryingSave = false
            savingRecovery = nil
            notifyProgress(task)
            for listener in task.listeners.values where listener.owner != nil {
                listener.onFinished(task, task.error)
            }
            menuTitleChanged()
            startNextIfIdle()
        }
        do {
            repeat {
                var output = task.pendingSaves[0]
                if let destination { output.url = destination; task.pendingSaves[0] = output }
                let events = task.resultEvents
                let selectedOutput = output
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    Self.recoveryIO.async {
                        do {
                            let rendered = selectedOutput.transcript ? events.map {
                                CaptionRenderEvent(start: $0.start, end: $0.end, source: $0.source, translation: nil)
                            } : events
                            try CaptionSRT.write(rendered, to: selectedOutput.url)
                            continuation.resume()
                        } catch { continuation.resume(throwing: error) }
                    }
                }
                task.pendingSaves.removeFirst()
                if output.transcript { task.resultTranscriptURL = output.url }
                else { task.resultSidecarURL = output.url }
                if destination != nil { break } // Save As confirms each output independently.
            } while !task.pendingSaves.isEmpty
            if task.pendingSaves.isEmpty {
                task.error = nil
                recoverableSaves.removeAll { $0 === task }
                lastOutcome = (task.mediaName, nil)
            } else if let failure = task.error as? CaptionSaveError {
                task.error = CaptionSaveError(url: task.pendingSaves[0].url, underlying: failure.underlying)
            }
        } catch {
            let wrapped = CaptionSaveError(url: task.pendingSaves[0].url, underlying: error)
            task.error = wrapped
            lastOutcome = (task.mediaName, wrapped)
            throw wrapped
        }
    }

    /// Exceptional recovery has its own actions; each Save As panel authorizes
    /// one filename, including the companion transcript when it still needs saving.
    func presentSaveRecovery(for task: Task, in window: NSWindow?, regenerate: (() -> Void)? = nil) {
        if task.isRetryingSave { presentStatusDialog(for: task, in: window); return }
        let alert = NSAlert()
        alert.messageText = task.error?.localizedDescription ?? L("captions.save.title")
        alert.informativeText = L("captions.save.retained")
        alert.addButton(withTitle: L("captions.button.retrySave"))
        alert.addButton(withTitle: L("captions.button.saveAs"))
        if regenerate != nil { alert.addButton(withTitle: L("captions.button.regenerate")) }
        alert.addButton(withTitle: L("captions.button.cancel"))
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self, weak task, weak window] response in
            guard let self, let task else { return }
            if response == .alertThirdButtonReturn, let regenerate { regenerate(); return }
            guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return }
            _Concurrency.Task { @MainActor in
                do {
                    if response == .alertFirstButtonReturn {
                        try await self.retrySave(task)
                    } else {
                        while let output = task.pendingSaves.first {
                            let panel = NSSavePanel()
                            panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
                            panel.nameFieldStringValue = output.url.lastPathComponent
                            panel.message = output.transcript ? L("captions.save.transcript") : L("captions.save.result")
                            let accepted: NSApplication.ModalResponse
                            if let window, window.isVisible {
                                accepted = await withCheckedContinuation { continuation in
                                    panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
                                }
                            } else { accepted = panel.runModal() }
                            guard accepted == .OK, let url = panel.url else { return }
                            try await self.retrySave(task, destination: url)
                        }
                    }
                } catch {
                    let failure = NSAlert()
                    failure.messageText = L("captions.save.title")
                    failure.informativeText = error.localizedDescription
                    if let window, window.isVisible { failure.beginSheetModal(for: window, completionHandler: nil) }
                    else { failure.runModal() }
                }
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) }
        else { handle(alert.runModal()) }
    }

    // MARK: - Subscriptions

    func addListener(_ listener: Listener, to task: Task, owner: AnyObject) {
        task.listeners[ObjectIdentifier(owner)] = listener
    }

    func removeListener(owner: AnyObject, from task: Task) {
        task.listeners.removeValue(forKey: ObjectIdentifier(owner))
    }

    // MARK: - Menu status

    /// Prefer this media's task, then the app's active task, then the latest background result.
    func menuTitle(forMedia url: URL?) -> String {
        let base = L("menu.captions.generateOrTranslate")
        if let url, let t = task(forMedia: url) {
            if t.isRunning { return base + runningMenuSuffix(t, other: false) }
            return base + L("captions.menu.queued")
        }
        if let url, let recovery = recoverableTask(forMedia: url) {
            return base + (recovery.isRetryingSave ? L("captions.menu.saving") : L("captions.menu.unsaved", recovery.mediaName))
        }
        if let r = running {
            return base + runningMenuSuffix(r, other: true)
        }
        if let recovery = savingRecovery ?? (url.flatMap { recoverableTask(forMedia: $0) }) ?? recoverableSaves.last {
            return base + (recovery.isRetryingSave ? L("captions.menu.savingOther", recovery.mediaName)
                : L("captions.menu.unsaved", recovery.mediaName))
        }
        if let o = lastOutcome {
            return base + (o.error == nil ? L("captions.menu.done", o.name) : L("captions.menu.failed", o.name))
        }
        return base
    }

    private func runningMenuSuffix(_ task: Task, other: Bool) -> String {
        if task.isSaving { return other ? L("captions.menu.savingOther", task.mediaName) : L("captions.menu.saving") }
        if task.isStopping { return other ? L("captions.menu.stoppingOther", task.mediaName) : L("captions.menu.stopping") }
        if task.isWaitingForPlayback { return other ? L("captions.menu.waitingOther", task.mediaName) : L("captions.menu.waiting") }
        return other ? L("captions.menu.runningOther", task.mediaName, Self.percentage(task.progress))
            : L("captions.menu.running", Self.percentage(task.progress))
    }

    /// Refresh an already-open menu when its title changes; closed menus need no work.
    private var menuUpdatePending = false
    private func menuTitleChanged() {
        guard !menuUpdatePending else { return }
        menuUpdatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.menuUpdatePending = false
            func update(_ menu: NSMenu) {
                if menu.items.contains(where: { $0.action == NSSelectorFromString("generateCaptionsAction:") }) {
                    menu.update()
                    return
                }
                for item in menu.items { if let submenu = item.submenu { update(submenu) } }
            }
            if let menu = NSApp?.mainMenu { update(menu) }
        }
    }

    // MARK: - Status dialogs

    struct DialogContent: Equatable {
        var title: String
        var message: String
        var primaryTitle: String
        var secondaryTitle: String?
        var secondaryEnabled: Bool
        /// The secondary button discards another task's progress (Stop Previous): use the
        /// system destructive style.
        var secondaryDestructive = false
    }

    /// "Stop previous or wait for it": the same question before submitting a new
    /// request and after it is queued; only the title differs. The two sentences of
    /// the body map one-to-one onto the two buttons. `othersAhead` = other tasks are
    /// queued ahead besides the running one: the predecessor's remaining time is not
    /// this file's wait, so it is not shown.
    func jumpAheadContent(predecessor: Task, queued: Bool, othersAhead: Bool = false) -> DialogContent {
        let pct = Self.percentage(predecessor.progress)
        let title = queued ? L("captions.dialog.behindTitle", predecessor.mediaName, pct)
                           : L("captions.dialog.stillGeneratingTitle", predecessor.mediaName, pct)
        let message: String
        if !othersAhead, let eta = predecessor.eta, eta.isFinite, eta >= 60 {
            message = L("captions.dialog.jumpAheadETA", Self.formatETA(eta))
        } else {
            message = L("captions.dialog.jumpAhead")
        }
        return DialogContent(title: title, message: message, primaryTitle: L("captions.button.waitForIt"),
                             secondaryTitle: L("captions.button.stopPrevious"),
                             secondaryEnabled: predecessor.canStop, secondaryDestructive: true)
    }

    /// The same value configures the live alert and is checked by state tests.
    func statusContent(for task: Task) -> DialogContent {
        if task.isRetryingSave {
            return DialogContent(title: L("captions.save.title"), message: L("captions.status.saving"),
                                 primaryTitle: L("captions.button.done"), secondaryTitle: nil, secondaryEnabled: false)
        }
        if task.isFinished {
            let title: String
            if task.error is CancellationError { title = L("captions.status.stopped") }
            else if let save = task.error as? CaptionSaveError { title = Self.saveFailureMessage(save) }
            else if let error = task.error { title = L("captions.status.failed", error.localizedDescription) }
            else { title = task.completionMessage ?? L("captions.status.done", task.sidecarURL?.lastPathComponent ?? task.mediaName) }
            return DialogContent(title: title, message: "", primaryTitle: L("captions.button.done"),
                                 secondaryTitle: nil, secondaryEnabled: false)
        }
        if !task.isRunning {
            // Behind another file: ask "stop previous or wait for it". With nothing running
            // (only blocked by the same file's save cleanup) fall back to Keep Waiting /
            // Remove from Queue.
            if let current = running, current.mediaKey != task.mediaKey {
                return jumpAheadContent(predecessor: current, queued: true,
                                        othersAhead: (queue.firstIndex { $0 === task } ?? 0) > 0)
            }
            return DialogContent(title: L("captions.dialog.queuedTitle", task.mediaName),
                                 message: L("captions.dialog.queued", blockingTaskName),
                                 primaryTitle: L("captions.button.keepWaiting"),
                                 secondaryTitle: L("captions.button.dequeue"), secondaryEnabled: task.canStop)
        }
        var message: String
        if task.isSaving { message = L("captions.status.saving") }
        else {
            if task.isStopping { message = L("captions.status.stopping") }
            else if task.isWaitingForPlayback { message = L("captions.status.waitingForPlayback") }
            else if task.phase == .preparing { message = task.preparationMessage ?? L("captions.status.preparing") }
            else {
                message = L("captions.dialog.running", Self.percentage(task.progress))
                if let eta = task.eta, eta.isFinite, eta >= 60 { message += L("captions.dialog.eta", Self.formatETA(eta)) }
            }
            message += "\n" + L("captions.dialog.stopLoses")
        }
        return DialogContent(title: L("captions.dialog.runningTitle", task.mediaName), message: message,
                             primaryTitle: L("captions.button.keepGoing"),
                             secondaryTitle: L("captions.button.stop"), secondaryEnabled: task.canStop)
    }

    private static func percentage(_ progress: Double) -> Int {
        progress.isFinite ? Int((min(1, max(0, progress)) * 100).rounded()) : 0
    }

    static func saveFailureMessage(_ error: CaptionSaveError) -> String {
        let explanation: String?
        if let output = error.underlying as? CaptionSRT.OutputError {
            explanation = output.localizedDescription
        } else {
            let cause = error.underlying as NSError
            if (cause.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM), Int(EROFS)].contains(cause.code))
                || (cause.domain == NSCocoaErrorDomain && [NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError].contains(cause.code)) {
                explanation = L("captions.save.permission")
            } else if (cause.domain == NSPOSIXErrorDomain && cause.code == Int(ENOSPC))
                || (cause.domain == NSCocoaErrorDomain && cause.code == NSFileWriteOutOfSpaceError) {
                explanation = L("captions.save.diskFull")
            } else { explanation = nil }
        }
        return error.localizedDescription + (explanation.map { " " + $0 } ?? "")
    }

    /// Present active or queued task status. A nil window uses app-modal presentation.
    func presentStatusDialog(for task: Task, in window: NSWindow?) {
        let alert = NSAlert()
        let keep = alert.addButton(withTitle: L("captions.button.keepGoing"))
        let stop = alert.addButton(withTitle: L("captions.button.stop"))
        let refresh: (Task) -> Void = { [weak alert, weak self] current in
            guard let alert, let self else { return }
            let previous = (alert.messageText, alert.informativeText, keep.title, stop.title)
            let content = self.statusContent(for: current)
            alert.messageText = content.title
            alert.informativeText = content.message
            keep.title = content.primaryTitle
            stop.title = content.secondaryTitle ?? ""
            stop.isEnabled = content.secondaryEnabled
            stop.isHidden = content.secondaryTitle == nil
            stop.hasDestructiveAction = content.secondaryDestructive
            if previous != (alert.messageText, alert.informativeText, keep.title, stop.title) {
                alert.layout()
            }
        }
        refresh(task)
        // Keep an already-open dialog truthful across saving/completion as well
        // as rechecking cancellation atomically when the action is delivered.
        let observer = NSObject()
        let seenPredecessor = observeStatusDialog(for: task, owner: observer, refresh: refresh) { [weak alert] in
            guard let alert else { return }
            if let window { window.endSheet(alert.window, returnCode: .alertFirstButtonReturn) }
            else { NSApp.abortModal() }
        }
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self, weak task, weak seenPredecessor] resp in
            guard let self, let task else { return }
            self.removeListener(owner: observer, from: task)
            if let seenPredecessor { self.removeListener(owner: observer, from: seenPredecessor) }
            guard resp == .alertSecondButtonReturn else { return }
            self.performSecondaryAction(for: task, seenPredecessor: seenPredecessor)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) }
        else { handle(alert.runModal()) }
    }

    /// Status dialog subscription (no UI, testable): changes to this task refresh the
    /// content; when queued behind another file, that predecessor's progress refreshes
    /// too and its end dismisses the dialog. The dialog answers a question about that
    /// one task only; once it is gone the question is gone, and reopening the menu asks
    /// about the new predecessor. Likewise, a dialog opened with no predecessor (blocked
    /// only by save cleanup) is dismissed when one appears. Returns the predecessor seen
    /// at open time (the secondary button acts only on it).
    @discardableResult
    func observeStatusDialog(for task: Task, owner: AnyObject, refresh: @escaping (Task) -> Void,
                             dismiss: @escaping () -> Void) -> Task? {
        let queuedWithoutPredecessor = !task.isRunning && !task.isFinished && running == nil
        addListener(Listener(owner: owner, onEvents: { _ in }, onProgress: { [weak self] task in
            if queuedWithoutPredecessor, let self, self.running != nil, !task.isRunning, !task.isFinished {
                dismiss()
                return
            }
            refresh(task)
        }, onFinished: { task, _ in refresh(task) }), to: task, owner: owner)
        guard !task.isRunning, !task.isFinished, let predecessor = running,
              predecessor.mediaKey != task.mediaKey else { return nil }
        addListener(Listener(owner: owner, onEvents: { _ in }, onProgress: { [weak task] _ in
            if let task { refresh(task) }
        }, onFinished: { _, _ in dismiss() }), to: predecessor, owner: owner)
        return predecessor
    }

    /// The secondary button acts only on the task whose name the person saw: opened
    /// behind `seenPredecessor`, it stops that task and moves ahead only while it is
    /// still running, and does nothing once the slot changed hands. Opened for a running
    /// task, or one blocked only by save cleanup, it stops or dequeues the task itself.
    func performSecondaryAction(for task: Task, seenPredecessor: Task?) {
        if let seenPredecessor {
            guard running === seenPredecessor, !task.isRunning, !task.isFinished else { return }
            jumpAhead(task)
        } else {
            stop(task)
        }
    }

    /// Confirm quitting once while work remains. True permits termination.
    func confirmQuitIfNeeded() -> Bool {
        guard let content = quitContent else { return true }
        let alert = NSAlert()
        alert.messageText = content.title
        alert.informativeText = content.message
        alert.addButton(withTitle: content.primaryTitle)
        alert.addButton(withTitle: content.secondaryTitle!)
        return alert.runModal() == .alertSecondButtonReturn
    }

    var quitContent: DialogContent? {
        guard let task = savingRecovery ?? running else {
            guard !recoverableSaves.isEmpty else { return nil }
            return DialogContent(title: L("captions.quit.unsavedTitle"),
                                 message: L("captions.quit.unsavedMessage", recoverableSaves.count),
                                 primaryTitle: L("captions.button.cancel"),
                                 secondaryTitle: L("captions.button.quitAnyway"), secondaryEnabled: true)
        }
        return DialogContent(title: task.isSaving ? L("captions.quit.savingTitle")
                                 : L("captions.quit.title", Self.percentage(task.progress)),
                             message: task.isSaving ? L("captions.quit.savingMessage", task.mediaName)
                                 : L("captions.quit.message", task.mediaName),
                             primaryTitle: L("captions.button.cancel"),
                             secondaryTitle: L("captions.button.quitAnyway"), secondaryEnabled: true)
    }

    /// Welcome-window status after the last playback window closes.
    var backgroundNotice: String? {
        guard let r = savingRecovery ?? running else { return nil }
        if r.isSaving { return L("captions.welcome.saving", r.mediaName) }
        if r.isStopping { return L("captions.welcome.stopping", r.mediaName) }
        if r.isWaitingForPlayback { return L("captions.welcome.waitingForPlayback", r.mediaName) }
        return L("captions.welcome.background", r.mediaName, Self.percentage(r.progress))
    }

    static func formatETA(_ seconds: Double) -> String {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        f.maximumUnitCount = 2
        return f.string(from: max(60, seconds)) ?? "\(Int(seconds / 60)) min"
    }
}

// Background readers yield at block boundaries whenever any live playback
// core is busy. A lock protects the weak registry; admission probes read only
// atomic playback state and never retain a core.
enum CaptionProbeRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cores: [WeakCore] = []

    private struct WeakCore { weak var core: SPPlayerCore? }

    static func register(_ core: SPPlayerCore) {
        lock.withLock {
            cores.removeAll { $0.core == nil || $0.core === core }
            cores.append(WeakCore(core: core))
        }
    }

    static func unregister(_ core: SPPlayerCore) {
        lock.withLock { cores.removeAll { $0.core == nil || $0.core === core } }
    }

    /// True only when every registered live core permits background work.
    static func idle() -> Bool {
        let snapshot = lock.withLock { cores.compactMap(\.core) }
        return snapshot.allSatisfy { $0.backgroundWorkIdle() }
    }
}

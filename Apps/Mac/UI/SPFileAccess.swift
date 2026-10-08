import AppKit
import Darwin

enum SPFileAccess {

    static let realHome: String = {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }()

    static func location(ofPath path: String) -> SPAccessLocation? {
        SPAccessLocationClassifier.location(forPath: path, home: realHome)
    }

    private static let lock = NSLock()
    private static let ledgerKey = "sp.fileAccess.grantedLocations"
    nonisolated(unsafe) private static var cachedLedger: SPAccessGrantLedger?

    private static func withLedger<T>(_ body: (inout SPAccessGrantLedger) -> (T, Bool)) -> T {
        lock.lock()
        defer { lock.unlock() }
        var ledger = cachedLedger ?? SPAccessGrantLedger(
            keys: UserDefaults.standard.stringArray(forKey: ledgerKey) ?? [])
        let (result, changed) = body(&ledger)
        cachedLedger = ledger
        if changed { UserDefaults.standard.set(ledger.keys, forKey: ledgerKey) }
        return result
    }

    static func mayWarm(path: String) -> Bool {
        let location = location(ofPath: path)
        guard withLedger({ (SPBackgroundAccessPolicy.mayWarm(location, ledger: $0), false) })
        else { return false }
#if SP_APP_STORE

        return SPFolderGrants.isActive(path: path)
#else
        return true
#endif
    }

    static func mayScanAfterOpen(directory: URL) -> Bool {
#if SP_APP_STORE

        return SPFolderGrants.isCovered(path: directory.path)
#else
        return SPBackgroundAccessPolicy.mayScanAfterOpen(location(ofPath: directory.path))
#endif
    }

    static func noteDirectoryListing(_ directory: URL, error code: Int32?) {
        guard let location = location(ofPath: directory.path) else { return }
        withLedger { ledger -> (Void, Bool) in
            switch code {
            case nil:
                return ((), ledger.noteGranted(location.key))
            case EPERM?, EACCES?:
                return ((), ledger.noteDenied(location.key))
            default:
                return ((), false)
            }
        }
    }
}

#if SP_APP_STORE

private func spAccessPath(_ path: String) -> String {
    (path as NSString).standardizingPath
}

private func spOnExternalVolume(_ path: String) -> Bool {
    let parts = (spAccessPath(path) as NSString).pathComponents
    return parts.count >= 2 && (parts[1] == "Volumes" || parts[1] == "Network")
}

private func spResolutionProvesMissing(path: String, error: Error?) -> Bool {
    guard !spOnExternalVolume(path), let error = error as NSError?,
          error.domain == NSCocoaErrorDomain else { return false }
    return error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError
}

enum SPFolderGrants {
    private struct Entry: Codable {
        var path: String
        var bookmark: Data
    }

    private static let lock = NSLock()
    private static let storeKey = "sp.fileAccess.folderBookmarks"
    private static let capacity = 24
    private static let failureRetryDelay: TimeInterval = 30
    nonisolated(unsafe) private static var loadedEntries: [Entry]?

    nonisolated(unsafe) private static var active: [String: URL] = [:]

    nonisolated(unsafe) private static var failedUntil: [String: TimeInterval] = [:]

    static let entitlementRoots: [String] = [
        SPFileAccess.realHome + "/Downloads",
        SPFileAccess.realHome + "/Movies",
    ]

    private static func entries() -> [Entry] {
        if let loadedEntries { return loadedEntries }
        let stored = UserDefaults.standard.data(forKey: storeKey)
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        loadedEntries = stored
        return stored
    }

    private static func save(_ list: [Entry]) {
        loadedEntries = list
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    private static func isInside(_ path: String, root: String) -> Bool {
        SPAccessLocationClassifier.remainder(of: spAccessPath(path), under: root) != nil
    }

    private static func coveredByEntitlement(_ path: String) -> Bool {
        entitlementRoots.contains { isInside(path, root: $0) }
    }

    private static func activeCoverLocked(_ path: String) -> Bool {
        active.keys.contains { isInside(path, root: $0) }
    }

    private static func candidatesLocked(_ path: String, now: TimeInterval) -> [Entry] {
        entries()
            .filter { isInside(path, root: $0.path) && (failedUntil[$0.path] ?? 0) <= now }
            .sorted { $0.path.count > $1.path.count }
    }

    static func isCovered(path: String) -> Bool {
        if coveredByEntitlement(path) { return true }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        return activeCoverLocked(path) || !candidatesLocked(path, now: now).isEmpty
    }

    static func isActive(path: String) -> Bool {
        if coveredByEntitlement(path) { return true }
        lock.lock()
        defer { lock.unlock() }
        return activeCoverLocked(path)
    }

    @discardableResult
    static func ensureAccess(path: String) -> Bool {
        if coveredByEntitlement(path) { return true }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if activeCoverLocked(path) {
            lock.unlock()
            return true
        }
        let candidates = candidatesLocked(path, now: now)
        lock.unlock()
        for entry in candidates {

            if let root = activate(entry), isInside(path, root: root) { return true }
        }
        return false
    }

    private static func activate(_ entry: Entry) -> String? {
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: entry.bookmark,
                          options: [.withSecurityScope, .withoutUI, .withoutMounting],
                          relativeTo: nil,
                          bookmarkDataIsStale: &stale)
        } catch {
            noteFailure(entry, error: error)
            return nil
        }
        guard url.startAccessingSecurityScopedResource() else {
            noteFailure(entry, error: nil)
            return nil
        }
        let resolvedPath = spAccessPath(url.path)
        let moved = resolvedPath != entry.path
        var fresh: Data?
        if stale || moved {
            fresh = try? url.bookmarkData(options: .withSecurityScope,
                                          includingResourceValuesForKeys: nil,
                                          relativeTo: nil)
        }
        var release: [URL] = []
        lock.lock()
        failedUntil[entry.path] = nil

        if moved, let old = active.removeValue(forKey: entry.path) { release.append(old) }
        if active[resolvedPath] != nil {
            release.append(url)
        } else {
            active[resolvedPath] = url
        }
        if moved || stale {

            var list = entries()
            if let i = list.firstIndex(where: { $0.path == entry.path }) {
                var updated = list.remove(at: i)
                updated.path = resolvedPath
                if let fresh { updated.bookmark = fresh }
                list.removeAll { $0.path == resolvedPath }
                list.insert(updated, at: min(i, list.count))
                save(list)
            }
        }
        lock.unlock()
        release.forEach { $0.stopAccessingSecurityScopedResource() }
        return resolvedPath
    }

    nonisolated(unsafe) private static var refreshInFlight = false
    nonisolated(unsafe) private static var refreshWaiters: [@MainActor () -> Void] = []
    nonisolated(unsafe) private static var nextRefreshWaiters: [@MainActor () -> Void] = []

    @MainActor
    private static func refresh(then completion: @escaping @MainActor () -> Void) {
        if refreshInFlight {
            nextRefreshWaiters.append(completion)
            return
        }
        refreshWaiters.append(completion)
        refreshInFlight = true
        DispatchQueue.global(qos: .utility).async {
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock()
            let pending = entries().filter { (failedUntil[$0.path] ?? 0) <= now }
            lock.unlock()
            for entry in pending { _ = activate(entry) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    refreshInFlight = false
                    let waiters = refreshWaiters
                    refreshWaiters.removeAll()
                    let next = nextRefreshWaiters
                    nextRefreshWaiters.removeAll()
                    waiters.forEach { $0() }
                    if let first = next.first {
                        refresh(then: first)
                        refreshWaiters.append(contentsOf: next.dropFirst())
                    }
                }
            }
        }
    }

    @MainActor
    static func checkAccess(path: String, completion: @escaping @MainActor (Bool) -> Void) {
        if coveredByEntitlement(path) {
            completion(true)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let accessible = ensureAccess(path: path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if accessible {
                        completion(true)
                        return
                    }
                    refresh {
                        lock.lock()
                        let covered = activeCoverLocked(path)
                        lock.unlock()
                        completion(covered)
                    }
                }
            }
        }
    }

    private static func noteFailure(_ entry: Entry, error: Error?) {
        let missing = spResolutionProvesMissing(path: entry.path, error: error)
        lock.lock()
        defer { lock.unlock() }
        if missing {
            save(entries().filter { $0.path != entry.path })
            failedUntil[entry.path] = nil
        } else {
            failedUntil[entry.path] = ProcessInfo.processInfo.systemUptime + failureRetryDelay
        }
    }

    @MainActor
    static func requestAccess(to directory: URL, message: String, window: NSWindow?,
                              completion: @escaping @MainActor (Bool) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = directory
        panel.message = message
        panel.prompt = L("access.folder.grantButton")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else {
                completion(false)
                return
            }

            guard isInside(directory.path, root: spAccessPath(url.path)) else {
                let retry = String(format: L("access.folder.wrongFolderFmt"),
                                   directory.lastPathComponent)
                DispatchQueue.main.async {
                    requestAccess(to: directory, message: retry, window: window,
                                  completion: completion)
                }
                return
            }
            remember(folder: url)
            completion(true)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    private static func remember(folder url: URL) {
        let path = spAccessPath(url.path)
        guard url.startAccessingSecurityScopedResource() else { return }
        let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                             includingResourceValuesForKeys: nil,
                                             relativeTo: nil)
        lock.lock()
        defer { lock.unlock() }
        if active[path] != nil {
            url.stopAccessingSecurityScopedResource()
        } else {
            active[path] = url
        }
        failedUntil[path] = nil
        guard let bookmark else { return }
        var list = entries().filter { $0.path != path }
        list.append(Entry(path: path, bookmark: bookmark))
        if list.count > capacity { list.removeFirst(list.count - capacity) }
        save(list)
    }
}

enum SPRecentBookmarks {
    enum Resolution {
        case granted(URL)
        case volumeUnavailable
        case unavailable
    }

    private static let storeKey = "sp.fileAccess.recentBookmarks"
    private static let capacity = 40
    private static let lock = NSLock()
    private static let queue = DispatchQueue(label: "sp.recent-bookmarks", qos: .utility)

    private struct Entry: Codable {
        var path: String
        var bookmark: Data
    }

    private static func key(_ path: String) -> String { spAccessPath(path) }

    private static func load() -> [Entry] {
        UserDefaults.standard.data(forKey: storeKey)
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    private static func store(_ list: [Entry]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    private static func mutate(_ body: (inout [Entry]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var list = load()
        body(&list)
        if list.count > capacity { list.removeFirst(list.count - capacity) }
        store(list)
    }

    static func remember(_ url: URL) {
        let path = key(url.path)
        queue.async {
            guard let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                       includingResourceValuesForKeys: nil,
                                                       relativeTo: nil) else { return }
            mutate { list in
                list.removeAll { $0.path == path }
                list.append(Entry(path: path, bookmark: bookmark))
            }
        }
    }

    static func resolveStartingAccess(path rawPath: String) -> Resolution {
        let path = key(rawPath)
        lock.lock()
        let entry = load().first { $0.path == path }
        lock.unlock()
        guard let entry else { return .unavailable }
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: entry.bookmark,
                          options: [.withSecurityScope, .withoutUI, .withoutMounting],
                          relativeTo: nil,
                          bookmarkDataIsStale: &stale)
        } catch {

            if spOnExternalVolume(path) { return .volumeUnavailable }
            if spResolutionProvesMissing(path: path, error: error) { forget(path: path) }
            return .unavailable
        }
        guard url.startAccessingSecurityScopedResource() else { return .unavailable }
        let resolvedPath = key(url.path)
        if stale || resolvedPath != path,
           let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                             includingResourceValuesForKeys: nil,
                                             relativeTo: nil) {
            queue.async {
                mutate { list in
                    list.removeAll { $0.path == path || $0.path == resolvedPath }
                    list.append(Entry(path: resolvedPath, bookmark: fresh))
                }
            }
        }
        return .granted(url)
    }

    static func forget(path rawPath: String) {
        let path = key(rawPath)
        queue.async { mutate { $0.removeAll { $0.path == path } } }
    }

    static func rename(from rawOld: String, to rawNew: String) {
        let old = key(rawOld), new = key(rawNew)
        queue.async {
            mutate { list in
                guard let i = list.firstIndex(where: { $0.path == old }) else { return }
                let bookmark = list[i].bookmark
                list.removeAll { $0.path == old || $0.path == new }
                list.append(Entry(path: new, bookmark: bookmark))
            }
        }
    }

    static func clear() {
        queue.async {
            lock.lock()
            defer { lock.unlock() }
            UserDefaults.standard.removeObject(forKey: storeKey)
        }
    }
}
#endif

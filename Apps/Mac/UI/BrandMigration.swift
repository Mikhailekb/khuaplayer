import Foundation
import Darwin

/// Copies this fork's development data without changing the original Khua app.
@MainActor
enum SPBrandMigration {
    nonisolated static let legacyIdentifier = "app.khuaplayer.KhuaPlayer.SidebarDev"
    nonisolated static let currentIdentifier = "app.kinolet.player"
    nonisolated static let completionKey = "kinolet.migration.sidebarDev.v1.complete"

    enum Outcome: Equatable { case notApplicable, alreadyComplete, completed }
    enum MigrationError: Error { case preferencesUnavailable, unsafeFileType }

    static func runIfNeeded() {
        guard Bundle.main.bundleIdentifier == currentIdentifier,
              let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                      in: .userDomainMask).first else { return }
        let defaults = UserDefaults.standard
        // Failed copies remain unmarked and are retried at the next launch.
        // Do not log paths, media names, or the contents of either domain.
        _ = try? migrate(bundleIdentifier: Bundle.main.bundleIdentifier,
                         applicationSupportDirectory: support,
                         readDomain: { defaults.persistentDomain(forName: $0) },
                         writeDomain: { values, identifier in
                             defaults.setPersistentDomain(values, forName: identifier)
                             guard defaults.synchronize() else {
                                 throw MigrationError.preferencesUnavailable
                             }
                         })
    }

    /// Domain access and the storage root are injectable for isolated regression checks.
    @discardableResult
    static func migrate(bundleIdentifier: String?, applicationSupportDirectory: URL,
                        readDomain: (String) -> [String: Any]?,
                        writeDomain: ([String: Any], String) throws -> Void,
                        fileManager: FileManager = .default) throws -> Outcome {
        guard bundleIdentifier == currentIdentifier else { return .notApplicable }
        var destination = readDomain(currentIdentifier) ?? [:]
        if destination[completionKey] as? Bool == true { return .alreadyComplete }
        let previous = readDomain(legacyIdentifier) ?? [:]
        var preferencesChanged = false
        for (key, value) in previous where key != completionKey && destination[key] == nil {
            destination[key] = value
            preferencesChanged = true
        }
        if preferencesChanged { try writeDomain(destination, currentIdentifier) }

        let sourceRoot = applicationSupportDirectory.appendingPathComponent(legacyIdentifier,
                                                                           isDirectory: true)
        let source = sourceRoot.appendingPathComponent("Torrent Resume", isDirectory: true)
        if let sourceKind = try kind(of: sourceRoot) {
            guard sourceKind == .directory else { throw MigrationError.unsafeFileType }
            if let resumeKind = try kind(of: source) {
                guard resumeKind == .directory else { throw MigrationError.unsafeFileType }
                let targetRoot = applicationSupportDirectory.appendingPathComponent(currentIdentifier,
                                                                                   isDirectory: true)
                try ensureDirectory(targetRoot, fileManager: fileManager)
                try copyMissingFiles(from: source,
                                     to: targetRoot.appendingPathComponent("Torrent Resume", isDirectory: true),
                                     fileManager: fileManager)
            }
        }

        // Re-read before marking completion so values written during a retry are kept.
        var completed = readDomain(currentIdentifier) ?? destination
        completed[completionKey] = true
        try writeDomain(completed, currentIdentifier)
        return .completed
    }

    private enum Kind { case directory, regular, other }

    private static func kind(of url: URL) throws -> Kind? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .regular
        default: return .other
        }
    }

    private static func ensureDirectory(_ url: URL, fileManager: FileManager) throws {
        if let existing = try kind(of: url) {
            guard existing == .directory else { throw MigrationError.unsafeFileType }
            return
        }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
        } catch {
            guard try kind(of: url) == .directory else { throw error }
        }
    }

    private static func copyMissingFiles(from source: URL, to destination: URL,
                                         fileManager: FileManager) throws {
        try ensureDirectory(destination, fileManager: fileManager)
        let children = try fileManager.contentsOfDirectory(at: source,
                                                           includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for child in children {
            let target = destination.appendingPathComponent(child.lastPathComponent)
            switch try kind(of: child) {
            case .directory:
                try copyMissingFiles(from: child, to: target, fileManager: fileManager)
            case .regular:
                if let existing = try kind(of: target) {
                    guard existing == .regular else { throw MigrationError.unsafeFileType }
                    continue
                }
                // Publish only a complete copy, atomically and without replacement.
                let staging = destination.appendingPathComponent(".kinolet-migrate-" + UUID().uuidString)
                defer { try? fileManager.removeItem(at: staging) }
                try fileManager.copyItem(at: child, to: staging)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
                if link(staging.path, target.path) != 0 {
                    let code = errno
                    if code == EEXIST, try kind(of: target) == .regular { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
                }
            case .none, .other:
                throw MigrationError.unsafeFileType
            }
        }
    }
}

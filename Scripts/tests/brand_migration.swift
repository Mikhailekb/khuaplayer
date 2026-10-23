import Foundation
import Darwin

@main @MainActor
struct BrandMigrationChecks {
    static var checks = 0
    enum CheckError: Error { case failed(String), injectedWriteFailure }

    @MainActor final class Fixture {
        let defaults: UserDefaults
        let names: [String: String]
        let root: URL
        var reads: [String] = []
        var writes: [String] = []
        let originalIdentifier = "app.khuaplayer.KhuaPlayer"

        init() throws {
            let token = "kinolet-migration-test-" + UUID().uuidString
            names = [SPBrandMigration.legacyIdentifier: token + "-legacy",
                     SPBrandMigration.currentIdentifier: token + "-current",
                     "app.khuaplayer.KhuaPlayer": token + "-original"]
            defaults = UserDefaults(suiteName: token)!
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent(token, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }

        func cleanup() {
            for name in names.values { defaults.removePersistentDomain(forName: name) }
            _ = defaults.synchronize()
            try? FileManager.default.removeItem(at: root)
        }

        func read(_ identifier: String) -> [String: Any]? {
            reads.append(identifier)
            guard let name = names[identifier] else { preconditionFailure("Unisolated test domain") }
            return defaults.persistentDomain(forName: name)
        }

        func write(_ values: [String: Any], _ identifier: String) {
            writes.append(identifier)
            guard let name = names[identifier] else { preconditionFailure("Unisolated test domain") }
            defaults.setPersistentDomain(values, forName: name)
        }

        func domain(_ identifier: String) -> [String: Any] { read(identifier) ?? [:] }
        var current: [String: Any] { domain(SPBrandMigration.currentIdentifier) }
        var source: URL { root.appendingPathComponent(SPBrandMigration.legacyIdentifier)
            .appendingPathComponent("Torrent Resume", isDirectory: true) }
        var destination: URL { root.appendingPathComponent(SPBrandMigration.currentIdentifier)
            .appendingPathComponent("Torrent Resume", isDirectory: true) }

        func makeSource() throws {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        }

        func run(identifier: String? = SPBrandMigration.currentIdentifier,
                 failWrites: Bool = false, failCompletion: Bool = false) throws -> SPBrandMigration.Outcome {
            try SPBrandMigration.migrate(bundleIdentifier: identifier,
                applicationSupportDirectory: root, readDomain: read,
                writeDomain: { values, destination in
                    if failWrites || (failCompletion && values[SPBrandMigration.completionKey] as? Bool == true) {
                        throw CheckError.injectedWriteFailure
                    }
                    self.write(values, destination)
                })
        }
    }

    static func check(_ condition: @autoclosure () throws -> Bool, _ description: String) throws {
        checks += 1
        guard try condition() else { throw CheckError.failed(description) }
    }

    static func withFixture(_ body: (Fixture) throws -> Void) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try body(fixture)
    }

    static func expectFailure(_ description: String, _ action: () throws -> Void) throws {
        do { try action() }
        catch { checks += 1; return }
        throw CheckError.failed(description)
    }

    static func main() throws {
        try firstRunChecks()
        try preservationChecks()
        try idempotencyChecks()
        try retryChecks()
        try originalApplicationChecks()
        try fileBoundaryChecks()
        print("Brand migration checks passed (\(checks) assertions; isolated preferences and temporary files only).")
    }

    static func firstRunChecks() throws {
        try withFixture { fixture in
            let stableIdentity = "/Library/Application Support/Khua/Torrent Playlists/example/Show/Episode.mkv"
            let values: [String: Any] = ["sp.volume": 0.75, "sp.flag": false,
                "sp.count": 4, "sp.list": ["first", "second"],
                "sp.bytes": Data([1, 2, 3]), "sp.date": Date(timeIntervalSince1970: 123),
                "sp.pos." + stableIdentity: 120.5, "stableIdentity": stableIdentity]
            fixture.write(values, SPBrandMigration.legacyIdentifier)
            try fixture.makeSource()
            try Data([3, 2, 1]).write(to: fixture.source.appendingPathComponent("one.torrent"))
            try FileManager.default.createDirectory(at: fixture.source.appendingPathComponent("nested"),
                                                     withIntermediateDirectories: false)
            try Data([4, 5]).write(to: fixture.source.appendingPathComponent("nested/two.torrent"))
            try check(fixture.run() == .completed, "First applicable launch completes migration")
            for (key, value) in values {
                try check(NSDictionary(dictionary: [key: fixture.current[key] as Any])
                    .isEqual(to: [key: value]), "Preference property-list value is copied unchanged")
            }
            try check(fixture.current[SPBrandMigration.completionKey] as? Bool == true,
                      "Completion is recorded after both preferences and metadata")
            try check(Data(contentsOf: fixture.destination.appendingPathComponent("one.torrent")) == Data([3, 2, 1]),
                      "Torrent metadata bytes are copied")
            try check(Data(contentsOf: fixture.destination.appendingPathComponent("nested/two.torrent")) == Data([4, 5]),
                      "Nested metadata files are copied")
            try check(NSDictionary(dictionary: fixture.domain(SPBrandMigration.legacyIdentifier)).isEqual(to: values),
                      "The legacy preference domain remains unchanged")
            try check(Data(contentsOf: fixture.source.appendingPathComponent("one.torrent")) == Data([3, 2, 1]),
                      "The source metadata remains unchanged")
            let attributes = try FileManager.default.attributesOfItem(atPath: fixture.destination.path)
            try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
                      "New metadata directory is private")
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: fixture.destination.appendingPathComponent("one.torrent").path)
            try check((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                      "Copied metadata file is private")
            try check(fixture.current["stableIdentity"] as? String == stableIdentity,
                      "Stable legacy playlist identity strings are not renamed")
        }
    }

    static func preservationChecks() throws {
        try withFixture { fixture in
            fixture.write(["same": "legacy", "falseValue": true, "missing": "copy"], SPBrandMigration.legacyIdentifier)
            fixture.write(["same": "new", "falseValue": false, "newOnly": 9], SPBrandMigration.currentIdentifier)
            try fixture.makeSource()
            try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: true)
            try Data([1]).write(to: fixture.source.appendingPathComponent("same.torrent"))
            try Data([2]).write(to: fixture.destination.appendingPathComponent("same.torrent"))
            try Data([3]).write(to: fixture.source.appendingPathComponent("missing.torrent"))
            _ = try fixture.run()
            try check(fixture.current["same"] as? String == "new", "New preferences take precedence")
            try check(fixture.current["falseValue"] as? Bool == false, "An existing false value is not treated as absent")
            try check(fixture.current["newOnly"] as? Int == 9, "New-only preferences remain")
            try check(fixture.current["missing"] as? String == "copy", "Only absent preferences are imported")
            try check(Data(contentsOf: fixture.destination.appendingPathComponent("same.torrent")) == Data([2]),
                      "Existing destination metadata is never overwritten")
            try check(Data(contentsOf: fixture.destination.appendingPathComponent("missing.torrent")) == Data([3]),
                      "Missing metadata is added beside existing files")
        }
    }

    static func idempotencyChecks() throws {
        try withFixture { fixture in
            fixture.write(["initial": 1], SPBrandMigration.legacyIdentifier)
            _ = try fixture.run()
            fixture.write(["initial": 2, "late": 3], SPBrandMigration.legacyIdentifier)
            try fixture.makeSource()
            try Data([1]).write(to: fixture.source.appendingPathComponent("late.torrent"))
            let writes = fixture.writes.count
            try check(fixture.run() == .alreadyComplete, "Completed migration is not repeated")
            try check(fixture.writes.count == writes, "A completed migration performs no preference writes")
            try check(fixture.current["initial"] as? Int == 1 && fixture.current["late"] == nil,
                      "Later legacy changes are not merged after the one-time migration")
            try check(!FileManager.default.fileExists(atPath: fixture.destination.path),
                      "No torrent directory is created when none existed at first launch")
        }
    }

    static func retryChecks() throws {
        try withFixture { fixture in
            fixture.write(["setting": "legacy"], SPBrandMigration.legacyIdentifier)
            try fixture.makeSource()
            try Data([1]).write(to: fixture.source.appendingPathComponent("metadata.torrent"))
            let blocked = fixture.root.appendingPathComponent(SPBrandMigration.currentIdentifier)
            try Data([8]).write(to: blocked)
            try expectFailure("A blocked destination must fail without completing") { _ = try fixture.run() }
            try check(fixture.current[SPBrandMigration.completionKey] == nil,
                      "File-copy failure does not mark completion")
            try check(fixture.current["setting"] as? String == "legacy", "Successful preference imports survive file failure")
            var changed = fixture.current
            changed["setting"] = "changedAfterFailure"
            fixture.write(changed, SPBrandMigration.currentIdentifier)
            try FileManager.default.removeItem(at: blocked)
            try check(fixture.run() == .completed, "Next launch retries unfinished metadata migration")
            try check(fixture.current["setting"] as? String == "changedAfterFailure",
                      "A retry preserves preferences changed after the first attempt")
            try check(Data(contentsOf: fixture.destination.appendingPathComponent("metadata.torrent")) == Data([1]),
                      "Retry copies previously blocked metadata")
        }
        try withFixture { fixture in
            fixture.write(["copy": 1], SPBrandMigration.legacyIdentifier)
            try expectFailure("Preference failure must be retryable") { _ = try fixture.run(failWrites: true) }
            try check(fixture.current.isEmpty, "Failed preference writes do not mark completion")
            try check(fixture.run() == .completed, "Preference write failure can be retried")
            try check(fixture.current["copy"] as? Int == 1, "Retry imports preferences")
        }
        try withFixture { fixture in
            try fixture.makeSource()
            try Data([1]).write(to: fixture.source.appendingPathComponent("metadata.torrent"))
            try expectFailure("Completion write failure must remain retryable") { _ = try fixture.run(failCompletion: true) }
            try check(fixture.current[SPBrandMigration.completionKey] == nil, "Failed marker write does not mark completion")
            try Data([9]).write(to: fixture.destination.appendingPathComponent("metadata.torrent"))
            try check(fixture.run() == .completed, "Retry can complete after files were copied")
            try check(Data(contentsOf: fixture.destination.appendingPathComponent("metadata.torrent")) == Data([9]),
                      "Retry never replaces an already present destination file")
        }
    }

    static func originalApplicationChecks() throws {
        try withFixture { fixture in
            fixture.write(["originalOnly": 1], fixture.originalIdentifier)
            fixture.write(["developmentOnly": 2], SPBrandMigration.legacyIdentifier)
            let originalData = fixture.domain(fixture.originalIdentifier)
            fixture.reads = []; fixture.writes = []
            try check(fixture.run(identifier: fixture.originalIdentifier) == .notApplicable,
                      "Original Khua application never triggers migration")
            try check(fixture.reads.isEmpty && fixture.writes.isEmpty,
                      "Non-target applications do not access any preference domain")
            try check(fixture.run(identifier: nil) == .notApplicable, "An unidentified process does not migrate")
            _ = try fixture.run()
            try check(!fixture.reads.contains(fixture.originalIdentifier), "Kinolet never reads the original Khua domain")
            try check(fixture.current["developmentOnly"] as? Int == 2 && fixture.current["originalOnly"] == nil,
                      "Only the custom SidebarDev domain is imported")
            try check(NSDictionary(dictionary: fixture.domain(fixture.originalIdentifier)).isEqual(to: originalData),
                      "Original Khua preferences stay unchanged")
        }
        try withFixture { fixture in
            fixture.write(["originalOnly": 1], fixture.originalIdentifier)
            _ = try fixture.run()
            try check(fixture.current["originalOnly"] == nil, "Original-domain data is not a fallback source")
            try check(fixture.current[SPBrandMigration.completionKey] as? Bool == true,
                      "A first launch without legacy data completes normally")
        }
    }

    static func fileBoundaryChecks() throws {
        try withFixture { fixture in
            try fixture.makeSource()
            let external = fixture.root.appendingPathComponent("external.torrent")
            try Data([7]).write(to: external)
            try FileManager.default.createSymbolicLink(at: fixture.source.appendingPathComponent("linked.torrent"),
                                                       withDestinationURL: external)
            try expectFailure("Migration must not follow a metadata symlink") { _ = try fixture.run() }
            try check(fixture.current[SPBrandMigration.completionKey] == nil,
                      "Unsafe file types remain retryable")
            try check(Data(contentsOf: external) == Data([7]), "Migration preserves external symlink targets")
            try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("linked.torrent"))
            try check(fixture.run() == .completed, "Removing a bad entry permits a later retry")
            let names = try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path)
            try check(!names.contains(where: { $0.hasPrefix(".kinolet-migrate-") }),
                      "Completed migration leaves no staging copies")
        }
    }
}

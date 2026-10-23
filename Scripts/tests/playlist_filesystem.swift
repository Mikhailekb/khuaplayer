import Foundation
import Darwin

@main @MainActor
struct PlaylistFilesystemChecks {
    static var checks = 0
    static func main() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("khua-playlist-" + UUID().uuidString, isDirectory: true)
        let root = fixture.appendingPathComponent("Show", isDirectory: true)
        let other = fixture.appendingPathComponent("Other", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let controller = SPPlaylistController(mediaExtensions: ["MP4", "mkv", "m4a"])
        defer { controller.stop() }
        var changes = 0
        var callbacksOnMain = true
        controller.onChange = { callbacksOnMain = callbacksOnMain && Thread.isMainThread; changes += 1 }
        check(SPPlaylistController.contains(root.appendingPathComponent("Season 2/E01.mp4"), in: root), "recursive path membership includes descendants")
        check(!SPPlaylistController.contains(fixture.appendingPathComponent("ShowBackup/E01.mp4"), in: root), "component membership rejects same-prefix sibling")
        check(!SPPlaylistController.contains(root.appendingPathComponent("../Other/E01.mp4"), in: root), "normalized membership rejects parent traversal")
        check(!SPPlaylistController.contains(root, in: root), "root directory itself is not a media member")
        try write(root.appendingPathComponent("E10.mp4"))
        try write(root.appendingPathComponent("E2.mp4"))
        try write(root.appendingPathComponent("E1.MP4"))
        try write(root.appendingPathComponent("ignored.txt"))
        try write(root.appendingPathComponent(".hidden.mp4"))
        try Data().write(to: root.appendingPathComponent("zero.mp4"))
        try write(root.appendingPathComponent("E3.part.mp4"))
        try write(root.appendingPathComponent("E4.mp4.crdownload"))
        try fm.createDirectory(at: root.appendingPathComponent("not-a-file.mp4"), withIntermediateDirectories: true)
        try write(root.appendingPathComponent("Season 2/E10.mp4"))
        try write(root.appendingPathComponent("Season 2/E2.mp4"))
        try write(root.appendingPathComponent("Season 2/E1.mp4"))
        try write(root.appendingPathComponent("Season 10/E1.mp4"))
        try write(root.appendingPathComponent(".hidden/E1.mp4"))
        try write(root.appendingPathComponent("FinderHidden/E1.mp4"))
        try write(root.appendingPathComponent("finder-hidden.mp4"))
        check(chflags(root.appendingPathComponent("FinderHidden").path, UInt32(UF_HIDDEN)) == 0 &&
              chflags(root.appendingPathComponent("finder-hidden.mp4").path, UInt32(UF_HIDDEN)) == 0,
              "fixture includes Finder-hidden directory and media file")
        try write(root.appendingPathComponent("Ignore.app/Contents/E1.mp4"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("linked.mp4"), withDestinationURL: root.appendingPathComponent("E1.MP4"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("Loop"), withDestinationURL: root)
        check(mkfifo(root.appendingPathComponent("pipe.mp4").path, 0o600) == 0, "fixture includes nonregular recognized-extension entry")
        controller.setRoot(root, recursive: false)
        check(controller.rootURL == root.standardizedFileURL && !controller.recursive && controller.isRefreshing,
              "setRoot immediately publishes root and refresh state")
        let initialRevision = controller.entriesRevision
        check(initialRevision > 0, "root replacement publishes a catalogue revision before scanning")
        check(wait(5) { !controller.isRefreshing && controller.entries.count == 3 }, "shallow scan ignores nested, hidden, zero, partial, symlink and nonregular entries")
        check(controller.entries.map(\.relativePath) == ["E1.MP4", "E2.mp4", "E10.mp4"], "shallow catalogue uses natural numeric order and case-insensitive extension filter")
        check(controller.error == nil && controller.entries.allSatisfy { !$0.isGrowing }, "first sight reports no fabricated growth or readiness")
        check(controller.contains(root.appendingPathComponent("E1.MP4")) && !controller.contains(root.appendingPathComponent("Season 2/E1.mp4")), "shallow instance membership retains only immediate siblings")
        controller.setRoot(root, recursive: true)
        let recursiveReady = wait(5) { !controller.isRefreshing && controller.entries.count == 7 }
        check(recursiveReady, "recursive scan includes season directories without entering packages or symlink cycles")
        check(controller.entries.map(\.relativePath) == ["E1.MP4", "E2.mp4", "E10.mp4", "Season 2/E1.mp4", "Season 2/E2.mp4", "Season 2/E10.mp4", "Season 10/E1.mp4"],
              "recursive natural order preserves episode and season number order")
        check(controller.contains(root.appendingPathComponent("Season 10/E1.mp4")), "controller root membership remains independent of immediate parent directory")
        spin(0.8)
        let live = root.appendingPathComponent("Season 2/E3.mp4")
        let liveStart = Date()
        try write(live)
        check(wait(5) { controller.entries.contains { $0.url == live } }, "native FSEvents adds a new descendant episode without explicit refresh")
        check(Date().timeIntervalSince(liveStart) < 5, "live add precedes ten-second fallback poll")
        let renamed = root.appendingPathComponent("Season 2/E4.mp4")
        try fm.moveItem(at: live, to: renamed)
        check(wait(5) { controller.entries.contains { $0.url == renamed } && !controller.entries.contains { $0.url == live } },
              "live rename replaces playlist identity and reorders naturally")
        try fm.removeItem(at: renamed)
        check(wait(5) { !controller.entries.contains { $0.url == renamed } }, "live delete removes an entry")

        let growing = root.appendingPathComponent("E2.mp4")
        spin(0.8)
        let handle = try FileHandle(forWritingTo: growing)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 2, count: 100))
        try handle.close()
        let beforeRefreshRevision = controller.entriesRevision
        controller.refresh()
        check(controller.entriesRevision == beforeRefreshRevision, "refresh start preserves the published catalogue revision")
        check(wait(5) { !controller.isRefreshing && controller.entries.first { $0.url == growing }?.isGrowing == true },
              "larger size since last successful snapshot is reported as informational growth")
        check(controller.entriesRevision > beforeRefreshRevision, "successful snapshot advances catalogue revision")
        controller.refresh()
        check(wait(5) { !controller.isRefreshing && controller.entries.first { $0.url == growing }?.isGrowing == false },
              "next stable-size snapshot clears growth without claiming file completion")
        let beforeFailure = controller.entries
        let moved = fixture.appendingPathComponent("TemporarilyMoved", isDirectory: true)
        try fm.moveItem(at: root, to: moved)
        controller.refresh()
        check(wait(5) { !controller.isRefreshing && controller.error != nil }, "inaccessible root exposes scan error")
        check(controller.entries == beforeFailure, "inaccessible root preserves last good catalogue")
        try fm.moveItem(at: moved, to: root)
        controller.refresh()
        check(wait(5) { !controller.isRefreshing && controller.error == nil }, "restored root recovers without replacing controller")

        try write(other.appendingPathComponent("Only.m4a"))
        SPBackgroundStorageGate.noteForegroundActivity(quietPeriod: 0.7)
        controller.refresh()
        controller.setRoot(other, recursive: false)
        check(wait(5) { !controller.isRefreshing && controller.entries.map(\.relativePath) == ["Only.m4a"] },
              "root generation rejects cancelled old-root publication while foreground storage gate yields")
        spin(0.8)
        check(controller.rootURL == other.standardizedFileURL && controller.entries.map(\.relativePath) == ["Only.m4a"],
              "late old-root callbacks cannot restore former catalogue")
        let empty = fixture.appendingPathComponent("Empty", isDirectory: true)
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        controller.setRoot(empty, recursive: true)
        check(wait(5) { !controller.isRefreshing && controller.error == nil }, "empty root completes successfully")
        check(controller.entries.isEmpty, "empty snapshot is a usable empty catalogue")
        spin(1.2)
        let beforeFallback = changes
        check(wait(12) { changes >= beforeFallback + 2 && !controller.isRefreshing }, "ten-second fallback refreshes an idle root without filesystem events")
        let beforeStopRevision = controller.entriesRevision
        controller.stop()
        let stoppedChanges = changes
        try write(empty.appendingPathComponent("Late.mp4"))
        spin(1.3)
        check(controller.rootURL == nil && controller.entries.isEmpty && !controller.isRefreshing && controller.error == nil,
              "stop releases active root and catalogue")
        check(controller.entriesRevision > beforeStopRevision, "stop advances catalogue revision when clearing entries")
        check(changes == stoppedChanges, "stopped watcher and delayed callbacks publish no further changes")
        check(callbacksOnMain, "all change callbacks remain on main thread")
        print("Playlist filesystem checks passed (\(checks) assertions; native FSEvents and fallback timer).")
    }
    static func write(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 20).write(to: url)
    }
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { print("RESULT FAIL: \(message)"); fflush(stdout); exit(1) }
        checks += 1
        print("PASS \(checks): \(message)"); fflush(stdout)
    }
    static func spin(_ seconds: TimeInterval) { _ = wait(seconds) { false } }
    static func wait(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.005)))
        }
        return condition()
    }
}

// Diagnostic logging only; the production index and storage gate compile unchanged.
let spDebugEnabled = false

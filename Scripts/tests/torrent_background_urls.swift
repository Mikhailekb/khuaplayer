import Foundation

private enum SPTorrentServerError: Error { case invalidLease, invalidResponse, invalidFile }
private struct SPTorrentDescriptor { let hash = String(repeating: "a", count: 40); let leaseID: UUID }
private struct SPTorrentFile { let id: Int }
@MainActor private final class Server {
    struct Process { var isRunning = true }
    struct Worker { var process = Process(); var generation: UInt64 = 1 }
    struct Retired: Equatable { let hash: String; let consumer: String; let parent: String; let remove: Bool; let generation: UInt64 }
    var worker: Worker? = Worker()
    var leaseHashes: [UUID: String] = [:]
    var retired: [Retired] = []
    var primary: URL {
        URL(string: "http://owned-user:owned-secret@127.0.0.1:8123/stream/owned.mkv?link=" + String(repeating: "a", count: 40) +
            "&index=7&play=&playback_prefetch=1&playback_prefetch_request=stale")!
    }
    func streamURL(hash: String, file: SPTorrentFile, playbackConsumer: UUID?) throws -> URL {
        guard let worker, worker.process.isRunning else { throw SPTorrentServerError.invalidLease }
        guard file.id == 7 else { throw SPTorrentServerError.invalidFile }
        var parts = URLComponents(url: primary, resolvingAgainstBaseURL: false)!
        if let playbackConsumer { parts.queryItems?.append(.init(name: "playback_consumer", value: playbackConsumer.uuidString)) }
        return parts.url!
    }
    private func jsonRequest(path: String, body: [String: Any], expectedGeneration: UInt64) async throws -> Bool {
        guard worker?.generation == expectedGeneration else { throw CancellationError() }
        precondition(path == "/playback/background")
        retired.append(Retired(hash: body["hash"] as! String, consumer: body["consumer"] as! String,
            parent: body["parent"] as! String, remove: body["remove"] as! Bool, generation: expectedGeneration))
        return true
    }
    // INSERT_METHODS
}

@main @MainActor private struct BackgroundURLChecks {
    static var count = 0
    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message); count += 1
    }
    static func rejected(_ action: () throws -> URL) -> Bool { do { _ = try action(); return false } catch { return true } }
    static func settle() async { try? await Task.sleep(for: .milliseconds(20)) }
    static func main() async throws {
        let server = Server(), parent = UUID(), first = UUID(), second = UUID()
        let descriptor = SPTorrentDescriptor(leaseID: parent), file = SPTorrentFile(id: 7)
        server.leaseHashes[parent] = descriptor.hash
        let before = server.primary
        let url = try server.backgroundStreamURL(descriptor, file: file, consumer: first)
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let values = Dictionary(uniqueKeysWithValues: parts.queryItems!.map { ($0.name, $0.value ?? "") })
        check(server.primary == before, "Background URL derivation never mutates the primary stream")
        check(values["playback_consumer"] == first.uuidString && values["playback_consumer"] != parent.uuidString,
              "A background job has a distinct consumer identity")
        check(values["playback_background"] == "1" && values["playback_parent"] == parent.uuidString,
              "The job carries the exact bounded worker role and parent consumer")
        check(values["playback_prefetch"] == nil && values["playback_prefetch_request"] == nil,
              "A background job cannot inherit primary prefetch authorization")
        check(values["link"] == descriptor.hash && values["index"] == "7" && values["play"] == "",
              "The torrent and selected file identity remain unchanged")
        let original = URLComponents(url: before, resolvingAgainstBaseURL: false)!
        check(parts.scheme == original.scheme && parts.host == original.host && parts.port == original.port &&
              parts.path == original.path && parts.user == original.user && parts.password == original.password,
              "The private endpoint, media path and in-memory authentication are preserved")
        let other = try server.backgroundStreamURL(descriptor, file: file, consumer: second)
        check(other != url, "Subtitles and previews can use distinct per-job URLs")
        check(rejected { try server.backgroundStreamURL(descriptor, file: file, consumer: parent) },
              "The primary consumer cannot be reused as a background job")
        check(rejected { try server.backgroundStreamURL(SPTorrentDescriptor(leaseID: UUID()), file: file, consumer: first) },
              "A stale descriptor lease cannot create a background URL")
        check(rejected { try server.backgroundStreamURL(descriptor, file: .init(id: 8), consumer: first) },
              "Existing stream validation still rejects another file")
        server.worker?.process.isRunning = false
        check(rejected { try server.backgroundStreamURL(descriptor, file: file, consumer: first) },
              "A stopped worker cannot create a usable background URL")
        server.worker?.process.isRunning = true
        server.endBackgroundStream(descriptor, consumer: first); await settle()
        check(server.retired == [.init(hash: descriptor.hash, consumer: first.uuidString, parent: parent.uuidString,
                                      remove: true, generation: 1)], "Cleanup targets only the exact job and original worker generation")
        server.endBackgroundStream(descriptor, consumer: first); await settle()
        check(server.retired.count == 2 && server.retired[0] == server.retired[1], "Repeated cleanup has an identical idempotent request body")
        server.endBackgroundStream(descriptor, consumer: parent)
        server.endBackgroundStream(.init(leaseID: UUID()), consumer: second); await settle()
        check(server.retired.count == 2, "Cleanup rejects primary consumers and obsolete leases")
        server.endBackgroundStream(descriptor, consumer: second)
        server.worker?.generation = 2; await settle()
        check(server.retired.count == 2, "A queued cleanup cannot cross a worker replacement")
        print("PASS: \(count) actual torrent background URL checks")
    }
}

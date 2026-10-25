import Foundation

/// Exercise the production Swift manager and actual worker without joining a swarm.
@main @MainActor
struct TorrentWorkerStartupCheck {
    static func main() async {
        setbuf(stdout, nil)
        guard CommandLine.arguments.count == 2 else {
            print("FAIL: pass the app bundle or bundled torrent worker executable")
            exit(2)
        }
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let worker: URL
        if input.pathExtension == "app" {
            guard let app = Bundle(url: input),
                  let bundledWorker = app.url(forResource: "TorrServer", withExtension: nil, subdirectory: "Torrent") else {
                print("FAIL: the app bundle cannot resolve its torrent worker resource")
                exit(1)
            }
            worker = bundledWorker
            print("PASS: worker resolved through the app bundle resource lookup")
        } else {
            worker = input
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinolet-real-worker-check-" + UUID().uuidString, isDirectory: true)
        let server = SPTorrentServer(workerURL: worker, temporaryDirectory: scratch,
                                    metadataTimeout: 3, idleTimeout: 30,
                                    peerDiscoveryEnabled: false,
                                    settingsProvider: { SPTorrentConfiguration() },
                                    notifications: NotificationCenter())
        let started = ProcessInfo.processInfo.systemUptime
        var failure: (any Error)?
        do {
            // This one-byte synthetic media entry supplies metadata locally.
            // No tracker or peer is needed, and no media playback is started.
            var metainfo = Data("d4:infod6:lengthi1e4:name9:probe.mkv12:piece lengthi16384e6:pieces20:".utf8)
            metainfo.append(Data(repeating: 0, count: 20))
            metainfo.append(Data("ee".utf8))
            let descriptor = try await server.add(torrentData: metainfo)
            guard server.isRunning, descriptor.files.count == 1,
                  descriptor.files[0].displayName == "probe.mkv", descriptor.files[0].length == 1,
                  server.activeTorrentCount == 1 else {
                throw SPTorrentServerError.invalidResponse
            }
            let status = try await server.status(hash: descriptor.hash)
            guard status.hash == descriptor.hash, status.files == descriptor.files else {
                throw SPTorrentServerError.invalidResponse
            }
            print("PASS: actual worker handshake, authenticated metainfo upload, descriptor and status")
            let cached = try await server.cacheSnapshot(descriptor, file: descriptor.files[0])
            guard cached.fileID == descriptor.files[0].id, cached.fileOffset == 0,
                  cached.fileLength == 1, cached.pieceLength == 16384,
                  cached.residentBytes == 0, cached.ranges.isEmpty else {
                throw SPTorrentServerError.invalidResponse
            }
            print("PASS: authenticated current-file cache snapshot reports no fabricated payload")
            // Exercise the shipped route with its real authentication and
            // revision ordering. This independent consumer has no media reader
            // and cannot allocate or download payload from a swarm.
            let file = descriptor.files[0]
            let stream = try server.streamURL(hash: descriptor.hash, file: file)
            guard var endpoint = URLComponents(url: stream, resolvingAgainstBaseURL: false),
                  let user = endpoint.user, let password = endpoint.password else {
                throw SPTorrentServerError.invalidResponse
            }
            endpoint.user = nil
            endpoint.password = nil
            endpoint.path = "/playback/window"
            endpoint.queryItems = nil
            guard let windowURL = endpoint.url else { throw SPTorrentServerError.invalidResponse }
            let consumer = UUID().uuidString
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            let protocolSession = URLSession(configuration: configuration)
            defer { protocolSession.invalidateAndCancel() }
            func command(_ fields: [String: Any], status expectedStatus: Int = 200) async throws -> [String: Any] {
                var body = fields
                body["hash"] = descriptor.hash
                body["consumer"] = consumer
                var request = URLRequest(url: windowURL)
                request.httpMethod = "POST"
                request.timeoutInterval = 3
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Basic " + Data((user + ":" + password).utf8).base64EncodedString(),
                                 forHTTPHeaderField: "Authorization")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await protocolSession.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == expectedStatus else {
                    throw SPTorrentServerError.invalidResponse
                }
                if expectedStatus != 200 { return [:] }
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw SPTorrentServerError.invalidResponse
                }
                return object
            }
            _ = try await command(["file_index": file.id, "revision": 1, "lower": 0, "current": 0, "upper": 1])
            let seeking = try await command(["file_index": file.id, "revision": 2, "seeking": true])
            guard seeking["seeking"] as? Bool == true, (seeking["revision"] as? NSNumber)?.intValue == 2 else {
                throw SPTorrentServerError.invalidResponse
            }
            let settled = try await command(["file_index": file.id, "revision": 3, "lower": 0, "current": 0, "upper": 1])
            guard (settled["revision"] as? NSNumber)?.intValue == 3, settled["seeking"] as? Bool != true else {
                throw SPTorrentServerError.invalidResponse
            }
            _ = try await command(["file_index": file.id, "revision": 2, "seeking": true], status: 409)
            _ = try await command(["revision": 4, "remove": true])
            _ = try await command(["file_index": file.id, "revision": 3, "seeking": true], status: 409)
            print("PASS: shipped seek handover, settled replacement and stale revision rejection")
            print("Expected worker: \(SPTorrentServer.workerVersion)")
            print(String(format: "Startup and metadata elapsed: %.3f s", ProcessInfo.processInfo.systemUptime - started))
            server.release(descriptor)
        } catch {
            failure = error
            print("FAIL: \(error.localizedDescription)")
            print("Expected worker: \(SPTorrentServer.workerVersion)")
            print(String(format: "Failure elapsed: %.3f s", ProcessInfo.processInfo.systemUptime - started))
        }
        // Only this manager's private child is terminated; wait for its state
        // directory to be removed before the harness process can exit.
        server.shutdown()
        do { try await server.prepareForCacheRestart(timeout: 10) }
        catch { failure = failure ?? error; print("FAIL: owned worker cleanup: \(error.localizedDescription)") }
        let contents = (try? FileManager.default.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil)) ?? []
        if !contents.isEmpty {
            print("FAIL: owned worker state remains after shutdown")
            exit(1)
        }
        try? FileManager.default.removeItem(at: scratch)
        print("PASS: owned worker stopped and private state removed")
        exit(failure == nil ? 0 : 1)
    }
}

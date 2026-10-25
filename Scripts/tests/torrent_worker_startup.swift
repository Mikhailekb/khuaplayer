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

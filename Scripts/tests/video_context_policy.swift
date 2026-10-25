import Foundation

@main @MainActor
struct VideoContextPolicyChecks {
    private static var checks = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { print("FAIL: \(message)"); exit(1) }
        checks += 1
    }

    private static func canRepeat(torrent: Bool = false, position: Double = 120,
                                  duration: Double = 120, growing: Bool = false,
                                  waiting: Bool = false, stalled: Bool = false,
                                  index: Bool = false, availableEnd: Double = -1) -> Bool {
        SPVideoContextPolicy.canRepeatEnded(isTorrent: torrent, position: position, duration: duration,
                                            growing: growing, waiting: waiting, stalled: stalled,
                                            waitingForIndex: index, availableEnd: availableEnd)
    }

    static func main() {
        let hash = "0123456789abcdef0123456789abcdef01234567"
        let worker = "http://khua:private-password@127.0.0.1:54321/stream/episode.mkv?token=private-token"
        let name = "Серия 1 & token=not-a-query.mkv"
        let torrent = SPVideoContextPolicy.sharingURL(localPath: worker, torrentHash: hash.uppercased(), torrentName: name)!
        let magnet = URLComponents(url: torrent, resolvingAgainstBaseURL: false)!
        check(magnet.scheme == "magnet" && magnet.host == nil && magnet.user == nil && magnet.password == nil,
              "A torrent is shared as a public source identity without an HTTP host or credentials")
        check(magnet.queryItems == [URLQueryItem(name: "xt", value: "urn:btih:" + hash),
                                   URLQueryItem(name: "dn", value: name)],
              "Only the canonical infohash and safely encoded display name enter the magnet")
        check(!torrent.absoluteString.contains("private-password") && !torrent.absoluteString.contains("private-token") &&
              !torrent.absoluteString.contains("127.0.0.1"), "Private stream authentication never leaves the player")
        check(magnet.queryItems?.count == 2, "A display name cannot inject additional magnet parameters")

        for name: String? in [nil, "", " \n\t"] {
            let url = SPVideoContextPolicy.sharingURL(localPath: nil, torrentHash: hash, torrentName: name)!
            check(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ==
                    [URLQueryItem(name: "xt", value: "urn:btih:" + hash)],
                  "An absent display name produces a minimal magnet")
        }
        for invalid in ["", String(hash.dropLast()), hash + "0", "g" + hash.dropFirst(), hash + "\n",
                        "magnet:?xt=urn:btih:" + hash, String(repeating: "Ａ", count: 40)] {
            check(SPVideoContextPolicy.sharingURL(localPath: "/tmp/public.mkv", torrentHash: invalid,
                                                  torrentName: name) == nil,
                  "Invalid torrent identity cannot fall back to a private or unrelated source")
        }

        let path = "/tmp/My video #1 & 100%.mkv"
        let local = SPVideoContextPolicy.sharingURL(localPath: path, torrentHash: nil, torrentName: nil)!
        check(local.isFileURL && local.path == path, "A local source keeps its exact filesystem path")
        for invalid: String? in [nil, "", "episode.mkv", "~/Movies/episode.mkv", "file:///tmp/episode.mkv", worker,
                                "/tmp/invalid\0.mkv"] {
            check(SPVideoContextPolicy.sharingURL(localPath: invalid, torrentHash: nil, torrentName: nil) == nil,
                  "Only absolute filesystem paths are shared as local files")
        }

        check(canRepeat(), "A completed local video may repeat")
        check(canRepeat(position: 119), "The existing one-second end tolerance is retained")
        check(!canRepeat(position: 118.9), "An early stopped video does not repeat")
        check(!canRepeat(growing: true), "A growing local prefix does not restart")
        check(!canRepeat(waiting: true), "Waiting for missing bytes does not trigger repeat")
        check(!canRepeat(stalled: true), "A stalled source does not trigger repeat")
        check(!canRepeat(index: true), "A missing local index does not trigger repeat")
        check(!canRepeat(availableEnd: 120), "A finite available-prefix boundary is not a complete local file")
        check(!canRepeat(availableEnd: .nan), "An unknown local prefix boundary is not mistaken for complete data")
        for duration in [0, -1, Double.nan, Double.infinity, -Double.infinity] {
            check(!canRepeat(duration: duration), "Invalid duration cannot cause a replay loop")
        }
        for position in [Double.nan, Double.infinity, -Double.infinity] {
            check(!canRepeat(position: position), "Invalid playback position cannot cause a replay loop")
        }
        check(canRepeat(torrent: true, growing: true, index: true, availableEnd: 120),
              "A complete streamed ending uses torrent guards independently of local growing-file flags")
        check(!canRepeat(torrent: true, waiting: true), "Torrent buffering remains distinct from completion")
        check(!canRepeat(torrent: true, stalled: true), "A stalled torrent does not restart its available prefix")
        check(!canRepeat(torrent: true, position: 60), "Torrent metadata alone cannot turn an early EOF into completion")
        print("Video context policy checks passed (\(checks) assertions).")
    }
}

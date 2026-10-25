import AppKit

@MainActor
private final class ContextMenuTarget: NSObject, SPVideoContextMenuActions {
    private(set) var performed: [String] = []
    func videoRepeatAction(_ sender: NSMenuItem) { performed.append("repeat") }
    func videoPictureInPictureAction(_ sender: NSMenuItem) { performed.append("pictureInPicture") }
    func videoCopyFrameAction(_ sender: NSMenuItem) { performed.append("copyFrame") }
    func videoInfoAction(_ sender: NSMenuItem) { performed.append("info") }
    func videoShareAction(_ sender: NSMenuItem) { performed.append("share") }
}

@main @MainActor
struct VideoContextMenuChecks {
    private static var checks = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { print("FAIL: \(message)"); exit(1) }
        checks += 1
    }

    static func main() {
        let target = ContextMenuTarget()
        let menu = SPVideoContextMenu.make(target: target, hasVideo: true,
                                          isRepeating: true, isPictureInPicture: false,
                                          canShare: true)
        let items = menu.items.filter { !$0.isSeparatorItem }
        let identifiers = ["sp.video.repeat", "sp.video.pictureInPicture", "sp.video.copyFrame",
                           "sp.video.info", "sp.video.share"]
        let selectors = [#selector(SPVideoContextMenuActions.videoRepeatAction(_:)),
                         #selector(SPVideoContextMenuActions.videoPictureInPictureAction(_:)),
                         #selector(SPVideoContextMenuActions.videoCopyFrameAction(_:)),
                         #selector(SPVideoContextMenuActions.videoInfoAction(_:)),
                         #selector(SPVideoContextMenuActions.videoShareAction(_:))]
        check(!menu.autoenablesItems, "Explicit state is not overridden by responder validation")
        check(menu.items.count == 7 && items.count == 5, "Exactly five actions and two separators appear")
        check(menu.items[2].isSeparatorItem && menu.items[5].isSeparatorItem,
              "Playback, frame information and sharing retain their ordering")
        check(items.compactMap { $0.identifier?.rawValue } == identifiers, "Actions follow the requested order")
        check(items.map { $0.title } == ["video.context.repeat", "video.context.pictureInPicture",
                                        "video.context.copyFrame", "video.context.info", "video.context.share"].map { L($0) },
              "Every action uses its localized title")
        for (index, item) in items.enumerated() {
            check(item.target === target && item.action == selectors[index], "Action \(index) routes to its explicit target")
            check(item.isEnabled && item.keyEquivalent.isEmpty, "Action \(index) is enabled without stealing a shortcut")
            check(item.image != nil, "Action \(index) has its native symbol")
            _ = target.perform(selectors[index], with: item)
        }
        check(target.performed == ["repeat", "pictureInPicture", "copyFrame", "info", "share"],
              "Menu callbacks remain separate and invoke their intended actions")
        check(items[0].state == .on && items[1].state == .off,
              "Repeat and picture-in-picture reflect independent current states")
        check(items.dropFirst(2).allSatisfy { $0.state == .off }, "One-shot actions never acquire checkmarks")

        let activePIP = SPVideoContextMenu.make(target: target, hasVideo: true,
                                               isRepeating: false, isPictureInPicture: true,
                                               canShare: false).items.filter { !$0.isSeparatorItem }
        check(activePIP[0].state == .off && activePIP[1].state == .on,
              "Rebuilding after a mode change reflects current playback state")
        check(activePIP[1].title == items[1].title, "The picture-in-picture toggle keeps its recognizable title")
        check(activePIP.prefix(4).allSatisfy(\.isEnabled) && !activePIP[4].isEnabled,
              "A missing share source does not disable unrelated video actions")

        let unavailable = SPVideoContextMenu.make(target: target, hasVideo: false,
                                                 isRepeating: false, isPictureInPicture: false,
                                                 canShare: false).items.filter { !$0.isSeparatorItem }
        check(unavailable.allSatisfy { !$0.isEnabled && $0.state == .off },
              "An unavailable video cannot trigger stale actions")
        let shareOnly = SPVideoContextMenu.make(target: target, hasVideo: false,
                                               isRepeating: false, isPictureInPicture: false,
                                               canShare: true).items.filter { !$0.isSeparatorItem }
        check(shareOnly.prefix(4).allSatisfy { !$0.isEnabled } && shareOnly[4].isEnabled,
              "A valid share source remains shareable independently of decoded video")
        print("Video context menu checks passed (\(checks) assertions).")
    }
}

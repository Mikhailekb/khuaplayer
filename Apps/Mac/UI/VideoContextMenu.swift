import AppKit

@MainActor
@objc protocol SPVideoContextMenuActions: AnyObject {
    func videoRepeatAction(_ sender: NSMenuItem)
    func videoPictureInPictureAction(_ sender: NSMenuItem)
    func videoCopyFrameAction(_ sender: NSMenuItem)
    func videoInfoAction(_ sender: NSMenuItem)
    func videoShareAction(_ sender: NSMenuItem)
}

/// The video surface owns this menu; playback controls retain their own input.
@MainActor
enum SPVideoContextMenu {
    static func make(target: any SPVideoContextMenuActions, hasVideo: Bool,
                     isRepeating: Bool, isPictureInPicture: Bool,
                     canShare: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        func item(_ title: String, id: String, symbol: String, action: Selector,
                  enabled: Bool, selected: Bool = false) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(id)
            item.target = target
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.isEnabled = enabled
            item.state = selected ? .on : .off
            return item
        }

        menu.addItem(item(L("video.context.repeat"), id: "sp.video.repeat", symbol: "repeat",
                          action: #selector(SPVideoContextMenuActions.videoRepeatAction(_:)),
                          enabled: hasVideo, selected: isRepeating))
        menu.addItem(item(L("video.context.pictureInPicture"), id: "sp.video.pictureInPicture", symbol: "pip.enter",
                          action: #selector(SPVideoContextMenuActions.videoPictureInPictureAction(_:)),
                          enabled: hasVideo, selected: isPictureInPicture))
        menu.addItem(.separator())
        menu.addItem(item(L("video.context.copyFrame"), id: "sp.video.copyFrame", symbol: "doc.on.clipboard",
                          action: #selector(SPVideoContextMenuActions.videoCopyFrameAction(_:)),
                          enabled: hasVideo))
        menu.addItem(item(L("video.context.info"), id: "sp.video.info", symbol: "info.circle",
                          action: #selector(SPVideoContextMenuActions.videoInfoAction(_:)),
                          enabled: hasVideo))
        menu.addItem(.separator())
        menu.addItem(item(L("video.context.share"), id: "sp.video.share", symbol: "square.and.arrow.up",
                          action: #selector(SPVideoContextMenuActions.videoShareAction(_:)),
                          enabled: canShare))
        return menu
    }
}

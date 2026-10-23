import Foundation

enum SPSettingsTab: Int, CaseIterable {
    case layout, video, audio, subtitles
}

struct SPSettingsTrack: Equatable {
    var id: String
    var title: String
}

struct SPSettingsLayout {
    let video: CGRect
    let menu: CGRect

    init(bounds: CGRect, topInset: CGFloat, shown: Bool,
         preferredMenuSize: CGSize = CGSize(width: 380, height: 368), anchor: CGRect? = nil) {
        // The menu overlays the picture; opening it never changes the viewport.
        video = bounds
        guard shown else { menu = .zero; return }
        let margin: CGFloat = 12
        let width = min(preferredMenuSize.width, max(0, bounds.width - margin * 2))
        let top = max(bounds.minY + margin, bounds.maxY - topInset - margin)
        let bottom = min(top, max(bounds.minY + margin, (anchor?.maxY ?? bounds.minY + 92) + 8))
        let height = min(preferredMenuSize.height, max(0, top - bottom))
        let trailing = min(bounds.maxX - margin, anchor.map { $0.maxX + 8 } ?? bounds.maxX - margin)
        menu = CGRect(x: max(bounds.minX + margin, trailing - width), y: bottom,
                      width: width, height: height).integral
    }
}

/// A value snapshot keeps the inspector independent of decoder callbacks.
struct SPSettingsSnapshot: Equatable {
    var hasMedia = false
    var hasVideo = false
    var picture = SPColorAdjust()
    var hueAvailable = true
    var hdrBrightRoomAvailable = false
    var hdrBrightRoomEnabled = true
    var xdrAvailable = false
    var xdrEnabled = false
    var xdrReason = ""
    var videoSummary = ""
    var resolutionBadge = ""
    var dynamicRange = ""
    var decoder = ""
    var forcedAspect = 0
    var crop = 0
    var rotation = 0
    var mirror = 0
    var rate = 1.0
    var volume = 100.0
    var muted = false
    var audioTracks: [SPSettingsTrack] = []
    var selectedAudio = ""
    var subtitleTracks: [SPSettingsTrack] = []
    var selectedSubtitle = "off"
    var subtitleScale = 1.0
    var timeline = 0
    var horizontalSeek = true
    var verticalVolume = true
    var pinch = 0
    var seekSensitivity = 1.0
    var fullscreen = false
}

enum SPSettingsAction {
    case picture(SPColorAdjust.Field, Double)
    case resetPicture(SPColorAdjust.Field)
    case resetAllPicture
    case hdrBrightRoom(Bool)
    case xdr(Bool)
    case forcedAspect(Int)
    case crop(Int)
    case rotation(Int)
    case mirror(Int)
    case rate(Double)
    case volume(Double)
    case muted(Bool)
    case audioTrack(String)
    case subtitleTrack(String)
    case loadSubtitle
    case subtitleScale(Double)
    case timeline(Int)
    case horizontalSeek(Bool)
    case verticalVolume(Bool)
    case pinch(Int)
    case seekSensitivity(Double)
    case fullscreen
    case fitWindow
    case mediaInfo
    case torrentSettings
}

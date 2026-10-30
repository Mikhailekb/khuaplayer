import Foundation

private enum SPFixtureState { case opening, ready, playing, paused, ended }
private enum SPFrameInterpolationMode: Int { case off, doubleRate }
@MainActor private final class SPFixtureCore {
    var state: SPFixtureState = .opening
    var audioTrackList: [Any] = []
    var subtitleTrackList: [Any] = []
    var currentAudioTrackIndex = 0
    var currentSubtitleTrackIndex = -1
    var frameInterpolationMode: SPFrameInterpolationMode = .off
    var xdrEnabled = false
    var audioSelections: [Int] = []
    var subtitleSelections: [Int] = []
    func selectAudioTrack(at index: Int) { currentAudioTrackIndex = index; audioSelections.append(index) }
    func selectSubtitleTrack(at index: Int) { currentSubtitleTrackIndex = index; subtitleSelections.append(index) }
    func setForcedAspect(_ value: Double) {}
    func setCropAspect(_ value: Double) {}
    func setRotation(_ value: Int) {}
    func setMirror(_ value: Int) {}
}
private struct SPFixtureFile { let id: Int }
private struct SPFixtureTorrentContext {
    var rootURL: URL
    var playableFiles: [SPFixtureFile] = [.init(id: 1), .init(id: 2), .init(id: 3)]
    var file = SPFixtureFile(id: 1)
    func identityURL(for file: SPFixtureFile) -> URL { rootURL.appendingPathComponent("Season 1/E\(file.id).mp4") }
    var identityURL: URL { identityURL(for: file) }
}
@MainActor private final class SPFixturePlaylist {
    var stops = 0
    func stop() { stops += 1 }
}
private enum SPPlaylistController {
    static func contains(_ url: URL, in root: URL) -> Bool {
        guard url.isFileURL, root.isFileURL else { return false }
        let child = url.standardizedFileURL.pathComponents, parent = root.standardizedFileURL.pathComponents
        return child.count > parent.count && child.starts(with: parent)
    }
}
@MainActor private final class SPFixtureOwner {
    var core: SPFixtureCore? = SPFixtureCore()
    var fixtureStore: SPPlaylistPreferencesStore
    var playlistProfileRoot: URL?
    var playlistProfile = SPPlaylistProfile()
    var playlistProfileRestorePending = false
    var playlistInitialOpenPending = false
    var playlistAdvanceAfterScanPath: String?
    var playlistController = SPFixturePlaylist()
    var torrentContext: SPFixtureTorrentContext?
    var mediaList: [URL] = []
    var currentMediaIndex = -1
    var hasMediaSession = true
    var hasVideoSession = true
    var pictureAdjustment = SPColorAdjust()
    var currentForcedAspectTag = 0, currentCropTag = 0, currentRotation = 0, currentMirror = 0
    var userTouchedSubtitleSelection = false
    var lastQuickSubtitleID: String?
    var torrentSubtitleBackgroundSuppressed = false
    var foregroundYields = 0, subtitleJobCancels = 0, policyCancels = 0, policyStarts = 0, pauseCancels = 0
    var playbackIdentityURL: URL? { torrentContext?.identityURL }
    init(store: SPPlaylistPreferencesStore, root: URL) {
        fixtureStore = store
        torrentContext = SPFixtureTorrentContext(rootURL: root)
        prepareTorrentPlaylist()
    }
    func yieldDirectoryScanToForegroundIO() { foregroundYields += 1 }
    func cancelTorrentSubtitleBackgroundJob() { subtitleJobCancels += 1 }
    func pauseTorrentBackgroundJobsForSeek() {}
    func cancelTorrentPauseBuffer() { pauseCancels += 1 }
    func cancelTorrentPlaybackWindowPolicy() { policyCancels += 1 }
    func startTorrentPlaybackWindowPolicyIfNeeded() { policyStarts += 1 }
    func applyHDRViewingPreference() {}
    func applyColorAdjust(_ field: SPColorAdjust.Field?) {}
    func refreshPlaybackSettings() {}
    func refreshPlaylistView() {}
    func restore() { restorePlaylistProfileIfReady() }
    func save() { savePlaylistProfile() }
    func prepare() { prepareTorrentPlaylist() }
    func invalidSelection() { rememberPlaylistAudioSelection(999); rememberPlaylistSubtitleSelection(999) }
    func ready() { core!.state = .playing; restorePlaylistProfileIfReady() }
    func selectAudio(_ index: Int) { rememberPlaylistAudioSelection(index); core!.selectAudioTrack(at: index); savePlaylistProfile() }
    func selectSubtitle(_ index: Int) { rememberPlaylistSubtitleSelection(index); core!.selectSubtitleTrack(at: index); savePlaylistProfile() }
    func next(audio: [[String: Any]], subtitles: [[String: Any]], defaultAudio: Int, defaultSubtitle: Int) {
        savePlaylistProfile()
        core!.state = .opening
        torrentContext!.file = .init(id: torrentContext!.file.id + 1)
        core!.audioTrackList = audio; core!.subtitleTrackList = subtitles
        core!.currentAudioTrackIndex = defaultAudio; core!.currentSubtitleTrackIndex = defaultSubtitle
        userTouchedSubtitleSelection = false; lastQuickSubtitleID = nil
        prepareTorrentPlaylist()
    }
    // INSERT_PRODUCTION_METHODS
}

@main @MainActor private enum SPPlaylistTrackChecks {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { print("FAIL: \(message)"); exit(1) }
    }
    static func audio(_ index: Int, _ name: String, _ language: String = "rus", _ codec: String = "ac3") -> [String: Any] {
        ["index": index, "rawTitle": name, "title": name, "language": language, "codec": codec, "channels": 6]
    }
    static func subtitle(_ index: Int, _ title: String) -> [String: Any] { ["index": index, "title": title] }
    static func main() throws {
        let suite = "kinolet.playlist-track-fixture." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SPPlaylistPreferencesStore(defaults: defaults)
        // Same stable synthetic file identity that real torrent playlists use;
        // worker stream ports/credentials are intentionally absent.
        let root = URL(fileURLWithPath: "/tmp/kinolet-fixture/Torrent Playlists/hash/Show", isDirectory: true)
        let unnamedRoot = root.appendingPathComponent("Unnamed", isDirectory: true)
        let unnamed = SPFixtureOwner(store: store, root: unnamedRoot)
        unnamed.core!.audioTrackList = [audio(3, "", "und"), audio(8, "", "und")]
        unnamed.ready(); unnamed.selectAudio(8)
        unnamed.next(audio: [audio(12, "", "und"), audio(17, "", "und")], subtitles: [], defaultAudio: 12, defaultSubtitle: -1)
        unnamed.ready()
        check(unnamed.core!.currentAudioTrackIndex == 17, "explicit unnamed audio selection transfers to the next torrent episode")
        unnamed.core!.subtitleTrackList = [subtitle(4, "Subtitle track 1"), subtitle(9, "Subtitle track 2")]
        unnamed.selectSubtitle(9)
        unnamed.next(audio: [audio(21, "", "und"), audio(26, "", "und")],
                     subtitles: [subtitle(31, "Subtitle track 1")], defaultAudio: 21, defaultSubtitle: 31)
        unnamed.ready()
        check(unnamed.core!.currentSubtitleTrackIndex == -1, "missing second generic subtitle stays off after cohort shrinks")
        unnamed.next(audio: [audio(32, "", "und"), audio(37, "", "und")],
                     subtitles: [subtitle(41, "Subtitle track 1"), subtitle(45, "Subtitle track 2")], defaultAudio: 32, defaultSubtitle: -1)
        unnamed.ready()
        check(unnamed.core!.currentSubtitleTrackIndex == 45, "generic subtitle preference survives an intermediate episode without that track")
        let owner = SPFixtureOwner(store: store, root: root)
        owner.core!.audioTrackList = [audio(1, "Original", "eng"), audio(3, "LostFilm")]
        owner.core!.subtitleTrackList = [subtitle(5, "Русский"), subtitle(9, "English SDH")]
        owner.ready()
        owner.selectAudio(3); owner.selectSubtitle(9)
        owner.pictureAdjustment.gamma = 23
        owner.next(audio: [audio(3, "Original", "eng"), audio(7, "LostFilm", "ru", "eac3")],
                   subtitles: [subtitle(9, "Русский"), subtitle(12, "English SDH")], defaultAudio: 3, defaultSubtitle: -1)
        check(owner.playlistProfileRestorePending, "next torrent episode arms profile restoration")
        check(owner.currentMediaIndex == 1 && owner.mediaList.count == 3, "torrent catalogue keeps the next stable file identity")
        owner.restore()
        check(owner.core!.currentAudioTrackIndex == 3, "Opening cannot apply tracks before metadata is ready")
        owner.ready()
        check(owner.core!.currentAudioTrackIndex == 7, "selected voice restores by identity after stream indices change")
        check(owner.core!.currentSubtitleTrackIndex == 12, "selected subtitles restore after torrent episode change")
        check(owner.userTouchedSubtitleSelection, "restored subtitles block later external autoload")
        check(owner.lastQuickSubtitleID == "embedded:12", "quick toggle remembers the new episode's matching index")
        check(!owner.torrentSubtitleBackgroundSuppressed, "restored embedded subtitles allow complete background preparation")
        check(owner.pictureAdjustment.gamma == 23, "track inheritance preserves image profile restoration")
        check(!owner.playlistProfileRestorePending, "ready transition consumes profile restoration once")
        let before = owner.core!.subtitleSelections.count
        owner.restore()
        check(owner.core!.subtitleSelections.count == before, "repeated state callbacks do not reselect subtitles")
        check(owner.policyCancels == owner.policyStarts && owner.policyStarts > 0, "subtitle selection restarts the foreground window policy")
        let remembered = owner.playlistProfile
        owner.next(audio: [audio(2, "NewStudio")], subtitles: [subtitle(4, "Русский")], defaultAudio: 2, defaultSubtitle: 4)
        owner.ready()
        check(owner.core!.currentSubtitleTrackIndex == -1, "missing chosen subtitles do not show a different language")
        check(owner.torrentSubtitleBackgroundSuppressed, "missing subtitles do not trigger preparation of a wrong track")
        check(owner.playlistProfile.subtitle == remembered.subtitle, "missing episode retains the selected subtitle preference")
        check(owner.playlistProfile.audio == remembered.audio, "missing voice retains the selected audio preference")
        owner.save()
        let reopened = SPFixtureOwner(store: store, root: root)
        reopened.core!.audioTrackList = [audio(20, "LostFilm")]
        reopened.core!.subtitleTrackList = [subtitle(31, "English SDH")]
        reopened.ready()
        check(reopened.core!.currentAudioTrackIndex == 20, "reopened torrent restores the saved voice")
        check(reopened.core!.currentSubtitleTrackIndex == 31, "later/reopened episode restores previously absent subtitles")
        reopened.selectSubtitle(-1)
        reopened.next(audio: [audio(44, "LostFilm")], subtitles: [subtitle(40, "English SDH")], defaultAudio: 44, defaultSubtitle: 40)
        reopened.ready()
        check(reopened.core!.currentSubtitleTrackIndex == -1, "explicit subtitles Off persists even when next episode defaults to On")
        check(reopened.userTouchedSubtitleSelection && reopened.torrentSubtitleBackgroundSuppressed, "Off blocks autoload and subtitle background work")
        let prior = reopened.playlistProfile
        reopened.invalidSelection()
        check(reopened.playlistProfile == prior, "invalid selections cannot erase stored preferences")
        let newRoot = root.deletingLastPathComponent().appendingPathComponent("Unrelated show", isDirectory: true)
        reopened.torrentContext = SPFixtureTorrentContext(rootURL: newRoot)
        reopened.prepare()
        check(reopened.playlistProfile == SPPlaylistProfile(), "another torrent has its own independent track profile")
        reopened.hasMediaSession = false; reopened.core!.state = .playing
        reopened.restore()
        check(reopened.playlistProfileRestorePending, "closed media cannot consume incoming restoration")
        print("Playlist controller track inheritance checks passed (\(checks) assertions).")
    }
}

import Foundation

@main
@MainActor
struct PlaylistPreferencesChecks {
    private static var checks = 0

    private static func expect<T: Equatable>(_ actual: T, _ expected: T,
                                             _ description: String) {
        checks += 1
        guard actual == expected else {
            fatalError("\(description): expected \(expected), got \(actual)")
        }
    }

    private static func audio(index: Int, voice: String = "", language: String,
                              codec: String = "ac3", channels: Int = 6,
                              isDefault: Bool = false,
                              title: String? = nil) -> [String: Any] {
        ["index": index, "title": title ?? "\(voice) · \(language) · \(codec)",
         "rawTitle": voice, "language": language, "codec": codec,
         "channels": channels, "isDefault": isDefault]
    }

    private static func preference(_ track: [String: Any],
                                   _ description: String) -> SPPlaylistAudioPreference {
        guard let value = SPPlaylistAudioPreference(track: track) else {
            fatalError("\(description): valid audio preference was rejected")
        }
        return value
    }

    static func main() throws {
        rawAudioMatchingChecks()
        conservativeAudioMatchingChecks()
        legacyAudioMatchingChecks()
        try explicitTrackAndSubtitleChecks()
        try profileChecks()
        try storeChecks()
        rememberedRootChecks()
        rememberedRootLimitChecks()
        print("Playlist preference checks passed (\(checks) assertions).")
    }

    private static func rawAudioMatchingChecks() {
        let remembered = preference(audio(index: 3, voice: "LostFilm", language: "rus"),
                                    "Remember a named Russian voice")
        let nextEpisode = [
            audio(index: 3, voice: "NewStudio", language: "rus"),
            audio(index: 11, voice: "Original", language: "eng"),
            audio(index: 8, voice: "LostFilm", language: "rus", codec: "eac3", channels: 2,
                  isDefault: true, title: "LostFilm · Russian · EAC3 2 ch")
        ]
        expect(remembered.bestMatch(in: nextEpisode), 8,
               "Voice identity survives changed stream index and encoding")
        expect(remembered.bestMatch(in: Array(nextEpisode.reversed())), 8,
               "Reordered track dictionaries do not change the selected voice")
        expect(remembered.bestMatch(in: [nextEpisode[2], nextEpisode[0]]), 8,
               "Removing an unrelated track does not shift the remembered voice")
        expect(remembered.bestMatch(in: [audio(index: 21, voice: "LOSTFILM", language: "ru")]), 21,
               "Raw voice name and equivalent language tags normalize consistently")

        let localized = preference(
            audio(index: 2, voice: "Кубик в Кубе", language: "rus",
                  title: "Кубик в Кубе · Русский · AC3, 6 кан."), "Remember a Cyrillic voice")
        expect(localized.bestMatch(in: [
            audio(index: 7, voice: "Кубик в Кубе", language: "rus", codec: "aac", channels: 2,
                  title: "Кубик в Кубе · Russian · AAC 2 ch")
        ]), 7, "Changing the interface language does not change raw voice identity")

        let codecInName = preference(audio(index: 4, voice: "AC3 Studio", language: "rus"),
                                     "Remember a voice whose name contains a codec")
        expect(codecInName.bestMatch(in: [
            audio(index: 9, voice: "Studio", language: "rus"),
            audio(index: 10, voice: "AC3 Studio", language: "rus", codec: "aac")
        ]), 10, "Raw voice metadata is not stripped as codec decoration")

        let channelsInName = preference(audio(index: 4, voice: "5.1 Productions", language: "eng"),
                                        "Remember a voice whose name contains a number")
        expect(channelsInName.bestMatch(in: [
            audio(index: 6, voice: "Productions", language: "eng"),
            audio(index: 12, voice: "5.1 Productions", language: "eng", channels: 8)
        ]), 12, "Raw voice metadata preserves meaningful channel-like text")
        expect(remembered.bestMatch(in: []), nil, "An episode without audio has no match")
    }

    private static func conservativeAudioMatchingChecks() {
        let named = preference(audio(index: 1, voice: "LostFilm", language: "rus"),
                               "Remember a named voice for conservative matching")
        expect(named.bestMatch(in: [audio(index: 1, voice: "NewStudio", language: "rus")]), nil,
               "A missing named voice does not silently switch to another dub")
        expect(named.bestMatch(in: [audio(index: 1, language: "rus", isDefault: true)]), nil,
               "A missing named voice does not fall back to generic language or default")
        expect(named.bestMatch(in: [audio(index: 1, voice: "LostFilm", language: "eng")]), nil,
               "The same voice label in another language is not selected")
        expect(named.bestMatch(in: [
            audio(index: 5, voice: "LostFilm", language: "eng"),
            audio(index: 6, voice: "LostFilm", language: "rus")
        ]), 6, "Language disambiguates identical voice names")
        expect(named.bestMatch(in: [
            audio(index: 7, voice: "LostFilm", language: "rus"),
            audio(index: 8, voice: "LostFilm", language: "rus")
        ]), nil, "Indistinguishable named tracks do not depend on list order")

        let languageOnly = preference(audio(index: 4, language: "rus",
                                             title: "Russian · EAC3 · 6 channels"),
                                      "Remember an unnamed language track")
        expect(languageOnly.bestMatch(in: [
            audio(index: 10, language: "eng"),
            audio(index: 12, language: "rus", codec: "aac", channels: 2)
        ]), 12, "An unnamed preference can select its sole same-language track")
        expect(languageOnly.bestMatch(in: [
            audio(index: 10, language: "rus"),
            audio(index: 12, language: "rus", codec: "aac", channels: 2)
        ]), nil, "Language-only tracks remain ambiguous when more than one matches")
        expect(languageOnly.bestMatch(in: [audio(index: 10, language: "eng")]), nil,
               "A language-only preference never crosses languages")
        expect(SPPlaylistAudioPreference(track: [:]), nil,
               "An empty track dictionary cannot produce a preference")
        expect(SPPlaylistAudioPreference(track: ["index": 2, "title": "  "]), nil,
               "An empty track title without metadata cannot produce a preference")
    }

    private static func legacyAudioMatchingChecks() {
        // Older installed MediaCore builds expose only a localized composed title.
        let legacy = preference(["index": 2,
                                 "title": "LostFilm · Русский · AC3 · 6 каналов"],
                                "Remember an older localized title")
        expect(legacy.bestMatch(in: [
            ["index": 4, "title": "NewStudio · Русский · AC3 · 6 каналов"],
            ["index": 9, "title": "LostFilm · Русский · EAC3 · 2 канала"]
        ]), 9, "Legacy localized title ignores codec and channel decorations")

        let actualRussian = preference(["index": 2,
                                        "title": "LostFilm · Русский · AC3, 6 кан."],
                                       "Remember the actual Russian legacy formatter")
        expect(actualRussian.bestMatch(in: [
            ["index": 5, "title": "NewStudio · Русский · AC3, 6 кан."],
            ["index": 13, "title": "LostFilm · Русский · EAC3, 2 кан."]
        ]), 13, "Actual Russian codec/channel formatting does not become voice identity")

        let actualChinese = preference(["index": 1,
                                        "title": "LostFilm · 俄语 · AC3 6声道"],
                                       "Remember the actual Chinese legacy formatter")
        expect(actualChinese.bestMatch(in: [
            ["index": 8, "title": "LostFilm · 俄语 · AAC 2声道"],
            ["index": 9, "title": "NewStudio · 俄语 · AC3 6声道"]
        ]), 8, "Chinese channel decoration changes do not lose the selected voice")

        let actualEnglish = preference(["index": 4,
                                        "title": "LostFilm · Russian · AC3 6 ch"],
                                       "Remember the actual English legacy formatter")
        expect(actualEnglish.bestMatch(in: [
            ["index": 16, "title": "LostFilm · Russian · EAC3 2 ch"]
        ]), 16, "English channel decoration changes do not lose the selected voice")
        expect(actualEnglish.bestMatch(in: [
            ["index": 16, "title": "LostFilm · English · EAC3 2 ch"]
        ]), nil, "Legacy composed titles retain their language guard")
        expect(actualEnglish.bestMatch(in: [
            ["index": 16, "title": "NewStudio · Russian · EAC3 2 ch"]
        ]), nil, "Legacy named voices do not fall back to language alone")

        let legacyLanguage = preference(["index": 1,
                                         "title": "Russian · EAC3 · 6 channels"],
                                        "Remember a legacy unnamed language track")
        expect(legacyLanguage.bestMatch(in: [
            ["index": 2, "title": "English · AC3 · 6 channels"],
            ["index": 3, "title": "Russian · AAC · 2 channels"]
        ]), 3, "Legacy unnamed language track survives an encoding change")
        expect(legacyLanguage.bestMatch(in: [
            ["index": 2, "title": "Russian · AC3 · 6 channels"],
            ["index": 3, "title": "Russian · AAC · 2 channels"]
        ]), nil, "Legacy language-only ties remain ambiguous")

        // Raw metadata is optional: a new track can match a preference captured by an old core.
        expect(actualRussian.bestMatch(in: [
            audio(index: 17, voice: "LostFilm", language: "rus", codec: "aac", channels: 2)
        ]), 17, "A legacy preference matches newer raw metadata")
        let raw = preference(audio(index: 5, voice: "LostFilm", language: "rus"),
                             "Remember raw metadata before legacy fallback")
        expect(raw.bestMatch(in: [
            ["index": 18, "title": "LostFilm · Русский · AAC, 2 кан."]
        ]), 18, "A raw preference can fall back to older composed metadata")

        let shortVoice = preference(["index": 1, "title": "DUB · Russian · AC3 6 ch"],
                                    "Remember a short legacy voice label")
        expect(shortVoice.bestMatch(in: [
            ["index": 7, "title": "DUB · English · AAC 2 ch"],
            ["index": 8, "title": "DUB · Russian · EAC3 6 ch"]
        ]), 8, "A short voice label is not confused with a language tag")
        expect(shortVoice.bestMatch(in: [
            ["index": 7, "title": "DUB · English · AAC 2 ch"]
        ]), nil, "Short legacy voice labels still enforce the remembered language")

        let codecVoiceTrack: [String: Any] = ["index": 3, "title": "AC3 Studio · AC3 6 ch"]
        expect(SPPlaylistAudioPreference(track: codecVoiceTrack) != nil, true,
               "A legacy voice containing a codec name can be remembered without language metadata")
        let legacyCodecVoice = preference(codecVoiceTrack, "Remember a codec-like legacy voice name")
        expect(legacyCodecVoice.bestMatch(in: [
            ["index": 9, "title": "AC3 Studio · AAC 2 ch"]
        ]), 9, "Only the trailing codec decoration is stripped from a codec-like voice name")
        expect(legacyCodecVoice.bestMatch(in: [
            ["index": 10, "title": "Studio · AAC 2 ch"]
        ]), nil, "Codec-like text inside the remembered voice is not discarded")

        let legacyPCM = preference(["index": 4,
                                    "title": "LostFilm · Russian · PCM_S16LE 2 ch"],
                                   "Remember an underscore-containing PCM codec decoration")
        expect(legacyPCM.bestMatch(in: [
            ["index": 19, "title": "NewStudio · Russian · PCM_S24LE 6 ch"],
            ["index": 20, "title": "LostFilm · Russian · AAC 2 ch"]
        ]), 20, "Legacy PCM codec decorations do not become part of the voice identity")
    }

    private static func explicitTrackAndSubtitleChecks() throws {
        let unnamed = [audio(index: 2, language: "und"), audio(index: 8, language: "und")]
        let preference = SPPlaylistAudioPreference(selectedIndex: 8, in: unnamed)!
        expect(preference.bestMatch(in: [audio(index: 12, language: "und"), audio(index: 17, language: "und")]),
               17, "Explicit untagged track remembers its cohort position after stream indices change")
        expect(preference.bestMatch(in: [audio(index: 12, language: "und")]), nil,
               "A second unnamed track cannot become the first after its cohort shrinks")
        expect(preference.bestMatch(in: [audio(index: 11, voice: "Unrelated Studio", language: "und")]),
               nil, "An unidentified voice does not switch to a newly named unknown-language voice")
        expect(SPPlaylistAudioPreference(selectedIndex: 999, in: unnamed), nil, "An absent selection creates no preference")
        let named = SPPlaylistAudioPreference(selectedIndex: 2, in: [audio(index: 2, voice: "LostFilm", language: "ru")])!
        expect(named.bestMatch(in: [audio(index: 8, voice: "NewStudio", language: "ru")]), nil,
               "Explicit capture preserves the named-voice guard")
        let languages = [audio(index: 2, language: "ru"), audio(index: 3, language: "ru")]
        let second = SPPlaylistAudioPreference(selectedIndex: 3, in: languages)!
        expect(second.bestMatch(in: [audio(index: 30, language: "ru"), audio(index: 40, language: "ru")]), 40,
               "Explicit language-only choice resolves equal metadata by cohort position")
        expect(second.bestMatch(in: [audio(index: 30, language: "ru"), audio(index: 40, language: "ru"), audio(index: 50, language: "ru")]),
               nil, "A changed indistinguishable cohort is not guessed by absolute stream index")
        let subs: [[String: Any]] = [["index": 3, "title": "Русский"], ["index": 8, "title": "English SDH"]]
        let subtitle = SPPlaylistSubtitlePreference(selectedIndex: 8, in: subs)!
        expect(subtitle.bestMatch(in: [["index": 8, "title": "Русский"], ["index": 18, "title": "English SDH"]]),
               18, "Subtitle identity follows title rather than the reused previous stream index")
        expect(subtitle.bestMatch(in: [["index": 18, "title": "English Forced"]]), nil,
               "Full/SDH and forced subtitle labels stay distinct")
        let russian = SPPlaylistSubtitlePreference(selectedIndex: 3, in: subs)!
        expect(russian.bestMatch(in: [["index": 20, "title": "Russian"]]), 20,
               "Language-only subtitle names survive the display language changing")
        expect(russian.bestMatch(in: [["index": 20, "title": "English"]]), nil,
               "Subtitle matching does not cross languages")
        let generic = SPPlaylistSubtitlePreference(selectedIndex: 12, in: [["index": 5, "title": "Субтитры 1"], ["index": 12, "title": "Субтитры 2"]])!
        expect(generic.bestMatch(in: [["index": 31, "title": "Subtitle track 1"], ["index": 41, "title": "Subtitle track 2"]]),
               41, "Unlabelled subtitle ordinal ignores localized generated labels and container indices")
        expect(generic.bestMatch(in: [["index": 31, "title": "Subtitle track 1"]]), nil,
               "A missing second generic subtitle cannot silently become the remaining first")
        let duplicateNamed = SPPlaylistAudioPreference(selectedIndex: 7,
            in: [audio(index: 3, voice: "Studio", language: "ru"), audio(index: 7, voice: "Studio", language: "ru")])!
        expect(duplicateNamed.bestMatch(in: [audio(index: 19, voice: "Studio", language: "ru")]), nil,
               "An indistinguishable named cohort also cannot shrink into an arbitrary unique choice")
        expect(SPPlaylistSubtitlePreference(selectedIndex: -1, in: subs)?.bestMatch(in: subs), -1,
               "Off is an explicit stored subtitle selection")
        expect(SPPlaylistSubtitlePreference(selectedIndex: 999, in: subs), nil,
               "Invalid subtitle selection cannot erase a remembered choice")
        var profile = SPPlaylistProfile()
        profile.audio = preference; profile.subtitle = subtitle; profile.gamma = 13
        let encoded = try JSONEncoder().encode(profile)
        expect(try JSONDecoder().decode(SPPlaylistProfile.self, from: encoded), profile,
               "Audio cohort and embedded subtitle preferences survive persistence")
        profile.subtitle = .off
        expect(try JSONDecoder().decode(SPPlaylistProfile.self, from: JSONEncoder().encode(profile)), profile,
               "Explicit Off survives persistence")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SPPlaylistProfile())) as! [String: Any]
        legacy.removeValue(forKey: "subtitle")
        legacy["audio"] = ["voice": "lostfilm", "language": "ru", "codec": "ac3", "channels": 6]
        let old = try JSONDecoder().decode(SPPlaylistProfile.self, from: JSONSerialization.data(withJSONObject: legacy))
        expect(old.subtitle, nil, "Older saved image/audio profiles without subtitles remain readable")
        expect(old.audio?.bestMatch(in: [audio(index: 20, voice: "LostFilm", language: "ru")]), 20,
               "Older audio identities without ordinal fields remain readable")
    }

    private static func profileChecks() throws {
        let neutral = SPPlaylistProfile()
        expect(neutral.audio, nil, "A new playlist does not force an audio track")
        expect(neutral.brightness, 0, "Default brightness is neutral")
        expect(neutral.contrast, 0, "Default contrast is neutral")
        expect(neutral.saturation, 0, "Default saturation is neutral")
        expect(neutral.gamma, 0, "Default gamma is neutral")
        expect(neutral.hue, 0, "Default hue is neutral")
        expect(neutral.aspect, 0, "Default aspect preserves the source")
        expect(neutral.crop, 0, "Default crop is disabled")
        expect(neutral.rotation, 0, "Default rotation is zero")
        expect(neutral.mirror, 0, "Default mirror is disabled")
        expect(neutral.motionMode, 0, "Default motion mode is disabled")
        expect(neutral.xdr, false, "Default brightness boost is disabled")

        var modified = neutral
        modified.audio = preference(audio(index: 1, voice: "LostFilm", language: "rus"),
                                    "Audio preference in saved profile")
        modified.brightness = 8
        modified.contrast = -12
        modified.saturation = 4.5
        modified.gamma = 18
        modified.hue = -3
        modified.aspect = 1333
        modified.crop = 1778
        modified.rotation = 90
        modified.mirror = 1
        modified.motionMode = 1
        modified.xdr = true
        let encoded = try JSONEncoder().encode(modified)
        let decoded = try JSONDecoder().decode(SPPlaylistProfile.self, from: encoded)
        expect(decoded, modified, "Every supported playback preference survives Codable round-trip")
        expect(decoded.audio?.bestMatch(in: [
            audio(index: 23, voice: "LostFilm", language: "rus", codec: "eac3")
        ]), 23, "The encoded audio preference remains independent of its old stream index")
        expect(try JSONDecoder().decode(SPPlaylistProfile.self,
                                       from: JSONEncoder().encode(neutral)), neutral,
               "A neutral profile survives Codable round-trip")
    }

    private static func storeChecks() throws {
        let suiteName = "khua.playlist-preferences-checks.\(UUID().uuidString)"
        let unrelatedSuiteName = "khua.playlist-preferences-checks.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName),
              let unrelatedDefaults = UserDefaults(suiteName: unrelatedSuiteName) else {
            fatalError("Could not create isolated preference suites")
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            unrelatedDefaults.removePersistentDomain(forName: unrelatedSuiteName)
        }
        let root = URL(fileURLWithPath: "/tmp/Khua Preferences Tests/Show/Season 1", isDirectory: true)
        let sibling = URL(fileURLWithPath: "/tmp/Khua Preferences Tests/Show/Season 2", isDirectory: true)
        let parent = root.deletingLastPathComponent()
        let child = root.appendingPathComponent("Extras", isDirectory: true)
        let store = SPPlaylistPreferencesStore(defaults: defaults)
        expect(store.profile(for: root), nil, "A fresh directory has no saved profile")

        var saved = SPPlaylistProfile()
        saved.gamma = 17
        saved.brightness = 8
        saved.contrast = -12
        saved.saturation = 3.5
        saved.hue = -4
        saved.aspect = 1333
        saved.crop = 1778
        saved.rotation = 90
        saved.mirror = 2
        saved.motionMode = 1
        saved.xdr = true
        saved.audio = preference(audio(index: 3, voice: "LostFilm", language: "rus"),
                                 "Audio preference saved per directory")
        store.save(saved, for: root)
        expect(store.profile(for: root), saved, "A profile can be read immediately after saving")
        expect(store.profile(for: sibling), nil, "Sibling directories do not share profiles")
        expect(store.profile(for: parent), nil, "A directory profile does not leak to its parent")
        expect(store.profile(for: child), nil, "A directory profile does not leak to descendants")

        let equivalentRoot = URL(fileURLWithPath:
            "/tmp/Khua Preferences Tests/Show/Season 2/../Season 1/./", isDirectory: true)
        expect(store.profile(for: equivalentRoot), saved,
               "Equivalent standardized directory paths share one profile")
        let recreated = SPPlaylistPreferencesStore(defaults: UserDefaults(suiteName: suiteName)!)
        expect(recreated.profile(for: root), saved,
               "Saved profiles survive recreating the store and defaults wrapper")
        expect(SPPlaylistPreferencesStore(defaults: unrelatedDefaults).profile(for: root), nil,
               "Explicit defaults injection isolates independent stores")

        var siblingProfile = SPPlaylistProfile()
        siblingProfile.contrast = -7
        siblingProfile.rotation = 180
        recreated.save(siblingProfile, for: sibling)
        expect(recreated.profile(for: sibling), siblingProfile,
               "Another directory can keep a different profile")
        expect(recreated.profile(for: root), saved,
               "Saving a sibling leaves the original directory profile intact")

        saved.gamma = 26
        saved.xdr = true
        recreated.save(saved, for: equivalentRoot)
        let reopened = SPPlaylistPreferencesStore(defaults: UserDefaults(suiteName: suiteName)!)
        expect(reopened.profile(for: root), saved,
               "Saving through a canonical alias overwrites the same durable profile")
        expect(reopened.profile(for: sibling), siblingProfile,
               "Overwriting one profile preserves other directory settings")

        // Corrupt the persisted payload without knowing the implementation's storage key.
        guard let domain = defaults.persistentDomain(forName: suiteName), !domain.isEmpty else {
            fatalError("Saving a playlist profile did not write to the injected defaults suite")
        }
        for key in domain.keys { defaults.set(Data("not valid JSON".utf8), forKey: key) }
        let corrupted = SPPlaylistPreferencesStore(defaults: UserDefaults(suiteName: suiteName)!)
        expect(corrupted.profile(for: root), nil,
               "An invalid persisted payload is ignored without crashing")
        corrupted.save(SPPlaylistProfile(), for: root)
        expect(SPPlaylistPreferencesStore(defaults: defaults).profile(for: root), SPPlaylistProfile(),
               "A valid save recovers after corrupted persisted data")
    }

    private static func rememberedRootChecks() {
        let suiteName = "khua.playlist-root-checks.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create isolated playlist-root defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SPPlaylistPreferencesStore(defaults: defaults)
        let show = URL(fileURLWithPath: "/tmp/Khua Root Tests/Show", isDirectory: true)
        let seasonOne = show.appendingPathComponent("Season 1", isDirectory: true)
        let seasonTwo = show.appendingPathComponent("Season 2", isDirectory: true)
        let firstEpisode = seasonOne.appendingPathComponent("Episode 01.mkv")
        let secondEpisode = seasonTwo.appendingPathComponent("Episode 02.mkv")

        expect(store.rememberedRoot(containing: firstEpisode), nil,
               "A media path alone does not create a remembered root")
        store.rememberRoot(seasonOne)
        expect(store.rememberedRoot(containing: firstEpisode)?.path, seasonOne.path,
               "An explicitly remembered directory contains its media files")
        expect(store.rememberedRoot(containing: secondEpisode), nil,
               "Remembering a season does not implicitly remember its parent or siblings")
        expect(store.rememberedRoot(containing: seasonOne), nil,
               "A remembered root must be a proper ancestor of the media URL")

        store.rememberRoot(show)
        expect(store.rememberedRoot(containing: firstEpisode)?.path, seasonOne.path,
               "The deepest remembered ancestor wins even when its parent was remembered later")
        expect(store.rememberedRoot(containing: secondEpisode)?.path, show.path,
               "An explicitly remembered show contains media in another season")
        expect(store.rememberedRoot(containing: show), nil,
               "A root never contains itself")
        let prefixCollision = URL(fileURLWithPath:
            "/tmp/Khua Root Tests/ShowExtras/Episode 01.mkv")
        expect(store.rememberedRoot(containing: prefixCollision), nil,
               "Path-component boundaries prevent Show from matching ShowExtras")
        let parentMedia = URL(fileURLWithPath: "/tmp/Khua Root Tests/Trailer.mkv")
        expect(store.rememberedRoot(containing: parentMedia), nil,
               "Remembering a show does not implicitly remember its parent")

        store.rememberRoot(seasonTwo)
        expect(store.rememberedRoot(containing: secondEpisode)?.path, seasonTwo.path,
               "A separately remembered sibling season gets its own root")
        expect(store.rememberedRoot(containing: firstEpisode)?.path, seasonOne.path,
               "Remembering a sibling never replaces the first season's deeper root")

        let aliasRoot = URL(fileURLWithPath:
            "/tmp/Khua Root Tests/Show/Season 2/../Season 1/./", isDirectory: true)
        store.rememberRoot(aliasRoot)
        let aliasMedia = URL(fileURLWithPath:
            "/tmp/Khua Root Tests/Show/Season 2/../Season 1/./Episode 03.mkv")
        expect(store.rememberedRoot(containing: aliasMedia)?.path, seasonOne.path,
               "Root and media aliases are standardized lexically")
        let recreated = SPPlaylistPreferencesStore(defaults: UserDefaults(suiteName: suiteName)!)
        expect(recreated.rememberedRoot(containing: aliasMedia)?.path, seasonOne.path,
               "Remembered canonical roots survive a recreated store")
        expect(recreated.rememberedRoot(containing: secondEpisode)?.path, seasonTwo.path,
               "Recreating the store preserves all explicitly remembered roots")

        let remoteRoot = URL(string: "https://example.invalid/Show/")!
        let remoteMedia = URL(string: "https://example.invalid/Show/Episode.mkv")!
        recreated.rememberRoot(remoteRoot)
        expect(recreated.rememberedRoot(containing: remoteMedia), nil,
               "Non-file URLs cannot create or resolve remembered roots")
        let remoteFilePath = URL(string: "https://example.invalid/tmp/Khua%20Root%20Tests/Show/Episode.mkv")!
        expect(recreated.rememberedRoot(containing: remoteFilePath), nil,
               "A remote URL with a matching local path cannot resolve a file root")
        expect(recreated.rememberedRoot(containing: firstEpisode)?.path, seasonOne.path,
               "Ignoring a non-file root leaves existing local roots intact")
    }

    private static func rememberedRootLimitChecks() {
        let suiteName = "khua.playlist-root-limit-checks.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create isolated bounded-root defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SPPlaylistPreferencesStore(defaults: defaults)
        let base = URL(fileURLWithPath: "/tmp/Khua Root Limit Tests", isDirectory: true)
        let roots = (0..<26).map { base.appendingPathComponent("Show \($0)", isDirectory: true) }
        func remembered(_ index: Int, in store: SPPlaylistPreferencesStore) -> String? {
            store.rememberedRoot(containing: roots[index].appendingPathComponent("Episode.mkv"))?.path
        }

        for root in roots.prefix(24) { store.rememberRoot(root) }
        expect(remembered(0, in: store), roots[0].path,
               "The oldest root remains available at the 24-root capacity")
        expect(remembered(23, in: store), roots[23].path,
               "The latest root is available at the 24-root capacity")

        let duplicateAlias = base.appendingPathComponent("Unused/../Show 12/./", isDirectory: true)
        store.rememberRoot(duplicateAlias)
        expect(remembered(0, in: store), roots[0].path,
               "Refreshing a canonical duplicate does not consume another capacity slot")
        expect(remembered(12, in: store), roots[12].path,
               "Refreshing a canonical duplicate preserves its root")

        store.rememberRoot(roots[0])
        store.rememberRoot(roots[24])
        expect(remembered(0, in: store), roots[0].path,
               "Refreshing the oldest root makes it recent enough to survive the next insertion")
        expect(remembered(1, in: store), nil,
               "The least recently remembered root is evicted beyond 24 unique roots")
        expect(remembered(2, in: store), roots[2].path,
               "Adding one root beyond capacity evicts only one unique root")
        expect(remembered(24, in: store), roots[24].path,
               "The new root is retained after eviction")

        store.rememberRoot(roots[25])
        let recreated = SPPlaylistPreferencesStore(defaults: UserDefaults(suiteName: suiteName)!)
        expect(remembered(2, in: recreated), nil,
               "The next insertion evicts the next least recent root durably")
        expect(remembered(3, in: recreated), roots[3].path,
               "Durable capacity management does not evict extra roots")
        expect(remembered(0, in: recreated), roots[0].path,
               "A refreshed root remains recent after store recreation")
        expect(remembered(12, in: recreated), roots[12].path,
               "A refreshed canonical alias remains present after store recreation")
        expect(remembered(25, in: recreated), roots[25].path,
               "The latest root survives store recreation")
    }
}

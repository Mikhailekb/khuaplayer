import Foundation

/// A playlist remembers the selected voice, not a container-specific stream index.
struct SPPlaylistAudioPreference: Codable, Equatable {
    private let voice: String
    private let language: String
    private let codec: String
    private let channels: Int

    init?(track: [String: Any]) {
        let identity = Track(track)
        guard !identity.voice.isEmpty || !identity.language.isEmpty else { return nil }
        voice = identity.voice
        language = identity.language
        codec = identity.codec
        channels = identity.channels
    }

    func bestMatch(in tracks: [[String: Any]]) -> Int? {
        var candidates = tracks.map(Track.init).filter { $0.index >= 0 }
        if voice.isEmpty {
            // Language alone cannot distinguish two different dubbed voices.
            candidates = candidates.filter { $0.language == language }
            return candidates.count == 1 ? candidates.first?.index : nil
        }
        candidates = candidates.filter { $0.voice == voice }
        if !language.isEmpty {
            candidates = candidates.filter { $0.language.isEmpty || $0.language == language }
            let sameLanguage = candidates.filter { $0.language == language }
            if !sameLanguage.isEmpty { candidates = sameLanguage }
        } else if Set(candidates.map(\.language).filter { !$0.isEmpty }).count > 1 {
            return nil
        }
        if candidates.count == 1 { return candidates.first?.index }
        // Encoding changes between episodes are harmless. Codec/channel count
        // only disambiguate otherwise identical named voices; ties stay unset.
        let scored = candidates.map { track in
            (track.index, (!codec.isEmpty && track.codec == codec ? 1 : 0)
                + (channels > 0 && track.channels == channels ? 1 : 0))
        }
        guard let best = scored.map(\.1).max(), best > 0 else { return nil }
        let winners = scored.filter { $0.1 == best }
        return winners.count == 1 ? winners.first?.0 : nil
    }

    private struct Track {
        var index = -1
        var voice = ""
        var language = ""
        var codec = ""
        var channels = 0

        init(_ track: [String: Any]) {
            index = track["index"] as? Int ?? -1
            language = SPPlaylistAudioPreference.languageCode(track["language"] as? String ?? "")
            codec = SPPlaylistAudioPreference.codecName(track["codec"] as? String ?? "")
            channels = max(0, track["channels"] as? Int ?? 0)
            var parts = (track["title"] as? String ?? "").components(separatedBy: "·")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            // Old installed engines expose a localized composed title only.
            // Remove trailing encoding decorations, never the voice label.
            while let last = parts.last, let technical = SPPlaylistAudioPreference.technicalPart(last) {
                if codec.isEmpty { codec = technical.codec }
                if channels == 0 { channels = technical.channels }
                parts.removeLast()
            }
            // The legacy formatter places a language after an explicit voice
            // title. A short voice label such as DUB must remain a title.
            let languageIndex = parts.indices.reversed().first { index in
                let code = SPPlaylistAudioPreference.displayLanguageCode(parts[index])
                return !code.isEmpty && (language.isEmpty || code == language)
            }
            if language.isEmpty, let languageIndex {
                language = SPPlaylistAudioPreference.displayLanguageCode(parts[languageIndex])
            }
            let labels = parts.enumerated().compactMap { index, part in
                index == languageIndex || SPPlaylistAudioPreference.isGenericTitle(part) ? nil : part
            }
            let title = track["rawTitle"] as? String ?? labels.joined(separator: " ")
            voice = SPPlaylistAudioPreference.isGenericTitle(title) ? "" : SPPlaylistAudioPreference.normalized(title)
        }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func codecName(_ value: String) -> String {
        let name = value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        switch name {
        case "dca": return "dts"
        case "ddp", "ddplus": return "eac3"
        default: return name
        }
    }

    private static let codecs: Set<String> = [
        "aac", "ac3", "eac3", "ddp", "ddplus", "truehd", "dts", "dca", "opus",
        "flac", "alac", "vorbis", "mp3", "mp2", "mp1", "wavpack", "ape", "wma",
    ]
    private static let channelUnits: Set<String> = [
        "ch", "channel", "channels", "кан", "канала", "каналов", "canales", "canaux", "kanale",
        "saluran", "canali", "kanalen", "kan", "canais", "kanal", "声道", "聲道", "채널", "แชนเนล", "kenh",
    ]
    private static func technicalPart(_ value: String) -> (codec: String, channels: Int)? {
        let normalized = normalized(value)
        guard let rawFirst = value.split(whereSeparator: { $0.isWhitespace || $0 == "," }).first else { return nil }
        let first = codecName(String(rawFirst))
        let hasCodec = codecs.contains(first) || first.hasPrefix("pcm") || first.hasPrefix("wmav")
        let remainder = hasCodec ? Self.normalized(String(value.dropFirst(rawFirst.count))) : normalized
        let words = remainder.split(separator: " ").map(String.init)
        let channelOnly = !hasCodec && first.first?.isNumber == true
        guard hasCodec || channelOnly else { return nil }
        let technicalWords = words.allSatisfy { word in
            let unit = String(word.drop(while: \.isNumber))
            return unit.isEmpty || channelUnits.contains(unit)
        }
        guard technicalWords else { return nil }
        let count = remainder.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap(Int.init).first ?? 0
        return (hasCodec ? codecName(first) : "", count)
    }

    private static let languageNames: [String: String] = {
        let locales = ["en", "de", "es", "fr", "id", "it", "ja", "ko", "nl", "pl", "pt",
                       "ru", "th", "tr", "vi", "zh-Hans", "zh-Hant"]
        let languages = ["zh", "zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de", "es",
                         "ru", "it", "pt", "th", "vi", "ar", "hi"]
        var names: [String: String] = [:]
        for language in languages {
            for locale in locales {
                if let name = Locale(identifier: locale).localizedString(forLanguageCode: language) {
                    names[normalized(name)] = language.lowercased()
                }
            }
        }
        // These are the display spellings emitted by the older Core bridge.
        names[normalized("俄文")] = "ru"
        names[normalized("英文")] = "en"
        return names
    }()

    private static func languageCode(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let code = languageNames[normalized(value)] { return code }
        // Unknown/localized voice labels must never be interpreted as BCP 47.
        guard value.range(of: #"^[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{2,8})*$"#,
                          options: .regularExpression) != nil else { return "" }
        let alias: String
        switch value.lowercased() {
        case "chs": alias = "zh-Hans"
        case "cht": alias = "zh-Hant"
        default: alias = value
        }
        let code = Locale.canonicalLanguageIdentifier(from: alias).replacingOccurrences(of: "_", with: "-").lowercased()
        return code == "und" ? "" : code
    }

    private static func displayLanguageCode(_ value: String) -> String {
        if let code = languageNames[normalized(value)] { return code }
        // Core lowercases unrecognized language tags, but preserves voice names.
        guard value == value.lowercased() else { return "" }
        return languageCode(value)
    }

    private static func isGenericTitle(_ value: String) -> Bool {
        let value = normalized(value)
        if value.isEmpty { return true }
        let unspecified = ["untagged", "unknown", "untitled", "no title", "unnamed", "без названия", "не указан",
                           "nicht gekennzeichnet", "sin etiquetar", "non indiquée", "tidak ditandai",
                           "non specificata", "タグなし", "미지정", "niet gelabeld", "nieoznaczony",
                           "sem etiqueta", "ไม่ได้ระบุ", "etiketlenmemiş", "chưa gắn nhãn", "未标注", "未標註"]
        if unspecified.contains(where: { normalized($0) == value }) { return true }
        let prefixes = ["Audio track", "Audiospur", "Pista de audio", "Piste audio", "Trek audio",
                        "Traccia audio", "音声トラック", "오디오 트랙", "Audiospoor", "Ścieżka dźwiękowa",
                        "Faixa de áudio", "Звуковая дорожка", "แทร็กเสียง", "Ses parçası", "Bản âm thanh", "音轨", "音訊軌道"]
        return prefixes.contains { prefix in
            let prefix = normalized(prefix)
            guard value.hasPrefix(prefix) else { return false }
            let suffix = value.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
        }
    }
}

struct SPPlaylistProfile: Codable, Equatable {
    var audio: SPPlaylistAudioPreference?
    var brightness: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0
    var gamma: Double = 0
    var hue: Double = 0
    var aspect: Int = 0
    var crop: Int = 0
    var rotation: Int = 0
    var mirror: Int = 0
    var motionMode: Int = 0
    var xdr = false

    fileprivate var sanitized: Self {
        var value = self
        func percent(_ number: Double) -> Double { number.isFinite ? min(100, max(-100, number)) : 0 }
        value.brightness = percent(brightness)
        value.contrast = percent(contrast)
        value.saturation = percent(saturation)
        value.gamma = percent(gamma)
        value.hue = percent(hue)
        value.aspect = (101..<10_000).contains(aspect) ? aspect : 0
        value.crop = (101..<10_000).contains(crop) ? crop : 0
        value.rotation = [0, 90, 180, 270].contains(rotation) ? rotation : 0
        value.mirror = (0...2).contains(mirror) ? mirror : 0
        value.motionMode = (0...1).contains(motionMode) ? motionMode : 0
        return value
    }
}

/// Durable settings belong to a playlist root, without probing a remote path.
@MainActor
final class SPPlaylistPreferencesStore {
    static let shared = SPPlaylistPreferencesStore()
    private let defaults: UserDefaults
    private static let keyPrefix = "sp.playlist.profile.v1."
    private static let rootsKey = "sp.playlist.roots.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Pass the playlist's directory URL, rather than an individual media URL.
    func profile(for rootURL: URL) -> SPPlaylistProfile? {
        guard let key = key(for: rootURL), let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(SPPlaylistProfile.self, from: data) else { return nil }
        return value.sanitized
    }

    func save(_ profile: SPPlaylistProfile, for rootURL: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let key = key(for: rootURL),
              let data = try? encoder.encode(profile.sanitized) else { return }
        if defaults.data(forKey: key) != data { defaults.set(data, forKey: key) }
    }

    /// Only an explicit folder choice is remembered. Plain file opens must not
    /// infer a broader root or turn a single episode into a recursive disk scan.
    func rememberRoot(_ rootURL: URL) {
        guard rootURL.isFileURL else { return }
        let path = rootURL.standardizedFileURL.path
        var roots = rememberedRootPaths.filter { $0 != path }
        roots.insert(path, at: 0)
        roots = Array(roots.prefix(24))
        if defaults.stringArray(forKey: Self.rootsKey) != roots {
            defaults.set(roots, forKey: Self.rootsKey)
        }
    }

    /// Match a proper ancestor by path components, with the most specific
    /// explicit root winning. This never probes a local or network filesystem.
    func rememberedRoot(containing mediaURL: URL) -> URL? {
        guard mediaURL.isFileURL else { return nil }
        let child = mediaURL.standardizedFileURL.pathComponents
        return rememberedRootPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { root in
                let parent = root.pathComponents
                return child.count > parent.count && child.starts(with: parent)
            }
            .max { $0.pathComponents.count < $1.pathComponents.count }
    }

    private var rememberedRootPaths: [String] {
        (defaults.stringArray(forKey: Self.rootsKey) ?? []).filter { $0.hasPrefix("/") }
            .prefix(24)
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path }
    }

    private func key(for rootURL: URL) -> String? {
        guard rootURL.isFileURL else { return nil }
        return Self.keyPrefix + rootURL.standardizedFileURL.path
    }
}

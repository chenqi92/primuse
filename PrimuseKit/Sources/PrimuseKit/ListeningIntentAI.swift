import Foundation

/// AI curation of the "for you" intents. The device hands an AI service a
/// summary of the listening profile — folder names, artists, albums, genre,
/// decade and quality shares (play figures only with listening consent) — and
/// asks it to choose, combine and name intents. Every answer is checked here
/// against the profile: references must exist and each intent becomes an
/// ordinary rule that the device lights and plays itself. Whatever cannot be
/// checked is dropped; with no AI at all the device's own intents stand.
public enum ListeningIntentAIExchange {
    public static let maximumIntents = 8
    public static let titleLimit = 24
    static let folderLimit = 10
    static let artistLimit = 16
    static let albumLimit = 8

    public struct Request: Codable, Equatable, Sendable {
        public struct Share: Codable, Equatable, Sendable {
            public var name: String
            public var songs: Double
            public var plays: Double?
        }

        public struct Decade: Codable, Equatable, Sendable {
            public var decade: Int
            public var songs: Double
            public var plays: Double?
        }

        public struct Folder: Codable, Equatable, Sendable {
            public var id: String
            public var name: String
            public var songs: Int
            public var plays: Int?
            public var genres: [String]
            public var artists: [String]
        }

        public struct Artist: Codable, Equatable, Sendable {
            public var id: String
            public var name: String
            public var songs: Int
            public var plays: Int?
        }

        public struct Album: Codable, Equatable, Sendable {
            public var id: String
            public var title: String
            public var artist: String
            public var year: Int?
            public var plays: Int?
        }

        public var language: String
        public var songs: Int
        public var lossless: Double
        public var hires: Double
        public var losslessPlays: Double?
        public var hiresPlays: Double?
        public var genres: [Share]
        public var decades: [Decade]
        public var folders: [Folder]
        public var artists: [Artist]
        public var albums: [Album]
        public var rotation: Int?
        public var maxIntents: Int
    }

    /// What each id in the request stands for. Stays on the device.
    public struct Context: Sendable {
        public var folders: [String: ListeningProfile.Folder]
        public var artists: [String: ListeningProfile.Artist]
        public var albums: [String: ListeningProfile.Album]
    }

    public enum Kind: String, Codable, Sendable {
        case folder, artist, albumLike = "album_like", quality, genreMix = "genre_mix", rotation
    }

    /// One checked answer, before it is turned into a rule.
    public struct Draft: Equatable, Sendable {
        public var kind: Kind
        public var title: String
        public var refs: [String]
        public var genres: [ListeningGenreFamily]
        public var decade: Int?
        public var quality: ListeningAudioQuality?
    }

    // MARK: Request

    public static func prepare(
        profile: ListeningProfile,
        languageCode: String,
        includesListening: Bool
    ) -> (request: Request, context: Context) {
        let listening = includesListening && profile.hasListening
        let library = Double(max(profile.songCount, 1))
        let plays = Double(max(profile.recentPlays, 1))
        func share(_ value: Int, of total: Double) -> Double { (Double(value) / total * 100).rounded() / 100 }

        var folders: [Request.Folder] = []
        var folderContext: [String: ListeningProfile.Folder] = [:]
        for (index, folder) in profile.folders.prefix(folderLimit).enumerated() {
            let id = "f\(index + 1)"
            folderContext[id] = folder
            folders.append(Request.Folder(
                id: id,
                name: folder.name,
                songs: folder.songCount,
                plays: listening ? folder.recentPlays : nil,
                genres: ListeningGenreFamily.allCases.filter { folder.familyMask & $0.bit != 0 }.map(\.rawValue),
                artists: folder.topArtists
            ))
        }

        let artistPool = listening
            ? profile.artists.filter { $0.recentPlays > 0 }
            : profile.artists.sorted { $0.songCount != $1.songCount ? $0.songCount > $1.songCount : $0.key < $1.key }
        var artists: [Request.Artist] = []
        var artistContext: [String: ListeningProfile.Artist] = [:]
        for (index, artist) in artistPool
            .filter({ $0.songCount >= ListeningIntentEngine.minimumSongCount / 2 })
            .prefix(artistLimit)
            .enumerated() {
            let id = "a\(index + 1)"
            artistContext[id] = artist
            artists.append(Request.Artist(id: id, name: artist.name, songs: artist.songCount, plays: listening ? artist.recentPlays : nil))
        }

        var albums: [Request.Album] = []
        var albumContext: [String: ListeningProfile.Album] = [:]
        if listening {
            let played = profile.albums
                .filter { $0.recentPlays > 0 }
                .sorted { $0.recentPlays != $1.recentPlays ? $0.recentPlays > $1.recentPlays : $0.albumID < $1.albumID }
            for (index, album) in played.prefix(albumLimit).enumerated() {
                let id = "b\(index + 1)"
                albumContext[id] = album
                albums.append(Request.Album(id: id, title: album.title, artist: album.artistName, year: album.year, plays: album.recentPlays))
            }
        }

        let genres = ListeningGenreFamily.allCases
            .compactMap { family -> Request.Share? in
                let songs = profile.familySongs[family] ?? 0
                guard Double(songs) >= library * 0.02 else { return nil }
                return Request.Share(
                    name: family.rawValue,
                    songs: share(songs, of: library),
                    plays: listening ? share(profile.familyPlays[family] ?? 0, of: plays) : nil
                )
            }
            .sorted { $0.songs > $1.songs }
        let decades = profile.decadeSongs.keys.sorted()
            .compactMap { decade -> Request.Decade? in
                let songs = profile.decadeSongs[decade] ?? 0
                guard Double(songs) >= library * 0.03 else { return nil }
                return Request.Decade(
                    decade: decade,
                    songs: share(songs, of: library),
                    plays: listening ? share(profile.decadePlays[decade] ?? 0, of: plays) : nil
                )
            }

        let request = Request(
            language: languageCode,
            songs: profile.songCount,
            lossless: share(profile.losslessSongs, of: library),
            hires: share(profile.hiResSongs, of: library),
            losslessPlays: listening ? share(profile.losslessPlays, of: plays) : nil,
            hiresPlays: listening ? share(profile.hiResPlays, of: plays) : nil,
            genres: genres,
            decades: decades,
            folders: folders,
            artists: artists,
            albums: albums,
            rotation: listening && profile.rotationSongIDs.count >= ListeningIntentEngine.minimumSongCount
                ? profile.rotationSongIDs.count
                : nil,
            maxIntents: maximumIntents
        )
        return (request, Context(folders: folderContext, artists: artistContext, albums: albumContext))
    }

    /// Nothing worth asking about: no folders, artists, albums or quality to
    /// work with beyond what the built-in intents already cover.
    public static func isWorthAsking(_ request: Request) -> Bool {
        !request.folders.isEmpty || !request.artists.isEmpty || !request.albums.isEmpty
            || request.lossless >= 0.05 || request.rotation != nil
    }

    public static func payloadJSON(_ request: Request) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(request) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static let instructions = """
    You arrange the "Start listening" shelf of a personal music player for one listener. \
    The input JSON summarises their own library and, when play figures are present, what they listened to in the last 60 days. \
    Shares are fractions of the library ("songs") and of recent plays ("plays"). \
    Folders are folders the listener sorted music into; artists, albums and folders carry ids.

    Suggest up to maxIntents intents that fit this listener. Each is one of:
    - folder: refs = [one folder id]. Use folders whose names describe a kind of music, a mood or a use (for example instrumental, children's songs, driving, workout, a language or a region). Skip folders that are only storage.
    - artist: refs = [1 to 3 artist ids] the listener plays a lot; combine closely related artists into one intent if fitting.
    - album_like: refs = [one album id] the listener plays a lot; it becomes "albums like this one".
    - quality: quality = "lossless" or "hires"; only when they clearly prefer it (lossless/hires plays or a large lossless share). Optional genres (at most 1).
    - genre_mix: genres = 1 or 2 of pop, rock, electronic, classical, jazz, soundtrack, folk, hipHop, easyListening, plus a decade (e.g. 1990) and/or quality. Never a single genre alone and never a decade alone: the shelf already has those.
    - rotation: no refs; only when "rotation" is present.

    Prefer what the listener actually plays, then how they organise their folders. Keep ideas distinct. \
    Titles: short and natural in the language given by "language" (at most 8 CJK characters or 24 Latin characters), no emoji, no quotation marks, no ids. \
    Answer with JSON only: {"intents":[{"kind":"folder","title":"...","refs":["f1"]},{"kind":"genre_mix","title":"...","genres":["pop"],"decade":1990}]}
    """

    // MARK: Answer

    private struct Output: Decodable {
        var intents: [Item]?
    }

    private struct Item: Decodable {
        var kind: String?
        var title: String?
        var refs: [String]?
        var genres: [String]?
        var decade: Int?
        var quality: String?
    }

    /// Reads a model's text answer, tolerating code fences and prose around
    /// the JSON object.
    public static func drafts(fromText text: String, request: Request) throws -> [Draft] {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let output = try? JSONDecoder().decode(Output.self, from: data) else {
            throw ListeningIntentAIExchangeError.unreadableAnswer
        }
        return validated(output.intents ?? [], request: request)
    }

    /// The relay's structured answer.
    public struct RawItem: Equatable, Sendable {
        public var kind: String?
        public var title: String?
        public var refs: [String]?
        public var genres: [String]?
        public var decade: Int?
        public var quality: String?

        public init(kind: String?, title: String?, refs: [String]?, genres: [String]?, decade: Int?, quality: String?) {
            self.kind = kind
            self.title = title
            self.refs = refs
            self.genres = genres
            self.decade = decade
            self.quality = quality
        }
    }

    public static func validated(_ items: [RawItem], request: Request) -> [Draft] {
        validated(items.map {
            Item(kind: $0.kind, title: $0.title, refs: $0.refs, genres: $0.genres, decade: $0.decade, quality: $0.quality)
        }, request: request)
    }

    private static func validated(_ items: [Item], request: Request) -> [Draft] {
        let folderIDs = Set(request.folders.map(\.id))
        let artistIDs = Set(request.artists.map(\.id))
        let albumIDs = Set(request.albums.map(\.id))
        let familiesByName = Dictionary(
            uniqueKeysWithValues: ListeningGenreFamily.allCases.map { ($0.rawValue.lowercased(), $0) }
        )
        var drafts: [Draft] = []
        for item in items {
            guard drafts.count < min(request.maxIntents, maximumIntents),
                  let kind = item.kind.flatMap({ Kind(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) }),
                  let title = cleanTitle(item.title) else { continue }
            let refs = (item.refs ?? []).map { $0.trimmingCharacters(in: .whitespaces) }
            var genres: [ListeningGenreFamily] = []
            for name in item.genres ?? [] {
                guard let family = familiesByName[name.trimmingCharacters(in: .whitespaces).lowercased()],
                      !genres.contains(family) else { continue }
                genres.append(family)
            }
            let decade = item.decade.flatMap { (1950...2030).contains($0) ? $0 / 10 * 10 : nil }
            let quality: ListeningAudioQuality? = switch item.quality?.lowercased() {
            case "lossless": .lossless
            case "hires", "hi-res", "hi_res": .hiRes
            default: nil
            }
            let draft: Draft?
            switch kind {
            case .folder:
                draft = refs.first.flatMap { folderIDs.contains($0) ? Draft(kind: kind, title: title, refs: [$0], genres: [], decade: nil, quality: nil) : nil }
            case .artist:
                let valid = Array(refs.filter(artistIDs.contains).prefix(3))
                draft = valid.isEmpty ? nil : Draft(kind: kind, title: title, refs: valid, genres: [], decade: nil, quality: nil)
            case .albumLike:
                draft = refs.first.flatMap { albumIDs.contains($0) ? Draft(kind: kind, title: title, refs: [$0], genres: [], decade: nil, quality: nil) : nil }
            case .quality:
                draft = quality.map { Draft(kind: kind, title: title, refs: [], genres: Array(genres.prefix(1)), decade: nil, quality: $0) }
            case .genreMix:
                let constraints = (genres.isEmpty ? 0 : 1) + (decade == nil ? 0 : 1) + (quality == nil ? 0 : 1)
                draft = !genres.isEmpty && constraints >= 2
                    ? Draft(kind: kind, title: title, refs: [], genres: Array(genres.prefix(2)), decade: decade, quality: quality)
                    : nil
            case .rotation:
                draft = request.rotation == nil ? nil : Draft(kind: kind, title: title, refs: [], genres: [], decade: nil, quality: nil)
            }
            if let draft, !drafts.contains(where: { $0.kind == draft.kind && $0.refs == draft.refs && $0.genres == draft.genres && $0.decade == draft.decade && $0.quality == draft.quality }) {
                drafts.append(draft)
            }
        }
        return drafts
    }

    static func cleanTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let unquoted = raw.filter { !"\"“”「」『』《》'`".contains($0) }
        let collapsed = unquoted
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        let title = String(collapsed.prefix(titleLimit)).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    // MARK: Intents

    /// Turns checked drafts into intents the device can light and play. An
    /// intent that says the same as one the device made itself keeps that
    /// one's id (so a pin survives) and takes the AI's title.
    public static func intents(
        from drafts: [Draft],
        context: Context,
        profile: ListeningProfile
    ) -> [ListeningIntent] {
        var result: [ListeningIntent] = []
        for draft in drafts {
            var intent: ListeningIntent?
            switch draft.kind {
            case .folder:
                intent = draft.refs.first.flatMap { context.folders[$0] }.map(PersonalListeningIntentPolicy.folderIntent)
            case .artist:
                let artists = draft.refs.compactMap { context.artists[$0] }
                if artists.count == 1 {
                    intent = PersonalListeningIntentPolicy.artistIntent(artists[0])
                } else if !artists.isEmpty {
                    intent = composed(
                        rule: ListeningIntentRule(artistKeys: artists.map(\.key).sorted()),
                        symbolName: "music.mic"
                    )
                }
            case .albumLike:
                intent = draft.refs.first.flatMap { context.albums[$0] }
                    .flatMap { PersonalListeningIntentPolicy.albumLikeIntent($0, profile: profile) }
            case .quality:
                if let quality = draft.quality {
                    if draft.genres.isEmpty {
                        intent = PersonalListeningIntentPolicy.qualityIntent(quality)
                    } else {
                        intent = composed(
                            rule: ListeningIntentRule(genreFamilies: Set(draft.genres), minimumQuality: quality),
                            symbolName: quality == .hiRes ? "hifispeaker.fill" : "waveform"
                        )
                    }
                }
            case .genreMix:
                intent = composed(
                    rule: ListeningIntentRule(
                        genreFamilies: Set(draft.genres),
                        years: draft.decade.map { $0...($0 + 9) },
                        minimumQuality: draft.quality
                    ),
                    symbolName: "sparkles"
                )
            case .rotation:
                intent = PersonalListeningIntentPolicy.rotationIntent(profile)
            }
            guard var intent, !result.contains(where: { $0.id == intent.id }) else { continue }
            intent.customTitle = draft.title
            intent.isAICurated = true
            result.append(intent)
        }
        return result
    }

    private static func composed(rule: ListeningIntentRule, symbolName: String) -> ListeningIntent {
        let id = "ai:" + String(ListeningSeededGenerator.seed(canonical(rule)), radix: 36)
        return ListeningIntent(
            id: "personal:" + id,
            source: .personal(id: id),
            category: .personal,
            symbolName: symbolName,
            titleKey: nil,
            rule: rule
        )
    }

    /// Same rule, same text, whatever order the sets came in.
    static func canonical(_ rule: ListeningIntentRule) -> String {
        var parts: [String] = []
        parts.append("g:" + rule.genreFamilies.map(\.rawValue).sorted().joined(separator: ","))
        if let years = rule.years { parts.append("y:\(years.lowerBound)-\(years.upperBound)") }
        if let quality = rule.minimumQuality { parts.append("q:\(quality.rawValue)") }
        if let artists = rule.artistKeys { parts.append("a:" + artists.sorted().joined(separator: ",")) }
        return parts.joined(separator: "|")
    }
}

public enum ListeningIntentAIExchangeError: Error, Equatable, Sendable {
    case unreadableAnswer
}

public extension PersonalListeningIntentPolicy {
    /// The AI's intents first, in its order, then the device's own that it
    /// did not cover; at most `maximumIntents`.
    static func merged(ai: [ListeningIntent], local: [ListeningIntent]) -> [ListeningIntent] {
        var result = ai
        let used = Set(ai.map(\.id))
        result.append(contentsOf: local.filter { !used.contains($0.id) })
        return Array(result.prefix(maximumIntents))
    }
}

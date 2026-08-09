import Foundation

public enum SiriMediaSearchKind: Sendable, Equatable {
    case song
    case album
    case artist
    case genre
    case playlist
    case radioStation
    case algorithmicRadioStation
    case music
    case unsupported
}

public struct SiriMediaSearchQuery: Sendable {
    public let kind: SiriMediaSearchKind
    public let mediaName: String?
    public let artistName: String?
    public let albumName: String?
    public let genreNames: [String]

    public init(
        kind: SiriMediaSearchKind,
        mediaName: String? = nil,
        artistName: String? = nil,
        albumName: String? = nil,
        genreNames: [String] = []
    ) {
        self.kind = kind
        self.mediaName = Self.nonempty(mediaName)
        self.artistName = Self.nonempty(artistName)
        self.albumName = Self.nonempty(albumName)
        self.genreNames = genreNames.compactMap(Self.nonempty)
    }

    public var hasSearchTerm: Bool {
        mediaName != nil || artistName != nil || albumName != nil || !genreNames.isEmpty
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// Stable identifiers exchanged with Siri, Spotlight, and App Intents.
///
/// Older Primuse builds donated bare IDs while Spotlight has always used a
/// namespaced form (`song:<id>`). Accept both, but reject a value carrying a
/// different known namespace so an unresolved playlist or station can never
/// silently degrade into a random song.
public enum SiriMediaIdentifier {
    private static let knownNamespaces: Set<String> = [
        "song", "album", "artist", "genre", "playlist", "radio", "station",
    ]

    public static func namespaced(_ identifier: String, as namespace: String) -> String {
        "\(namespace.lowercased()):\(identifier)"
    }

    public static func namespace(from identifier: String) -> String? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.firstIndex(of: ":") else { return nil }
        let namespace = String(trimmed[..<separator]).lowercased()
        return knownNamespaces.contains(namespace) ? namespace : nil
    }

    public static func value(
        from identifier: String,
        expectedNamespace: String
    ) -> String? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let separator = trimmed.firstIndex(of: ":") else { return trimmed }
        let namespace = trimmed[..<separator].lowercased()
        guard knownNamespaces.contains(namespace) else {
            // Provider IDs can contain a colon. Only interpret prefixes owned
            // by Primuse as namespaces; preserve every other identifier.
            return trimmed
        }

        let expected = expectedNamespace.lowercased()
        let acceptedNamespaces: Set<String> = expected == "radio"
            ? ["radio", "station"]
            : [expected]
        guard acceptedNamespaces.contains(namespace) else { return nil }

        let value = trimmed[trimmed.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    public static func values(
        from identifiers: [String],
        expectedNamespace: String
    ) -> [String] {
        var seen = Set<String>()
        return identifiers.compactMap {
            guard let value = value(from: $0, expectedNamespace: expectedNamespace),
                  seen.insert(value).inserted else {
                return nil
            }
            return value
        }
    }

    /// Produces the identifier fallback order used by SiriKit handlers.
    /// Resolved media items are authoritative and preserve their queue order;
    /// `mediaSearch.mediaIdentifier` covers newer Siri/Spotlight delivery, and
    /// a container identifier is last.
    public static func prioritized(
        mediaItemIdentifiers: [String],
        searchIdentifier: String?,
        containerIdentifier: String?
    ) -> [String] {
        prioritizedGroups(
            mediaItemIdentifiers: mediaItemIdentifiers,
            searchIdentifier: searchIdentifier,
            containerIdentifier: containerIdentifier
        ).flatMap { $0 }
    }

    /// Keeps Siri's identifier tiers separate. Every resolved media item forms
    /// the authoritative first group; the search and container identifiers are
    /// fallbacks only when no item in an earlier group exists in the library.
    public static func prioritizedGroups(
        mediaItemIdentifiers: [String],
        searchIdentifier: String?,
        containerIdentifier: String?
    ) -> [[String]] {
        var seen = Set<String>()
        let groups: [[String?]] = [
            mediaItemIdentifiers.map { Optional($0) },
            [searchIdentifier],
            [containerIdentifier],
        ]
        return groups.compactMap { group in
            let values: [String] = group.compactMap { value in
                guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty,
                      seen.insert(value).inserted else {
                    return nil
                }
                return value
            }
            return values.isEmpty ? nil : values
        }
    }

    public static func prioritized(
        mediaItemIdentifier: String?,
        searchIdentifier: String?,
        containerIdentifier: String?
    ) -> [String] {
        prioritized(
            mediaItemIdentifiers: [mediaItemIdentifier].compactMap { $0 },
            searchIdentifier: searchIdentifier,
            containerIdentifier: containerIdentifier
        )
    }
}

public struct SiriNamedMediaItem: Sendable, Equatable {
    public let id: String
    public let name: String
    public let aliases: [String]

    public init(id: String, name: String, aliases: [String] = []) {
        self.id = id
        self.name = name
        self.aliases = aliases
    }
}

public struct SiriNamedMediaResolution: Sendable {
    public let selected: SiriNamedMediaItem
    public let candidates: [SiriNamedMediaItem]
    public let needsDisambiguation: Bool
}

/// Shared exact/prefix/substring matching for named containers such as
/// playlists and saved internet-radio stations.
public enum SiriNamedMediaResolver {
    public static func resolve(
        query: String?,
        selectedItemIDs: [String] = [],
        namespace: String,
        items: [SiriNamedMediaItem]
    ) -> SiriNamedMediaResolution? {
        guard !items.isEmpty else { return nil }

        if !selectedItemIDs.isEmpty {
            let values = SiriMediaIdentifier.values(
                from: selectedItemIDs,
                expectedNamespace: namespace
            )
            let itemsByID = Dictionary(
                items.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            guard let selected = values.lazy.compactMap({ itemsByID[$0] }).first else {
                return nil
            }
            return SiriNamedMediaResolution(
                selected: selected,
                candidates: [selected],
                needsDisambiguation: false
            )
        }

        guard let query = nonempty(query) else { return nil }
        let ranked = items.compactMap { item -> (item: SiriNamedMediaItem, score: Int)? in
            let score = ([item.name] + item.aliases)
                .map { matchScore(requested: query, candidate: $0) }
                .max() ?? 0
            return score > 0 ? (item, score) : nil
        }.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let nameOrder = lhs.item.name.localizedCaseInsensitiveCompare(rhs.item.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.item.id < rhs.item.id
        }

        guard let first = ranked.first else { return nil }
        let tied = ranked.prefix { $0.score == first.score }.map(\.item)
        let candidates = tied.count > 1
            ? Array(tied.prefix(8))
            : Array(ranked.prefix(8).map(\.item))
        return SiriNamedMediaResolution(
            selected: first.item,
            candidates: candidates,
            needsDisambiguation: tied.count > 1
        )
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func matchScore(requested: String, candidate: String) -> Int {
        let needle = normalized(requested)
        let value = normalized(candidate)
        guard !needle.isEmpty, !value.isEmpty else { return 0 }
        if value == needle { return 4 }
        if value.hasPrefix(needle) { return 3 }
        if value.contains(needle) { return 2 }
        return 0
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}

public struct SiriMediaSearchResolution: Sendable {
    /// Queue used if the system invokes the handler without first resolving a
    /// concrete media item. Song searches intentionally start with only the
    /// best match; album and artist searches keep the whole matching group.
    public let queue: [Song]

    /// Ranked songs that Siri can use to resolve or disambiguate a song name.
    public let candidates: [Song]

    /// True when the leading candidates are equally plausible and Siri should
    /// ask the user which one they meant instead of guessing.
    public let needsDisambiguation: Bool

    public init(queue: [Song], candidates: [Song], needsDisambiguation: Bool) {
        self.queue = queue
        self.candidates = candidates
        self.needsDisambiguation = needsDisambiguation
    }
}

/// Deterministic, platform-neutral matching for SiriKit and App Intents.
///
/// Siri supplies song, artist, and album names separately when speech
/// recognition succeeds. Ranking exact names ahead of prefix/substring matches
/// avoids picking a remix or similarly named track before the requested song.
public enum SiriMediaSearchResolver {
    public static func resolve(
        query: SiriMediaSearchQuery,
        resolvedItemIDs: [String] = [],
        songs: [Song]
    ) -> SiriMediaSearchResolution? {
        let playable = songs.filteredPlayable()
        guard !playable.isEmpty else { return nil }

        let kind = inferredKind(for: query)

        if !resolvedItemIDs.isEmpty {
            return identifierResolution(
                kind: kind,
                identifiers: resolvedItemIDs,
                songs: playable
            )
        }

        switch kind {
        case .album:
            return albumResolution(query: query, songs: playable)
        case .artist:
            return artistResolution(query: query, songs: playable)
        case .genre:
            return genreResolution(query: query, songs: playable)
        case .song:
            return songResolution(query: query, songs: playable)
        case .music:
            guard !query.hasSearchTerm else {
                return songResolution(query: query, songs: playable)
            }
            return SiriMediaSearchResolution(
                queue: playable,
                candidates: [],
                needsDisambiguation: false
            )
        case .playlist, .radioStation, .algorithmicRadioStation, .unsupported:
            return nil
        }
    }

    private static func identifierResolution(
        kind: SiriMediaSearchKind,
        identifiers: [String],
        songs: [Song]
    ) -> SiriMediaSearchResolution? {
        switch kind {
        case .song, .algorithmicRadioStation:
            return selectedSongResolution(identifiers: identifiers, songs: songs)
        case .album:
            return selectedContainerResolution(
                identifiers: identifiers,
                namespace: "album",
                songs: songs,
                value: \Song.albumID,
                sort: sortedAlbumSongs
            )
        case .artist:
            return selectedContainerResolution(
                identifiers: identifiers,
                namespace: "artist",
                songs: songs,
                value: \Song.artistID,
                sort: { $0.sorted(by: artistQueueBefore) }
            )
        case .genre:
            let values = SiriMediaIdentifier.values(
                from: identifiers,
                expectedNamespace: "genre"
            )
            for value in values {
                let selected = songs.filter {
                    guard let genre = $0.genre else { return false }
                    return normalized(genre) == normalized(value)
                }
                if !selected.isEmpty {
                    let queue = selected.sorted(by: stableSongBefore)
                    return SiriMediaSearchResolution(
                        queue: queue,
                        candidates: queue,
                        needsDisambiguation: false
                    )
                }
            }
            return nil
        case .music:
            var attempted = Set<String>()
            for identifier in identifiers {
                let namespace = SiriMediaIdentifier.namespace(from: identifier) ?? "song"
                guard attempted.insert(namespace).inserted else { continue }
                let selected: SiriMediaSearchResolution? = switch namespace {
                case "song":
                    selectedSongResolution(identifiers: identifiers, songs: songs)
                case "album":
                    identifierResolution(kind: .album, identifiers: identifiers, songs: songs)
                case "artist":
                    identifierResolution(kind: .artist, identifiers: identifiers, songs: songs)
                case "genre":
                    identifierResolution(kind: .genre, identifiers: identifiers, songs: songs)
                default:
                    nil
                }
                if let selected { return selected }
            }
            return nil
        case .playlist, .radioStation, .unsupported:
            return nil
        }
    }

    private static func selectedSongResolution(
        identifiers: [String],
        songs: [Song]
    ) -> SiriMediaSearchResolution? {
        let values = SiriMediaIdentifier.values(
            from: identifiers,
            expectedNamespace: "song"
        )
        guard !values.isEmpty else { return nil }
        let byID = Dictionary(
            songs.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let queue = values.compactMap { byID[$0] }
        guard !queue.isEmpty else { return nil }
        return SiriMediaSearchResolution(
            queue: queue,
            candidates: queue,
            needsDisambiguation: false
        )
    }

    private static func selectedContainerResolution(
        identifiers: [String],
        namespace: String,
        songs: [Song],
        value: KeyPath<Song, String?>,
        sort: ([Song]) -> [Song]
    ) -> SiriMediaSearchResolution? {
        let values = SiriMediaIdentifier.values(
            from: identifiers,
            expectedNamespace: namespace
        )
        for identifier in values {
            let queue = sort(songs.filter { $0[keyPath: value] == identifier })
            guard !queue.isEmpty else { continue }
            return SiriMediaSearchResolution(
                queue: queue,
                candidates: queue,
                needsDisambiguation: false
            )
        }
        return nil
    }

    private static func inferredKind(for query: SiriMediaSearchQuery) -> SiriMediaSearchKind {
        switch query.kind {
        case .album, .artist, .genre, .playlist, .radioStation,
             .algorithmicRadioStation, .song, .unsupported:
            return query.kind
        case .music:
            if query.albumName != nil, query.mediaName == nil { return .album }
            if query.artistName != nil, query.mediaName == nil, query.albumName == nil { return .artist }
            return query.hasSearchTerm ? .song : .music
        }
    }

    private static func genreResolution(
        query: SiriMediaSearchQuery,
        songs: [Song]
    ) -> SiriMediaSearchResolution? {
        let requestedGenres = query.genreNames.isEmpty
            ? [query.mediaName].compactMap { $0 }
            : query.genreNames
        guard !requestedGenres.isEmpty else { return nil }

        let ranked = songs.compactMap { song -> (song: Song, score: Int)? in
            guard let genre = song.genre else { return nil }
            let score = requestedGenres
                .map { matchScore(requested: $0, candidate: genre) }
                .max() ?? 0
            return score > 0 ? (song, score) : nil
        }.sorted(by: rankedBefore)

        guard !ranked.isEmpty else { return nil }
        let queue = ranked.map(\.song)
        return SiriMediaSearchResolution(
            queue: queue,
            candidates: Array(queue.prefix(8)),
            needsDisambiguation: false
        )
    }

    private static func songResolution(
        query: SiriMediaSearchQuery,
        songs: [Song]
    ) -> SiriMediaSearchResolution? {
        guard let requestedTitle = query.mediaName ?? query.albumName ?? query.artistName else {
            return nil
        }

        let ranked = songs.compactMap { song -> (song: Song, score: Int)? in
            let titleScore = bestScore(
                requestedTitle,
                candidates: [song.title, song.titlePinyin]
            )
            guard titleScore > 0 else { return nil }

            var score = titleScore * 100
            if let artistName = query.artistName {
                let artistScore = bestScore(
                    artistName,
                    candidates: [song.artistName, song.artistPinyin]
                )
                guard artistScore > 0 else { return nil }
                score += artistScore * 10
            }
            if let albumName = query.albumName {
                let albumScore = bestScore(
                    albumName,
                    candidates: [song.albumTitle, song.albumPinyin]
                )
                guard albumScore > 0 else { return nil }
                score += albumScore
            }
            return (song, score)
        }.sorted(by: rankedBefore)

        guard let first = ranked.first else { return nil }
        let tied = ranked.prefix { $0.score == first.score }.map(\.song)
        let candidates = tied.count > 1
            ? Array(tied.prefix(8))
            : Array(ranked.prefix(8).map(\.song))
        return SiriMediaSearchResolution(
            queue: [first.song],
            candidates: candidates,
            needsDisambiguation: tied.count > 1
        )
    }

    private static func albumResolution(
        query: SiriMediaSearchQuery,
        songs: [Song]
    ) -> SiriMediaSearchResolution? {
        guard let requestedAlbum = query.albumName ?? query.mediaName else { return nil }
        let groups = Dictionary(grouping: songs, by: albumGroupKey)

        let ranked = groups.values.compactMap { group -> (songs: [Song], score: Int)? in
            guard let representative = group.first else { return nil }
            let albumScore = bestScore(
                requestedAlbum,
                candidates: [representative.albumTitle, representative.albumPinyin]
            )
            guard albumScore > 0 else { return nil }

            var score = albumScore * 10
            if let artistName = query.artistName {
                let artistScore = bestScore(
                    artistName,
                    candidates: [representative.artistName, representative.artistPinyin]
                )
                guard artistScore > 0 else { return nil }
                score += artistScore
            }
            return (sortedAlbumSongs(group), score)
        }.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return stableSongBefore(lhs.songs[0], rhs.songs[0])
        }

        guard let best = ranked.first else { return nil }
        return SiriMediaSearchResolution(
            queue: best.songs,
            candidates: best.songs,
            needsDisambiguation: false
        )
    }

    private static func artistResolution(
        query: SiriMediaSearchQuery,
        songs: [Song]
    ) -> SiriMediaSearchResolution? {
        guard let requestedArtist = query.artistName ?? query.mediaName else { return nil }
        let groups = Dictionary(grouping: songs, by: artistGroupKey)

        let ranked = groups.values.compactMap { group -> (songs: [Song], score: Int)? in
            guard let representative = group.first else { return nil }
            let score = bestScore(
                requestedArtist,
                candidates: [representative.artistName, representative.artistPinyin]
            )
            guard score > 0 else { return nil }
            return (group.sorted(by: artistQueueBefore), score)
        }.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return stableSongBefore(lhs.songs[0], rhs.songs[0])
        }

        guard let best = ranked.first else { return nil }
        return SiriMediaSearchResolution(
            queue: best.songs,
            candidates: best.songs,
            needsDisambiguation: false
        )
    }

    private static func bestScore(_ requested: String, candidates: [String?]) -> Int {
        candidates.compactMap { candidate in
            guard let candidate else { return nil }
            return matchScore(requested: requested, candidate: candidate)
        }.max() ?? 0
    }

    private static func matchScore(requested: String, candidate: String) -> Int {
        let needle = normalized(requested)
        let value = normalized(candidate)
        guard !needle.isEmpty, !value.isEmpty else { return 0 }
        if value == needle { return 4 }
        if value.hasPrefix(needle) { return 3 }
        if value.contains(needle) { return 2 }
        return 0
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func albumGroupKey(_ song: Song) -> String {
        if let albumID = song.albumID, !albumID.isEmpty { return "id:\(albumID)" }
        return "name:\(normalized(song.albumTitle ?? ""))|\(normalized(song.artistName ?? ""))"
    }

    private static func artistGroupKey(_ song: Song) -> String {
        if let artistID = song.artistID, !artistID.isEmpty { return "id:\(artistID)" }
        return "name:\(normalized(song.artistName ?? ""))"
    }

    private static func sortedAlbumSongs(_ songs: [Song]) -> [Song] {
        songs.sorted { lhs, rhs in
            let lhsDisc = lhs.discNumber ?? 0
            let rhsDisc = rhs.discNumber ?? 0
            if lhsDisc != rhsDisc { return lhsDisc < rhsDisc }
            let lhsTrack = lhs.trackNumber ?? 0
            let rhsTrack = rhs.trackNumber ?? 0
            if lhsTrack != rhsTrack { return lhsTrack < rhsTrack }
            return stableSongBefore(lhs, rhs)
        }
    }

    private static func artistQueueBefore(_ lhs: Song, _ rhs: Song) -> Bool {
        let lhsAlbum = normalized(lhs.albumTitle ?? "")
        let rhsAlbum = normalized(rhs.albumTitle ?? "")
        if lhsAlbum != rhsAlbum { return lhsAlbum < rhsAlbum }
        return sortedAlbumSongs([lhs, rhs]).first?.id == lhs.id
    }

    private static func rankedBefore(
        _ lhs: (song: Song, score: Int),
        _ rhs: (song: Song, score: Int)
    ) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return stableSongBefore(lhs.song, rhs.song)
    }

    private static func stableSongBefore(_ lhs: Song, _ rhs: Song) -> Bool {
        let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        let artistOrder = (lhs.artistName ?? "").localizedCaseInsensitiveCompare(rhs.artistName ?? "")
        if artistOrder != .orderedSame { return artistOrder == .orderedAscending }
        return lhs.id < rhs.id
    }
}

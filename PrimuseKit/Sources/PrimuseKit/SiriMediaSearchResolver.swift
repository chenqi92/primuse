import Foundation

public enum SiriMediaSearchKind: Sendable {
    case song
    case album
    case artist
    case music
    case unsupported
}

public struct SiriMediaSearchQuery: Sendable {
    public let kind: SiriMediaSearchKind
    public let mediaName: String?
    public let artistName: String?
    public let albumName: String?

    public init(
        kind: SiriMediaSearchKind,
        mediaName: String? = nil,
        artistName: String? = nil,
        albumName: String? = nil
    ) {
        self.kind = kind
        self.mediaName = Self.nonempty(mediaName)
        self.artistName = Self.nonempty(artistName)
        self.albumName = Self.nonempty(albumName)
    }

    public var hasSearchTerm: Bool {
        mediaName != nil || artistName != nil || albumName != nil
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
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

        if !resolvedItemIDs.isEmpty {
            let byID = Dictionary(
                playable.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let selected = resolvedItemIDs.compactMap { byID[$0] }
            guard !selected.isEmpty else { return nil }
            return SiriMediaSearchResolution(
                queue: selected,
                candidates: selected,
                needsDisambiguation: false
            )
        }

        switch inferredKind(for: query) {
        case .album:
            return albumResolution(query: query, songs: playable)
        case .artist:
            return artistResolution(query: query, songs: playable)
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
        case .unsupported:
            return nil
        }
    }

    private static func inferredKind(for query: SiriMediaSearchQuery) -> SiriMediaSearchKind {
        switch query.kind {
        case .album, .artist, .song, .unsupported:
            return query.kind
        case .music:
            if query.albumName != nil, query.mediaName == nil { return .album }
            if query.artistName != nil, query.mediaName == nil, query.albumName == nil { return .artist }
            return query.hasSearchTerm ? .song : .music
        }
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

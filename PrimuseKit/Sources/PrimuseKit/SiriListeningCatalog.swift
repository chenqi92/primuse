import Foundation

/// Books and podcast shows as Siri sees them: the ones registered as App
/// Shortcut values ("用 Primuse 继续听<书名>", "用 Primuse 播放播客<节目>"),
/// the names spoken requests are matched against, and what to play when
/// nothing is named.
public enum SiriListeningCatalog {
    /// Each registered value is multiplied by every spoken form of the app
    /// name against the 1,000-phrase limit all App Shortcuts share; see
    /// `SiriRadioStationCatalog.appShortcutStationLimit`.
    public static let bookLimit = 8
    public static let podcastShowLimit = 8

    /// Books in "continue listening" order — `SpokenWordBookGrouping.books`
    /// already puts books in progress first, most recent first. Archived
    /// books are not offered; asking for one by name still finds it.
    public static func shortcutBooks(
        _ books: [SpokenWordBook],
        archivedBookIDs: Set<String> = [],
        limit: Int = bookLimit
    ) -> [SpokenWordBook] {
        Array(books.lazy.filter { !archivedBookIDs.contains($0.id) }.prefix(max(0, limit)))
    }

    /// "继续听书" without a title: the book last listened to and not finished
    /// nor archived.
    public static func bookToContinue(
        _ books: [SpokenWordBook],
        archivedBookIDs: Set<String> = []
    ) -> SpokenWordBook? {
        books.filter { $0.isInProgress && !archivedBookIDs.contains($0.id) }.max { lhs, rhs in
            (lhs.lastListenedAt ?? .distantPast) < (rhs.lastListenedAt ?? .distantPast)
        }
    }

    public static func namedItems(books: [SpokenWordBook]) -> [SiriNamedMediaItem] {
        books.map { book in
            SiriNamedMediaItem(
                id: book.id,
                name: book.title,
                aliases: book.author.map { ["\(book.title) \($0)", "\($0) \(book.title)"] } ?? []
            )
        }
    }

    /// Shows with an episode in progress first (most recent first, as
    /// `recentShowIDs` lists them), then the rest in subscription order.
    public static func shortcutShows(
        _ shows: [PodcastShow],
        recentShowIDs: [String],
        limit: Int = podcastShowLimit
    ) -> [PodcastShow] {
        let byID = Dictionary(shows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let recent = recentShowIDs.compactMap { id -> PodcastShow? in
            guard seen.insert(id).inserted else { return nil }
            return byID[id]
        }
        let rest = shows.filter { seen.insert($0.id).inserted }
        return Array((recent + rest).prefix(max(0, limit)))
    }

    public static func namedItems(shows: [PodcastShow]) -> [SiriNamedMediaItem] {
        shows.map { show in
            SiriNamedMediaItem(
                id: show.id,
                name: show.title,
                aliases: show.author.map { ["\(show.title) \($0)"] } ?? []
            )
        }
    }
}

/// A Siri show ID survives a shortcut round trip and identifies which player owns its episodes.
public struct SiriPodcastShow: Sendable, Equatable {
    public let id: String
    public let title: String
    public let author: String?

    private static let libraryPrefix = "library-show:"

    public static func libraryID(for id: String) -> String? {
        id.hasPrefix(libraryPrefix) ? String(id.dropFirst(libraryPrefix.count)) : nil
    }

    public static func needsLibrary(
        subscriptions: [PodcastShow],
        query: String?,
        identifiers: [String],
        needsUnnamedLookup: @autoclosure () -> Bool
    ) -> Bool {
        if SiriRequestNeeds.allRadio(identifiers) { return false }
        let ids = SiriMediaIdentifier.values(from: identifiers, expectedNamespace: "podcastshow")
        if ids.contains(where: { libraryID(for: $0) != nil }) { return true }
        if query == nil, identifiers.isEmpty { return needsUnnamedLookup() }
        let match = SiriNamedMediaResolver.resolve(
            query: query, selectedItemIDs: identifiers, namespace: "podcastshow",
            items: SiriListeningCatalog.namedItems(shows: subscriptions)
        )
        return match?.matchScore != 1_000
    }

    public static func mayHaveNewerLibraryProgress<Position>(
        than subscriptionDate: Date?, positions: [String: Position],
        updatedAt: (Position) -> Date, isFinished: (String) -> Bool
    ) -> Bool {
        positions.contains { id, position in
            !PodcastIdentity.isEpisodeID(id) && !isFinished(id)
                && updatedAt(position) > (subscriptionDate ?? .distantPast)
        }
    }

    public static func mostRecentLibraryEpisode<Position>(
        in positions: [String: Position], newerThan subscriptionDate: Date?,
        updatedAt: (Position) -> Date, playableEpisode: (String) -> Song?
    ) -> Song? {
        var recent: (song: Song, date: Date)?
        for (id, position) in positions {
            let date = updatedAt(position)
            guard date > (subscriptionDate ?? .distantPast), !PodcastIdentity.isEpisodeID(id) else { continue }
            if let recent, recent.date > date || (recent.date == date && recent.song.id <= id) { continue }
            guard let song = playableEpisode(id), song.isPlayable else { continue }
            recent = (song, date)
        }
        return recent?.song
    }

    public static func catalog(
        subscriptions: [PodcastShow],
        libraryEpisodes: [Song],
        libraryShowCount: Int,
        limit: Int = .max,
        placement: (String) -> (id: String, title: String)?
    ) -> [Self] {
        var shows = subscriptions.prefix(max(0, limit)).map { Self(id: $0.id, title: $0.title, author: $0.author) }
        guard shows.count < limit, libraryShowCount > 0 else { return shows }
        var seen = Set<String>()
        for song in libraryEpisodes {
            guard let group = placement(song.id), seen.insert(group.id).inserted else { continue }
            shows.append(Self(id: libraryPrefix + group.id, title: group.title, author: song.albumArtistName ?? song.artistName))
            if shows.count >= limit || seen.count == libraryShowCount { break }
        }
        return shows
    }

    public static func namedItems(_ shows: [Self], query: String?, identifiers: [String] = []) -> [SiriNamedMediaItem] {
        let groups = Dictionary(grouping: shows) { libraryID(for: $0.id) != nil }
        func candidates(from group: [Self]?) -> SiriNamedMediaResolution? {
            let items = (group ?? []).map { show in
                SiriNamedMediaItem(id: show.id, name: show.title, aliases: show.author.map { ["\(show.title) \($0)"] } ?? [])
            }
            return SiriNamedMediaResolver.resolve(query: query, selectedItemIDs: identifiers, namespace: "podcastshow", items: items)
        }
        let rss = candidates(from: groups[false])
        let library = candidates(from: groups[true])
        if let rss, rss.matchScore >= (library?.matchScore ?? 0) { return rss.candidates }
        return library?.candidates ?? []
    }
}

/// What "用 Primuse 定时…" asks for, resolved against what is playing.
public enum SiriSleepTimerRequest: String, CaseIterable, Sendable {
    case minutes15
    case minutes30
    case minutes45
    case minutes60
    case minutes90
    case endOfTrack
    case endOfChapter
    case off

    public enum Resolution: Equatable, Sendable {
        case set(SleepTimerOption)
        case cancel
        /// "Stop at the end" of a live stream, or with nothing playing.
        case unavailable
    }

    /// - Parameters:
    ///   - space: what is playing; nil when nothing is.
    ///   - hasChapters: the spoken-word item carries chapter marks.
    public func resolution(space: ListeningSpace?, hasChapters: Bool) -> Resolution {
        switch self {
        case .minutes15: return .set(.minutes(15))
        case .minutes30: return .set(.minutes(30))
        case .minutes45: return .set(.minutes(45))
        case .minutes60: return .set(.minutes(60))
        case .minutes90: return .set(.minutes(90))
        case .off: return .cancel
        case .endOfTrack, .endOfChapter:
            // 直播没有尽头;环境音循环着放,「播完这一首」没有意义。
            guard let space, space != .radio, space != .ambient else { return .unavailable }
            // Without chapter marks the item itself is the chapter; music has
            // no chapters, so "this chapter" means this song.
            if self == .endOfChapter,
               hasChapters,
               space == .spokenWord || space == .podcast {
                return .set(.endOfChapter)
            }
            return .set(.endOfTrack)
        }
    }
}

/// Spoken-word items a lookup found are never queued as songs: they play as
/// part of their book, in reading order and at the book's speed. A request
/// that named the item (a chapter, a 相声 piece) starts from it; one that
/// named an album, an artist or a genre continues the book listened to last
/// among those found, where it was left.
public enum SiriSpokenWordRouting {
    public struct Start: Sendable, Equatable {
        public let bookID: String
        /// The item to start from; nil continues where the book was left.
        public let itemID: String?

        public init(bookID: String, itemID: String?) {
            self.bookID = bookID
            self.itemID = itemID
        }
    }

    /// Nil when the best item found is music: a music lookup reaches
    /// spoken-word items only when no music answers it, so a queue never
    /// mixes the two.
    public static func start(
        forFoundSongIDs songIDs: [String],
        bookID: (String) -> String?,
        books: [SpokenWordBook],
        namesItem: Bool
    ) -> Start? {
        guard let first = songIDs.first, let firstBook = bookID(first) else { return nil }
        if namesItem { return Start(bookID: firstBook, itemID: first) }
        var foundBookIDs = Set<String>()
        for songID in songIDs {
            if let id = bookID(songID) { foundBookIDs.insert(id) }
        }
        let continuing = SiriListeningCatalog.bookToContinue(books.filter { foundBookIDs.contains($0.id) })
        return Start(bookID: continuing?.id ?? firstBook, itemID: nil)
    }

    /// Whether a lookup named one item by its title (or Siri chose songs),
    /// rather than a container.
    public static func namesItem(_ query: SiriMediaSearchQuery, identifiers: [String]) -> Bool {
        if !identifiers.isEmpty {
            return identifiers.allSatisfy {
                let namespace = SiriMediaIdentifier.namespace(from: $0)
                return namespace == nil || namespace == "song"
            }
        }
        switch query.kind {
        case .song:
            return true
        case .music:
            return query.mediaName != nil
        case .album, .artist, .genre, .playlist, .radioStation, .algorithmicRadioStation,
             .audiobook, .podcast, .unsupported:
            return false
        }
    }
}

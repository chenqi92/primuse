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
    /// already puts books in progress first, most recent first.
    public static func shortcutBooks(
        _ books: [SpokenWordBook],
        limit: Int = bookLimit
    ) -> [SpokenWordBook] {
        Array(books.prefix(max(0, limit)))
    }

    /// "继续听书" without a title: the book last listened to and not finished.
    public static func bookToContinue(_ books: [SpokenWordBook]) -> SpokenWordBook? {
        books.filter(\.isInProgress).max { lhs, rhs in
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
            guard let space, space != .radio else { return .unavailable }
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

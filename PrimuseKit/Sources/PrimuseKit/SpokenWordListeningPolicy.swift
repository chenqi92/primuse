import Foundation

// MARK: - Bookmarks

/// A position inside a spoken-word item the listener wants to come back to:
/// a passage to quote, the place a chapter really started, where they dozed
/// off. Unlike the single resume position it is explicit and there can be
/// many per item.
public struct SpokenWordBookmark: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var songID: String
    public var position: TimeInterval
    /// What the listener typed, or the chapter title / time it was made at.
    public var title: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        songID: String,
        position: TimeInterval,
        title: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.songID = songID
        self.position = position
        self.title = title
        self.createdAt = createdAt
    }
}

public enum SpokenWordBookmarkPolicy {
    /// More than this per item is a table of contents, not bookmarks; the
    /// oldest is dropped so the store cannot grow without bound.
    public static let maximumPerItem = 50

    /// Two bookmarks this close together are the same place pressed twice.
    public static let duplicateTolerance: TimeInterval = 2

    /// Inserts a bookmark keeping the list ordered by position, collapsing a
    /// press within `duplicateTolerance` of an existing mark into that mark.
    public static func inserting(
        _ bookmark: SpokenWordBookmark,
        into bookmarks: [SpokenWordBookmark]
    ) -> [SpokenWordBookmark] {
        guard bookmark.position.isFinite, bookmark.position >= 0 else { return bookmarks }
        if bookmarks.contains(where: { abs($0.position - bookmark.position) <= duplicateTolerance }) {
            return bookmarks
        }
        var result = bookmarks
        result.append(bookmark)
        result.sort { $0.position < $1.position }
        if result.count > maximumPerItem {
            // Drop the oldest, not the first by position: the listener keeps
            // what they marked most recently.
            let oldest = result.min { $0.createdAt < $1.createdAt }
            result.removeAll { $0.id == oldest?.id }
        }
        return result
    }
}

// MARK: - Playback rate

/// Spoken word is listened to faster than music is: 1.25× or 1.5× is the
/// normal setting for a book, and it must not carry over to the next song.
/// The two rates are therefore separate settings, and which one the engine
/// runs at follows the item that is playing.
public enum SpokenWordPlaybackRatePolicy {
    public static let minimumRate: Float = 0.5
    public static let maximumRate: Float = 2.0
    public static let presets: [Float] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    public static func clamped(_ rate: Float) -> Float {
        guard rate.isFinite else { return 1 }
        return min(maximumRate, max(minimumRate, rate))
    }

    /// The rate the engine should run at right now.
    /// - Parameter rateAllowed: false when the output path cannot time-stretch
    ///   (high-fidelity passthrough), where everything plays at 1×.
    public static func effectiveRate(
        isSpokenWord: Bool,
        musicRate: Float,
        spokenWordRate: Float,
        rateAllowed: Bool
    ) -> Float {
        guard rateAllowed else { return 1 }
        return clamped(isSpokenWord ? spokenWordRate : musicRate)
    }

    public static func label(for rate: Float) -> String {
        let rounded = (rate * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return String(format: "%.0f×", rounded)
        }
        var text = String(format: "%.2f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        return text + "×"
    }
}

// MARK: - Skip intervals

extension SpokenWordSkipPolicy {
    /// The intervals SF Symbols has a `goforward.N` / `gobackward.N` glyph
    /// for, which is what the transport draws.
    public static let allowedIntervals: [Int] = [5, 10, 15, 30, 45, 60, 90]

    /// Snaps a stored value to the nearest allowed interval so a hand-edited
    /// or future value still has a glyph.
    public static func clampedInterval(_ seconds: Int) -> Int {
        allowedIntervals.min {
            abs($0 - seconds) < abs($1 - seconds)
                || (abs($0 - seconds) == abs($1 - seconds) && $0 < $1)
        } ?? Int(forwardInterval)
    }

    public static func symbolName(forward: Bool, interval seconds: Int) -> String {
        let interval = clampedInterval(seconds)
        return (forward ? "goforward." : "gobackward.") + String(interval)
    }
}

// MARK: - Sleep at chapter end

/// "Stop after this chapter": the timer is armed on the chapter the play head
/// is in and fires the moment the head leaves it forwards. Leaving backwards
/// (the listener rewound into the previous chapter) keeps the timer armed on
/// the original chapter so it still stops where they asked.
public enum SpokenWordChapterSleepPolicy {
    public static func shouldStop(
        lockedChapterIndex: Int,
        currentChapterIndex: Int?
    ) -> Bool {
        guard let currentChapterIndex else { return false }
        return currentChapterIndex > lockedChapterIndex
    }
}

// MARK: - Books

/// One spoken-word item as the book grouping sees it. Deliberately not the
/// library's `Song`: the grouping is pure and runs wherever it is handed a
/// list.
public struct SpokenWordBookItem: Hashable, Sendable {
    public var id: String
    public var title: String
    public var albumTitle: String?
    public var albumArtist: String?
    public var artist: String?
    public var discNumber: Int?
    public var trackNumber: Int?
    public var duration: TimeInterval
    public var fileName: String
    /// Where the listener is in this item, if they are part way through.
    public var position: TimeInterval?
    public var positionUpdatedAt: Date?
    /// When the item was listened to the end, if it was.
    public var finishedAt: Date?

    public init(
        id: String,
        title: String,
        albumTitle: String? = nil,
        albumArtist: String? = nil,
        artist: String? = nil,
        discNumber: Int? = nil,
        trackNumber: Int? = nil,
        duration: TimeInterval,
        fileName: String = "",
        position: TimeInterval? = nil,
        positionUpdatedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.albumTitle = albumTitle
        self.albumArtist = albumArtist
        self.artist = artist
        self.discNumber = discNumber
        self.trackNumber = trackNumber
        self.duration = duration
        self.fileName = fileName
        self.position = position
        self.positionUpdatedAt = positionUpdatedAt
        self.finishedAt = finishedAt
    }

    public var isFinished: Bool { finishedAt != nil }
    public var isInProgress: Bool { position != nil && !isFinished }

    public var fractionComplete: Double {
        if isFinished { return 1 }
        guard let position, duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }
}

/// A book, series or lecture course: the items that share an album, in the
/// order they are meant to be heard, with where the listener is in it.
public struct SpokenWordBook: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let author: String?
    public let items: [SpokenWordBookItem]
    /// The item "continue" starts from, or nil when every item is finished.
    public let resumeItemID: String?
    public let lastListenedAt: Date?

    public var chapterCount: Int { items.count }
    public var finishedCount: Int { items.filter(\.isFinished).count }
    public var totalDuration: TimeInterval { items.reduce(0) { $0 + max(0, $1.duration) } }
    public var isFinished: Bool { !items.isEmpty && finishedCount == items.count }
    /// Started and not finished: what the "continue listening" shelf shows.
    public var isInProgress: Bool { lastListenedAt != nil && !isFinished }

    public var resumeItem: SpokenWordBookItem? {
        guard let resumeItemID else { return nil }
        return items.first { $0.id == resumeItemID }
    }

    /// Overall progress through the book: finished items count whole, the
    /// item being listened to counts by its own fraction, by duration where
    /// it is known so a two-minute preface does not weigh like a two-hour
    /// chapter.
    public var fractionComplete: Double {
        guard !items.isEmpty else { return 0 }
        let total = totalDuration
        if total > 0, items.allSatisfy({ $0.duration > 0 }) {
            let done = items.reduce(0.0) { $0 + $1.duration * $1.fractionComplete }
            return min(1, max(0, done / total))
        }
        let done = items.reduce(0.0) { $0 + $1.fractionComplete }
        return min(1, max(0, done / Double(items.count)))
    }

    /// Time left, for the shelf: nil when a duration is unknown.
    public var remainingDuration: TimeInterval? {
        guard items.allSatisfy({ $0.duration > 0 }) else { return nil }
        return items.reduce(0.0) { $0 + $1.duration * (1 - $1.fractionComplete) }
    }
}

public enum SpokenWordBookGrouping {
    /// Groups items into books.
    ///
    /// Items sharing an album title and author form one book; an item with
    /// no album stands alone as a one-item book. Within a book the order is
    /// disc, track, then file name — the order the files were numbered in —
    /// and never the position, so a rewind does not reorder chapters.
    /// Books come back with the ones being listened to first, most recent
    /// first, then the rest by title.
    public static func books(from items: [SpokenWordBookItem]) -> [SpokenWordBook] {
        var groups: [String: [SpokenWordBookItem]] = [:]
        var order: [String] = []
        for item in items {
            let key = groupingKey(for: item)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }

        let books = order.map { key -> SpokenWordBook in
            let members = (groups[key] ?? []).sorted(by: chapterOrder)
            return makeBook(id: key, items: members)
        }
        return books.sorted(by: shelfOrder)
    }

    static func groupingKey(for item: SpokenWordBookItem) -> String {
        let album = normalized(item.albumTitle)
        guard !album.isEmpty else { return "item:" + item.id }
        let author = normalized(item.albumArtist).isEmpty
            ? normalized(item.artist)
            : normalized(item.albumArtist)
        return "book:" + album + "\u{1F}" + author
    }

    private static func normalized(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func chapterOrder(_ lhs: SpokenWordBookItem, _ rhs: SpokenWordBookItem) -> Bool {
        let leftDisc = lhs.discNumber ?? 1
        let rightDisc = rhs.discNumber ?? 1
        if leftDisc != rightDisc { return leftDisc < rightDisc }
        switch (lhs.trackNumber, rhs.trackNumber) {
        case let (left?, right?) where left != right:
            return left < right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            break
        }
        let byFile = lhs.fileName.localizedStandardCompare(rhs.fileName)
        if byFile != .orderedSame { return byFile == .orderedAscending }
        let byTitle = lhs.title.localizedStandardCompare(rhs.title)
        if byTitle != .orderedSame { return byTitle == .orderedAscending }
        return lhs.id < rhs.id
    }

    private static func shelfOrder(_ lhs: SpokenWordBook, _ rhs: SpokenWordBook) -> Bool {
        switch (lhs.isInProgress, rhs.isInProgress) {
        case (true, false): return true
        case (false, true): return false
        case (true, true):
            let left = lhs.lastListenedAt ?? .distantPast
            let right = rhs.lastListenedAt ?? .distantPast
            if left != right { return left > right }
        default:
            break
        }
        let byTitle = lhs.title.localizedStandardCompare(rhs.title)
        if byTitle != .orderedSame { return byTitle == .orderedAscending }
        return lhs.id < rhs.id
    }

    private static func makeBook(id: String, items: [SpokenWordBookItem]) -> SpokenWordBook {
        let first = items[0]
        let albumTitle = first.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = id.hasPrefix("item:") || albumTitle.isEmpty ? first.title : albumTitle
        let authorCandidates = [first.albumArtist, first.artist]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let author = authorCandidates.first

        let lastListenedAt = items
            .flatMap { [$0.positionUpdatedAt, $0.finishedAt] }
            .compactMap { $0 }
            .max()

        // Continue from what was heard most recently if it is unfinished;
        // otherwise the first chapter not yet heard, in reading order.
        let resumeItemID: String?
        if let recent = items
            .filter(\.isInProgress)
            .max(by: { ($0.positionUpdatedAt ?? .distantPast) < ($1.positionUpdatedAt ?? .distantPast) }) {
            resumeItemID = recent.id
        } else {
            resumeItemID = items.first { !$0.isFinished }?.id
        }

        return SpokenWordBook(
            id: id,
            title: title,
            author: author,
            items: items,
            resumeItemID: resumeItemID,
            lastListenedAt: lastListenedAt
        )
    }
}

/// The spoken-word list on CarPlay: what a driver wants within reach is the
/// book they are in the middle of, so it comes first, then the rest of the
/// shelf, then what they have finished — recent listening first, which is
/// also the listening history.
public enum SpokenWordCarPlayShelfPolicy {
    public enum Section: Equatable, Sendable {
        case continueListening
        case shelf
        case finished
    }

    /// - Parameters:
    ///   - books: as `SpokenWordBookGrouping.books` returns them.
    ///   - limit: how many rows the car's list takes in total.
    public static func sections(
        from books: [SpokenWordBook],
        limit: Int
    ) -> [(section: Section, books: [SpokenWordBook])] {
        let inProgress = books.filter(\.isInProgress)
            .sorted { ($0.lastListenedAt ?? .distantPast) > ($1.lastListenedAt ?? .distantPast) }
        let shelf = books.filter { !$0.isInProgress && !$0.isFinished }
        let finished = books.filter(\.isFinished)
            .sorted { ($0.lastListenedAt ?? .distantPast) > ($1.lastListenedAt ?? .distantPast) }
        var remaining = max(0, limit)
        var result: [(section: Section, books: [SpokenWordBook])] = []
        for (section, group) in [(Section.continueListening, inProgress), (.shelf, shelf), (.finished, finished)] {
            guard remaining > 0, !group.isEmpty else { continue }
            let taken = Array(group.prefix(remaining))
            remaining -= taken.count
            result.append((section, taken))
        }
        return result
    }

    /// Where playing a book starts: the item asked for, else where the
    /// listener left off, else the first.
    public static func startItemID(for book: SpokenWordBook, requested: String? = nil) -> String? {
        if let requested, book.items.contains(where: { $0.id == requested }) { return requested }
        return book.resumeItemID ?? book.items.first?.id
    }
}

import Foundation

// MARK: - Where the listener is in the book

/// What the spoken-word player shows about the book as a whole: which part
/// is playing, how far through the book the listener is and how long is left.
///
/// A "part" is what the listener moves between with the previous / next
/// buttons and what the contents list numbers: the book's files when it is
/// split into several, the chapter marks when it is one file that carries
/// them. Both are called 章 in the interface; titles written into the files
/// ("第十二回", "Part 3") are shown as they are.
public struct SpokenWordNowPlayingSummary: Equatable, Sendable {
    /// 1-based index of the playing part and the number of parts; nil when
    /// the book is one file without chapter marks.
    public var partIndex: Int?
    public var partCount: Int?
    /// The part numbering follows the file's chapter marks rather than the
    /// book's files.
    public var partsAreChapterMarks: Bool
    /// 0…1 through the whole book, the playing item counted at the play head.
    public var bookFraction: Double
    /// Content time left in the book (not scaled by the speed); nil while a
    /// duration in the book is unknown, so the player never guesses.
    public var bookRemaining: TimeInterval?

    public init(
        partIndex: Int? = nil,
        partCount: Int? = nil,
        partsAreChapterMarks: Bool = false,
        bookFraction: Double = 0,
        bookRemaining: TimeInterval? = nil
    ) {
        self.partIndex = partIndex
        self.partCount = partCount
        self.partsAreChapterMarks = partsAreChapterMarks
        self.bookFraction = bookFraction
        self.bookRemaining = bookRemaining
    }
}

public enum SpokenWordNowPlayingPolicy {
    /// - Parameters:
    ///   - book: the book the playing item belongs to, as the shelf builds it
    ///     (stored positions). Nil when it cannot be found; the item is then
    ///     treated as a book of its own.
    ///   - position: the live play head. The store is written every few
    ///     seconds, so the book's copy of the playing item lags behind it.
    ///   - duration: the playing item's duration as the decoder reports it;
    ///     preferred over the library's when known.
    ///   - chapterCount / currentChapterIndex: the playing file's marks.
    public static func summary(
        book: SpokenWordBook?,
        currentItemID: String,
        position: TimeInterval,
        duration: TimeInterval,
        chapterCount: Int,
        currentChapterIndex: Int?
    ) -> SpokenWordNowPlayingSummary {
        let livePosition = position.isFinite ? max(0, position) : 0
        var items = book?.items ?? []
        if let index = items.firstIndex(where: { $0.id == currentItemID }) {
            var current = items[index]
            if duration > 0 { current.duration = duration }
            current.position = livePosition
            current.finishedAt = nil
            items[index] = current
        } else {
            items = [SpokenWordBookItem(
                id: currentItemID,
                title: "",
                duration: max(0, duration),
                position: livePosition
            )]
        }

        var summary = SpokenWordNowPlayingSummary()
        if items.count > 1, let index = items.firstIndex(where: { $0.id == currentItemID }) {
            summary.partIndex = index + 1
            summary.partCount = items.count
        } else if chapterCount > 1 {
            summary.partIndex = (currentChapterIndex ?? 0) + 1
            summary.partCount = chapterCount
            summary.partsAreChapterMarks = true
        }

        let live = SpokenWordBook(
            id: book?.id ?? currentItemID,
            title: book?.title ?? "",
            author: book?.author,
            items: items,
            resumeItemID: currentItemID,
            lastListenedAt: book?.lastListenedAt
        )
        summary.bookFraction = live.fractionComplete
        summary.bookRemaining = live.remainingDuration
        return summary
    }

    /// Content time turned into listening time at `rate`: an hour of book at
    /// 1.5× is forty minutes of listening.
    public static func listeningTime(forContent seconds: TimeInterval, rate: Float) -> TimeInterval {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let rate = Double(SpokenWordPlaybackRatePolicy.clamped(rate))
        return seconds / rate
    }

    /// Content time left in the part being heard: to the next chapter mark
    /// when the file has marks, to the end of the file otherwise. Nil when
    /// the end is unknown.
    public static func partRemaining(
        position: TimeInterval,
        duration: TimeInterval,
        chapters: [MediaChapter],
        currentChapterIndex: Int?
    ) -> TimeInterval? {
        let position = position.isFinite ? max(0, position) : 0
        if let index = currentChapterIndex, chapters.indices.contains(index), index + 1 < chapters.count {
            return max(0, chapters[index + 1].startTime - position)
        }
        guard duration.isFinite, duration > 0 else { return nil }
        return max(0, duration - position)
    }

    /// Where the bookmark ticks sit on the progress bar, 0…1, for the marks
    /// of the playing item. Marks past the end are dropped.
    public static func bookmarkFractions(
        _ bookmarks: [SpokenWordBookmark],
        duration: TimeInterval
    ) -> [Double] {
        guard duration.isFinite, duration > 0 else { return [] }
        return bookmarks
            .map { $0.position / duration }
            .filter { $0 >= 0 && $0 <= 1 }
            .sorted()
    }
}

// MARK: - Contents

/// One row of a book's contents: an item of the book, or a chapter mark of
/// the item that is playing.
public struct SpokenWordContentsRow: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A file of the book.
        case item
        /// A chapter mark inside `itemID`, `startTime` into it.
        case chapter(index: Int, startTime: TimeInterval)
    }

    public enum State: Equatable, Sendable {
        case unplayed
        /// Started, `fraction` of the way through.
        case inProgress(fraction: Double)
        /// Under the play head.
        case current(fraction: Double)
        case finished
    }

    public var kind: Kind
    public var itemID: String
    /// 1-based number the list shows. Nested chapters number within their item.
    public var number: Int
    public var title: String
    /// Content duration; nil when unknown.
    public var duration: TimeInterval?
    public var state: State
    /// Drawn indented under its item.
    public var isNested: Bool

    public var id: String {
        switch kind {
        case .item: return "item:\(itemID)"
        case let .chapter(index, _): return "chapter:\(itemID):\(index)"
        }
    }

    public var isCurrent: Bool {
        if case .current = state { return true }
        return false
    }

    public init(
        kind: Kind,
        itemID: String,
        number: Int,
        title: String,
        duration: TimeInterval?,
        state: State,
        isNested: Bool
    ) {
        self.kind = kind
        self.itemID = itemID
        self.number = number
        self.title = title
        self.duration = duration
        self.state = state
        self.isNested = isNested
    }
}

public enum SpokenWordContentsPolicy {
    /// The contents list of the book being heard.
    ///
    /// - A book of several files lists the files. When the playing file
    ///   carries chapter marks of its own, they are listed under it, so a
    ///   series of long m4b volumes can still be navigated inside a volume.
    /// - A book that is one file lists that file's chapter marks.
    /// - One file without marks lists just itself.
    ///
    /// - Parameters:
    ///   - book: the book as the shelf builds it; nil treats the playing item
    ///     as a book of its own.
    ///   - currentItemID: the item playing, nil when the book is not playing.
    ///   - position / duration: the live play head in the playing item.
    ///   - chapters: the playing item's marks.
    public static func rows(
        book: SpokenWordBook?,
        currentItemID: String?,
        currentItemTitle: String = "",
        position: TimeInterval,
        duration: TimeInterval,
        chapters: [MediaChapter],
        currentChapterIndex: Int?
    ) -> [SpokenWordContentsRow] {
        let livePosition = position.isFinite ? max(0, position) : 0
        var items = book?.items ?? []
        if items.isEmpty, let currentItemID {
            items = [SpokenWordBookItem(
                id: currentItemID,
                title: currentItemTitle,
                duration: max(0, duration),
                position: livePosition
            )]
        }

        if items.count == 1, chapters.count > 1, items[0].id == currentItemID {
            return chapterRows(
                itemID: items[0].id,
                position: livePosition,
                duration: duration > 0 ? duration : items[0].duration,
                chapters: chapters,
                currentChapterIndex: currentChapterIndex,
                nested: false
            )
        }

        var rows: [SpokenWordContentsRow] = []
        for (offset, item) in items.enumerated() {
            let isPlaying = item.id == currentItemID
            let itemDuration = isPlaying && duration > 0 ? duration : item.duration
            let state: SpokenWordContentsRow.State
            if isPlaying {
                let fraction = itemDuration > 0 ? min(1, livePosition / itemDuration) : 0
                state = .current(fraction: fraction)
            } else if item.isFinished {
                state = .finished
            } else if item.isInProgress {
                state = .inProgress(fraction: item.fractionComplete)
            } else {
                state = .unplayed
            }
            rows.append(SpokenWordContentsRow(
                kind: .item,
                itemID: item.id,
                number: offset + 1,
                title: item.title,
                duration: itemDuration > 0 ? itemDuration : nil,
                state: state,
                isNested: false
            ))
            if isPlaying, chapters.count > 1 {
                rows += chapterRows(
                    itemID: item.id,
                    position: livePosition,
                    duration: itemDuration,
                    chapters: chapters,
                    currentChapterIndex: currentChapterIndex,
                    nested: true
                )
            }
        }
        return rows
    }

    private static func chapterRows(
        itemID: String,
        position: TimeInterval,
        duration: TimeInterval,
        chapters: [MediaChapter],
        currentChapterIndex: Int?,
        nested: Bool
    ) -> [SpokenWordContentsRow] {
        chapters.enumerated().map { index, chapter in
            let end = index + 1 < chapters.count ? chapters[index + 1].startTime : duration
            let length = end > chapter.startTime ? end - chapter.startTime : nil
            let state: SpokenWordContentsRow.State
            if index == currentChapterIndex {
                let fraction = length.map { min(1, max(0, (position - chapter.startTime) / $0)) } ?? 0
                state = .current(fraction: fraction)
            } else if let currentChapterIndex, index < currentChapterIndex {
                state = .finished
            } else {
                state = .unplayed
            }
            return SpokenWordContentsRow(
                kind: .chapter(index: index, startTime: chapter.startTime),
                itemID: itemID,
                number: index + 1,
                title: chapter.title,
                duration: length,
                state: state,
                isNested: nested
            )
        }
    }

    /// Index of the row to scroll to when the list opens: the one playing,
    /// else where the book resumes, else the top.
    public static func initialRowIndex(
        in rows: [SpokenWordContentsRow],
        resumeItemID: String?
    ) -> Int? {
        if let current = rows.lastIndex(where: \.isCurrent) { return current }
        if let resumeItemID,
           let index = rows.firstIndex(where: { $0.kind == .item && $0.itemID == resumeItemID }) {
            return index
        }
        return rows.isEmpty ? nil : 0
    }
}

// MARK: - Bookmarks across a book

public enum SpokenWordBookBookmarkPolicy {
    public struct Entry: Identifiable, Equatable, Sendable {
        public var bookmark: SpokenWordBookmark
        /// 1-based number of the item it was made in; nil for a one-file book.
        public var partNumber: Int?
        public var id: UUID { bookmark.id }

        public init(bookmark: SpokenWordBookmark, partNumber: Int?) {
            self.bookmark = bookmark
            self.partNumber = partNumber
        }
    }

    /// Every bookmark in the book, in reading order: by item, then by
    /// position within the item.
    public static func entries(
        itemIDs: [String],
        bookmarks: (String) -> [SpokenWordBookmark]
    ) -> [Entry] {
        let numbered = itemIDs.count > 1
        return itemIDs.enumerated().flatMap { offset, itemID in
            bookmarks(itemID)
                .sorted { $0.position < $1.position }
                .map { Entry(bookmark: $0, partNumber: numbered ? offset + 1 : nil) }
        }
    }
}

// MARK: - Moving between parts

/// What the previous / next part buttons do. Chapter marks inside the file
/// come first; at the first or last mark (or without marks) the button moves
/// to the neighbouring file of the book.
public enum SpokenWordPartNavigationPolicy {
    public enum Move: Equatable, Sendable {
        case seekToChapter(Int)
        case restartItem
        case previousItem
        case nextItem
        case none
    }

    /// Within this many seconds of a part's start, "previous" goes to the
    /// previous part instead of back to the start of this one.
    public static let restartThreshold: TimeInterval = 3

    public static func previous(
        position: TimeInterval,
        chapters: [MediaChapter],
        currentChapterIndex: Int?,
        hasPreviousItem: Bool
    ) -> Move {
        if let index = currentChapterIndex, chapters.indices.contains(index) {
            if position - chapters[index].startTime > restartThreshold { return .seekToChapter(index) }
            if index > 0 { return .seekToChapter(index - 1) }
        }
        if position > restartThreshold { return .restartItem }
        return hasPreviousItem ? .previousItem : .restartItem
    }

    public static func next(
        chapters: [MediaChapter],
        currentChapterIndex: Int?,
        hasNextItem: Bool
    ) -> Move {
        if !chapters.isEmpty {
            let next = (currentChapterIndex ?? -1) + 1
            if chapters.indices.contains(next) { return .seekToChapter(next) }
        }
        return hasNextItem ? .nextItem : .none
    }

    public static func canGoNext(
        chapters: [MediaChapter],
        currentChapterIndex: Int?,
        hasNextItem: Bool
    ) -> Bool {
        next(chapters: chapters, currentChapterIndex: currentChapterIndex, hasNextItem: hasNextItem) != .none
    }
}

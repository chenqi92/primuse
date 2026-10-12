import Foundation

/// What the store holds about listening to one item: where the listener is
/// and when that was saved, when it was heard to the end, and the duration
/// heard (for a file whose tags give none).
public struct SpokenWordItemProgress: Equatable, Sendable {
    public var knownDuration: TimeInterval?
    public var position: TimeInterval?
    public var positionUpdatedAt: Date?
    public var finishedAt: Date?

    public init(
        knownDuration: TimeInterval? = nil,
        position: TimeInterval? = nil,
        positionUpdatedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        self.knownDuration = knownDuration
        self.position = position
        self.positionUpdatedAt = positionUpdatedAt
        self.finishedAt = finishedAt
    }
}

extension SpokenWordBookItem {
    /// This item with its listening progress replaced, as `init(song:…)`
    /// builds it: the duration follows the progress only for a song that
    /// has none of its own.
    public func replacingProgress(
        _ progress: SpokenWordItemProgress,
        songHasDuration: Bool
    ) -> SpokenWordBookItem {
        var item = self
        if !songHasDuration { item.duration = progress.knownDuration ?? 0 }
        item.position = progress.position
        item.positionUpdatedAt = progress.positionUpdatedAt
        item.finishedAt = progress.finishedAt
        return item
    }
}

/// The book the playing item belongs to, kept between the store's writes.
///
/// A playing book's position is saved every few seconds, and each save used
/// to regroup the book from the library — for a book of a few thousand parts
/// that held the main thread for tens of milliseconds while the player was
/// on screen. Grouping reads tags and paths, never progress
/// (`SpokenWordBookGrouping.books(from:)`), so the grouped book is kept while
/// `groupingKey` stays the same and only the progress is read again when
/// `progressKey` moves.
public struct SpokenWordCurrentBookCache {
    public struct Grouped {
        public var book: SpokenWordBook?
        /// Items whose song has no duration of its own; theirs follows the
        /// stored progress.
        public var untimedItemIDs: Set<String>

        public init(book: SpokenWordBook?, untimedItemIDs: Set<String> = []) {
            self.book = book
            self.untimedItemIDs = untimedItemIDs
        }
    }

    private var groupingKey: String?
    private var itemID: String?
    private var grouped = Grouped(book: nil)
    /// Names the book last returned, progress and playing item included:
    /// what caches derived from it key on.
    public private(set) var key: String?

    public init() {}

    /// - Parameters:
    ///   - groupingKey: changes whenever the book's members, their tags or
    ///     how they are classified may have changed.
    ///   - progressKey: changes whenever any stored progress may have.
    ///   - itemID: the item playing.
    ///   - group: groups the playing item's book from the library.
    ///   - progress: what the store holds now for an item.
    public mutating func book(
        groupingKey: String,
        progressKey: String,
        itemID: String,
        group: () -> Grouped,
        progress: (String) -> SpokenWordItemProgress
    ) -> SpokenWordBook? {
        let key = "\(groupingKey)#\(progressKey)#\(itemID)"
        if key == self.key { return grouped.book }
        // Another item of the same book keeps the grouping; one outside it
        // (or the first item of a book not found yet) groups again.
        let keepsGrouping = groupingKey == self.groupingKey
            && (itemID == self.itemID || grouped.book?.items.contains { $0.id == itemID } == true)
        if keepsGrouping {
            if let book = grouped.book {
                let untimed = grouped.untimedItemIDs
                grouped.book = SpokenWordBookGrouping.updatingProgress(of: book) { item in
                    item.replacingProgress(progress(item.id), songHasDuration: !untimed.contains(item.id))
                }
            }
        } else {
            grouped = group()
            self.groupingKey = groupingKey
        }
        self.itemID = itemID
        self.key = key
        return grouped.book
    }
}

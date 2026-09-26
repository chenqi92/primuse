import Foundation

// MARK: - Now playing

/// What the now-playing widget needs to draw a book rather than a song: the
/// skip intervals that replace the track buttons, and where the listener is in
/// the book. Rides on `PlaybackState.spokenWord`; nil for music and radio, so
/// snapshots written before it existed decode as music.
public struct SpokenWordPlaybackInfo: Codable, Sendable, Hashable {
    public var skipBackwardSeconds: Int
    public var skipForwardSeconds: Int
    public var bookTitle: String?
    public var bookAuthor: String?
    /// 1-based position of the part playing — a file of a multi-file book, or
    /// a chapter mark of a single-file one — and how many parts there are.
    /// Nil when the book is a single part.
    public var partIndex: Int?
    public var partCount: Int?
    /// Whole-book progress (0...1) and the time left in it, when every
    /// part's duration is known.
    public var bookFraction: Double?
    public var bookRemaining: TimeInterval?

    public init(
        skipBackwardSeconds: Int,
        skipForwardSeconds: Int,
        bookTitle: String? = nil,
        bookAuthor: String? = nil,
        partIndex: Int? = nil,
        partCount: Int? = nil,
        bookFraction: Double? = nil,
        bookRemaining: TimeInterval? = nil
    ) {
        self.skipBackwardSeconds = skipBackwardSeconds
        self.skipForwardSeconds = skipForwardSeconds
        self.bookTitle = bookTitle
        self.bookAuthor = bookAuthor
        self.partIndex = partIndex
        self.partCount = partCount
        self.bookFraction = bookFraction
        self.bookRemaining = bookRemaining
    }

    /// `gobackward.N` / `goforward.N` for the configured intervals.
    public var skipBackwardSymbol: String {
        SpokenWordSkipPolicy.symbolName(forward: false, interval: skipBackwardSeconds)
    }

    public var skipForwardSymbol: String {
        SpokenWordSkipPolicy.symbolName(forward: true, interval: skipForwardSeconds)
    }
}

// MARK: - Continue listening shelf

/// The books the "continue listening" widget shows, written by the app into
/// the App Group whenever what it would draw changes.
public struct SpokenWordShelfSnapshot: Codable, Sendable, Hashable {
    public struct Book: Codable, Sendable, Hashable, Identifiable {
        /// `SpokenWordBook.id` — what the resume intent is handed back.
        public var id: String
        public var title: String
        public var author: String?
        /// A file in the shared container, in the cover's own proportions.
        public var coverImageName: String?
        public var fractionComplete: Double
        public var remaining: TimeInterval?
        /// 1-based part the book continues from, and how many parts it has.
        public var partIndex: Int?
        public var partCount: Int
        public var lastListenedAt: Date?

        public init(
            id: String,
            title: String,
            author: String? = nil,
            coverImageName: String? = nil,
            fractionComplete: Double,
            remaining: TimeInterval? = nil,
            partIndex: Int? = nil,
            partCount: Int = 1,
            lastListenedAt: Date? = nil
        ) {
            self.id = id
            self.title = title
            self.author = author
            self.coverImageName = coverImageName
            self.fractionComplete = fractionComplete
            self.remaining = remaining
            self.partIndex = partIndex
            self.partCount = partCount
            self.lastListenedAt = lastListenedAt
        }
    }

    public var books: [Book]
    public var updatedAt: Date

    public init(books: [Book], updatedAt: Date = Date()) {
        self.books = books
        self.updatedAt = updatedAt
    }

    public static func load() -> SpokenWordShelfSnapshot? {
        WidgetSharedStore.load(SpokenWordShelfSnapshot.self, key: PrimuseConstants.spokenWordShelfSnapshotKey)
    }

    public func save() {
        WidgetSharedStore.save(self, key: PrimuseConstants.spokenWordShelfSnapshotKey)
    }

    public static func clear() {
        WidgetSharedStore.defaults?.removeObject(forKey: PrimuseConstants.spokenWordShelfSnapshotKey)
    }
}

public enum SpokenWordWidgetPolicy {
    /// The medium widget's row count; the small one shows the first.
    public static let shelfLimit = 3
    /// Book covers in the shared container start with this, so clearing the
    /// shared covers can find them.
    public static let coverFilePrefix = "widget_book_"

    /// The books being listened to, most recently heard first.
    public static func shelfBooks(from books: [SpokenWordBook], limit: Int = shelfLimit) -> [SpokenWordBook] {
        Array(
            books.filter(\.isInProgress)
                .sorted { ($0.lastListenedAt ?? .distantPast) > ($1.lastListenedAt ?? .distantPast) }
                .prefix(max(0, limit))
        )
    }

    /// Where `itemID` sits in the book, 1-based, with the book's part count;
    /// nil for a single-part book or an item not in it.
    public static func partPosition(of itemID: String?, in book: SpokenWordBook) -> (index: Int, count: Int)? {
        guard book.items.count > 1, let itemID,
              let index = book.items.firstIndex(where: { $0.id == itemID }) else { return nil }
        return (index + 1, book.items.count)
    }

    public static func shelfEntry(for book: SpokenWordBook, coverImageName: String?) -> SpokenWordShelfSnapshot.Book {
        let part = partPosition(of: book.resumeItemID, in: book)
        return SpokenWordShelfSnapshot.Book(
            id: book.id,
            title: book.title,
            author: book.author,
            coverImageName: coverImageName,
            fractionComplete: book.fractionComplete,
            remaining: book.remainingDuration,
            partIndex: part?.index,
            partCount: book.items.count,
            lastListenedAt: book.lastListenedAt
        )
    }

    /// A stable, file-name-safe name for a book's cover. Book ids hold album
    /// titles and paths, which are neither.
    public static func coverFileName(forBookID bookID: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bookID.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return coverFilePrefix + String(hash, radix: 16) + ".jpg"
    }

    /// What the widget would visibly draw: the books in order, their part,
    /// progress to the whole percent and time left to the minute. Position
    /// saves every 15 s change none of these most of the time, so comparing
    /// signatures keeps the widget from being reloaded on each save.
    public static func signature(of books: [SpokenWordShelfSnapshot.Book]) -> String {
        books.map { book in
            [
                book.id,
                book.title,
                book.author ?? "",
                book.coverImageName ?? "",
                String(Int((book.fractionComplete * 100).rounded())),
                book.remaining.map { String(Int(($0 / 60).rounded())) } ?? "",
                book.partIndex.map(String.init) ?? "",
                String(book.partCount),
            ].joined(separator: "\u{1F}")
        }.joined(separator: "\u{1E}")
    }
}

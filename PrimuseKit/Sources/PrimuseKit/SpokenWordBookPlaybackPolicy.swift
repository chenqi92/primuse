import Foundation

extension SpokenWordBookGrouping {
    /// The id of the book `item` belongs to — the same id
    /// `books(from:)` gives that book, so a per-book setting can be looked up
    /// from the item that is playing without regrouping the library.
    public static func bookID(for item: SpokenWordBookItem) -> String {
        groupingKey(for: item)
    }

    /// The book that now holds most of `chapterIDs` — for a page keeping a
    /// book open while the library regroups. A book's id changes when the
    /// first tags are read: a folder of untagged files is named after the
    /// folder, and the album its first tagged chapter carries takes over.
    public static func bookID(
        holdingMostOf chapterIDs: Set<String>,
        among books: some Sequence<SpokenWordBook>
    ) -> String? {
        guard !chapterIDs.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for book in books {
            let count = book.items.reduce(0) { $0 + (chapterIDs.contains($1.id) ? 1 : 0) }
            if count > 0 { counts[book.id] = count }
        }
        return mostHeld(counts)?.id
    }

    /// Old book id → the book that took over its chapters, for each book of
    /// `previous` that `current` no longer has (both item id → book id, as
    /// `bookIDs(for:)` gives them). The successor is found the way an open
    /// book page follows its book (`bookID(holdingMostOf:among:)`), and must
    /// hold more than half of the old book's chapters still in the library:
    /// a book whose chapters scattered or went away has none.
    public static func renamedBookIDs(
        from previous: [String: String],
        to current: [String: String]
    ) -> [String: String] {
        guard !previous.isEmpty, !current.isEmpty else { return [:] }
        let currentBookIDs = Set(current.values)
        var tallies: [String: [String: Int]] = [:]
        for (itemID, oldID) in previous where !currentBookIDs.contains(oldID) {
            guard let newID = current[itemID] else { continue }
            tallies[oldID, default: [:]][newID, default: 0] += 1
        }
        var renames: [String: String] = [:]
        for (oldID, counts) in tallies {
            guard let best = mostHeld(counts) else { continue }
            if best.count * 2 > counts.values.reduce(0, +) { renames[oldID] = best.id }
        }
        return renames
    }

    /// The book holding the most, the smaller id on a tie.
    static func mostHeld(_ counts: [String: Int]) -> (id: String, count: Int)? {
        counts.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
        }.map { ($0.key, $0.value) }
    }
}

extension SpokenWordPlaybackRatePolicy {
    /// The spoken-word speed for one book: its own when the listener set one,
    /// the global spoken-word speed otherwise.
    public static func bookRate(stored: Float?, globalSpokenWordRate: Float) -> Float {
        if let stored, stored.isFinite { return clamped(stored) }
        return clamped(globalSpokenWordRate)
    }

    /// What to store when the listener picks `rate` for a book: nothing when
    /// it equals the global speed, so a later change of the global speed
    /// still reaches the book.
    public static func storedBookRate(for rate: Float, globalSpokenWordRate: Float) -> Float? {
        let value = clamped(rate)
        return abs(value - clamped(globalSpokenWordRate)) < 0.001 ? nil : value
    }
}

/// Moving through a book whose items carry no chapter marks: the items
/// themselves are the chapters.
public enum SpokenWordBookNavigationPolicy {
    /// The item `offset` steps from `currentItemID` in reading order, or nil
    /// at either end of the book (or when the current item is not in it).
    public static func adjacentItemID(
        from currentItemID: String,
        offset: Int,
        in bookItemIDs: [String]
    ) -> String? {
        guard let index = bookItemIDs.firstIndex(of: currentItemID) else { return nil }
        let target = index + offset
        guard bookItemIDs.indices.contains(target), target != index else { return nil }
        return bookItemIDs[target]
    }

    /// "Previous" inside an item restarts it first, like every audiobook
    /// player: only a press within the opening seconds moves to the previous
    /// item.
    public static let restartThreshold: TimeInterval = 3

    public static func previousRestartsCurrentItem(currentTime: TimeInterval) -> Bool {
        currentTime.isFinite && currentTime > restartThreshold
    }
}

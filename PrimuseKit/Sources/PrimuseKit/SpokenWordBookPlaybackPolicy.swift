import Foundation

extension SpokenWordBookGrouping {
    /// The id of the book `item` belongs to — the same id
    /// `books(from:)` gives that book, so a per-book setting can be looked up
    /// from the item that is playing without regrouping the library.
    public static func bookID(for item: SpokenWordBookItem) -> String {
        groupingKey(for: item)
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

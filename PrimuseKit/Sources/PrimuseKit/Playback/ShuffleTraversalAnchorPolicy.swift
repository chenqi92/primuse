import Foundation

/// Selects a prepared repeat-all shuffle round without regenerating it once a
/// caller has cached the first result. Callers persist the returned round and
/// feed it back on subsequent reads so previews, prefetch and playback agree.
public enum ShuffleRoundPreparationPolicy {
    public static func preparedRound(
        pending: [Int]?,
        generate: () -> [Int]
    ) -> [Int] {
        if let pending { return pending }
        return generate()
    }
}

/// Resolves where the playing queue slot actually sits inside a managed
/// shuffle round.
///
/// `shufflePosition` is a cached hint, not the truth. Several paths move
/// `currentIndex` without being able to update it: a restored session whose
/// snapshot no longer points at the current track, an Apple Music mirror
/// adopting a native transition, a traversal target rebuilt from a stale
/// presentation snapshot. Presentation and traversal then disagreed about
/// where the round is cut — Up Next was sliced at `shufflePosition` while
/// advance started from the position that really holds `currentIndex`. The
/// visible Up Next stopped describing what plays next, and an Up Next drag
/// rewrote a slice of the round that playback never visits. Every reader
/// resolves the anchor here so the round has a single meaning.
public enum ShuffleTraversalAnchorPolicy {
    /// First occurrence of the playing slot in the round. The clamped hint is
    /// used only when the round no longer contains that slot at all, which is
    /// the case for a round extended from the library: it intentionally drops
    /// the previous segment's indices.
    public static func anchorPosition(
        traversalIndices: [Int],
        currentIndex: Int,
        shufflePosition: Int
    ) -> Int? {
        guard !traversalIndices.isEmpty else { return nil }
        if let position = traversalIndices.firstIndex(of: currentIndex) {
            return position
        }
        return min(max(shufflePosition, 0), traversalIndices.count - 1)
    }
}

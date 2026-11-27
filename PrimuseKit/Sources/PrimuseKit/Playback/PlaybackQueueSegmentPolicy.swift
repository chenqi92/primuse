import Foundation

/// A system renderer receives only the contiguous compatible part of the
/// canonical traversal, so it cannot skip an intervening provider or gap.
public enum PlaybackQueueSegmentPolicy {
    public static func indices(
        traversal: [Int],
        currentIndex: Int,
        isCompatible: (Int) -> Bool
    ) -> [Int] {
        guard let position = traversal.firstIndex(of: currentIndex),
              isCompatible(currentIndex) else { return [] }
        var lower = position
        var upper = position
        while lower > 0, isCompatible(traversal[lower - 1]) { lower -= 1 }
        while upper + 1 < traversal.count, isCompatible(traversal[upper + 1]) { upper += 1 }
        return Array(traversal[lower...upper])
    }
}

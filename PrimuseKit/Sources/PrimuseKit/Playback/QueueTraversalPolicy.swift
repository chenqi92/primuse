import Foundation

/// Resolves queue navigation against the current library without mutating the
/// canonical queue. This lets playback survive source removal or disablement.
public enum QueueTraversalPolicy {
    public static func nextAvailableIndex(
        queueCount: Int,
        after currentIndex: Int,
        wraps: Bool,
        isAvailable: (Int) -> Bool
    ) -> Int? {
        guard queueCount > 0 else { return nil }

        let forwardStart = max(0, currentIndex + 1)
        if forwardStart < queueCount {
            for index in forwardStart..<queueCount where isAvailable(index) {
                return index
            }
        }

        guard wraps, currentIndex >= 0 else { return nil }
        let wrapEnd = min(currentIndex, queueCount - 1)
        for index in 0...wrapEnd where isAvailable(index) {
            return index
        }
        return nil
    }

    public static func previousAvailableIndex(
        before currentIndex: Int,
        isAvailable: (Int) -> Bool
    ) -> Int? {
        guard currentIndex > 0 else { return nil }
        for index in stride(from: currentIndex - 1, through: 0, by: -1)
        where isAvailable(index) {
            return index
        }
        return nil
    }

    /// Finds a playable position in an arbitrary traversal order (for
    /// example a managed shuffle round). Invalid queue indices are ignored so
    /// a stale presentation snapshot cannot escape into playback.
    public static func nextAvailableTraversalPosition(
        in traversalIndices: [Int],
        queueCount: Int,
        after currentPosition: Int,
        isAvailable: (Int) -> Bool
    ) -> Int? {
        guard queueCount > 0 else { return nil }
        let start = max(0, currentPosition + 1)
        guard start < traversalIndices.count else { return nil }
        for position in start..<traversalIndices.count {
            let queueIndex = traversalIndices[position]
            guard (0..<queueCount).contains(queueIndex) else { continue }
            if isAvailable(queueIndex) { return position }
        }
        return nil
    }

    public static func previousAvailableTraversalPosition(
        in traversalIndices: [Int],
        queueCount: Int,
        before currentPosition: Int,
        isAvailable: (Int) -> Bool
    ) -> Int? {
        guard queueCount > 0, currentPosition > 0 else { return nil }
        let start = min(currentPosition - 1, traversalIndices.count - 1)
        guard start >= 0 else { return nil }
        for position in stride(from: start, through: 0, by: -1) {
            let queueIndex = traversalIndices[position]
            guard (0..<queueCount).contains(queueIndex) else { continue }
            if isAvailable(queueIndex) { return position }
        }
        return nil
    }
}

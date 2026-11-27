import Foundation

/// Splits a queue's current shuffle round into played and upcoming occurrences.
/// `roundOffset` distinguishes the same queue slot when repeat-all previews the
/// next round, while `queueIndex` keeps duplicate songs in separate slots.
public struct QueuePresentationOccurrence: Hashable, Sendable {
    public let queueIndex: Int
    public let roundOffset: Int

    public init(queueIndex: Int, roundOffset: Int) {
        self.queueIndex = queueIndex
        self.roundOffset = roundOffset
    }
}

public enum QueuePresentationPolicy {
    public static func playedOccurrences(
        queueCount: Int,
        currentIndex: Int,
        shuffledIndices: [Int]?,
        shufflePosition: Int
    ) -> [QueuePresentationOccurrence] {
        guard queueCount > 0 else { return [] }
        guard let shuffledIndices, !shuffledIndices.isEmpty else {
            let end = min(max(currentIndex, 0), queueCount)
            return occurrences(in: Array(0..<end), queueCount: queueCount, roundOffset: 0)
        }

        let currentPosition = min(max(shufflePosition, 0), shuffledIndices.count - 1)
        let played = Array(shuffledIndices.prefix(currentPosition))
            .filter { $0 != currentIndex }
        return occurrences(in: played, queueCount: queueCount, roundOffset: 0)
    }

    /// 本轮待播里前 `limit` 个满足 `include` 的队列下标，顺序与
    /// `upcomingOccurrences` 的 roundOffset == 0 部分一致，但边走边判断、够数就停。
    /// 播放页菜单和每几秒一次的智能提示只想知道「还有没有」，整库队列时展开
    /// 整轮会在主线程上花掉几百毫秒。
    public static func firstCurrentRoundUpcomingIndices(
        queueCount: Int,
        currentIndex: Int,
        shuffledIndices: [Int]?,
        shufflePosition: Int,
        limit: Int,
        where include: (Int) -> Bool = { _ in true }
    ) -> [Int] {
        guard queueCount > 0, limit > 0 else { return [] }
        var result: [Int] = []
        guard let shuffledIndices, !shuffledIndices.isEmpty else {
            let start = min(max(currentIndex + 1, 0), queueCount)
            for index in start..<queueCount where include(index) {
                result.append(index)
                if result.count == limit { break }
            }
            return result
        }

        let currentPosition = min(max(shufflePosition, 0), shuffledIndices.count - 1)
        var excluded: Set<Int>?
        var seen = Set<Int>()
        for index in shuffledIndices.dropFirst(currentPosition + 1) {
            guard index != currentIndex, (0..<queueCount).contains(index) else { continue }
            let consumed = excluded ?? Set(shuffledIndices.prefix(currentPosition + 1))
            excluded = consumed
            guard !consumed.contains(index), seen.insert(index).inserted, include(index) else { continue }
            result.append(index)
            if result.count == limit { break }
        }
        return result
    }

    public static func upcomingOccurrences(
        queueCount: Int,
        currentIndex: Int,
        shuffledIndices: [Int]?,
        shufflePosition: Int,
        nextRoundIndices: [Int]?
    ) -> [QueuePresentationOccurrence] {
        guard queueCount > 0 else { return [] }
        guard let shuffledIndices, !shuffledIndices.isEmpty else {
            let start = min(max(currentIndex + 1, 0), queueCount)
            return occurrences(in: Array(start..<queueCount), queueCount: queueCount, roundOffset: 0)
        }

        let currentPosition = min(max(shufflePosition, 0), shuffledIndices.count - 1)
        let consumedCurrentRound = Set(
            shuffledIndices.prefix(currentPosition + 1).filter { (0..<queueCount).contains($0) }
        )
        let remaining = shuffledIndices.dropFirst(currentPosition + 1).filter {
            $0 != currentIndex && !consumedCurrentRound.contains($0)
        }
        var result = occurrences(
            in: Array(remaining),
            queueCount: queueCount,
            roundOffset: 0
        )
        if let nextRoundIndices {
            result.append(contentsOf: occurrences(
                in: nextRoundIndices,
                queueCount: queueCount,
                roundOffset: 1
            ))
        }
        return result
    }

    private static func occurrences(
        in indices: [Int],
        queueCount: Int,
        roundOffset: Int
    ) -> [QueuePresentationOccurrence] {
        var seen = Set<Int>()
        return indices.compactMap { index in
            guard (0..<queueCount).contains(index), seen.insert(index).inserted else { return nil }
            return QueuePresentationOccurrence(queueIndex: index, roundOffset: roundOffset)
        }
    }
}

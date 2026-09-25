import Foundation

/// iPhone Duo 桌面半折时，播放页下半屏控件上方那一排封面：当前曲居中放大，左边露出刚放过的几首、
/// 右边露出接下来的几首，左右滑到哪一张停下就放那一首。
///
/// 顺序与「播放队列」页一致（随机时按本轮实际的播放顺序），只取当前曲前后几首 —— 整库队列有几万条，
/// 这一排不能每次都把整条队列展开。
public enum TabletopQueueStripPolicy {
    /// 左边最多露出几首刚放过的。
    public static let playedLimit = 3
    /// 右边最多排几首接下来的。
    public static let upcomingLimit = 8

    /// 刚放过的 `limit` 个队列下标，按播放顺序排（最近放的在最后），与队列页「已播放」那一段同序：
    /// 随机时取本轮顺序里当前位置之前的，否则取队列里当前曲之前的。越界与当前曲本身都去掉。
    public static func recentPlayedIndices(
        queueCount: Int,
        currentIndex: Int,
        shuffledIndices: [Int]?,
        shufflePosition: Int,
        limit: Int
    ) -> [Int] {
        guard queueCount > 0, limit > 0 else { return [] }
        guard let shuffledIndices, !shuffledIndices.isEmpty else {
            let end = min(max(currentIndex, 0), queueCount)
            return Array(max(0, end - limit)..<end)
        }
        let currentPosition = min(max(shufflePosition, 0), shuffledIndices.count - 1)
        var result: [Int] = []
        var seen = Set<Int>()
        var position = currentPosition - 1
        while position >= 0, result.count < limit {
            let index = shuffledIndices[position]
            if index != currentIndex, (0..<queueCount).contains(index), seen.insert(index).inserted {
                result.append(index)
            }
            position -= 1
        }
        return result.reversed()
    }

    /// 这一排从左到右的队列下标：刚放过的、当前曲、接下来的。当前曲只出现一次，重复与越界的去掉。
    /// 当前曲不在队列里时为空。
    public static func stripIndices(
        played: [Int],
        currentIndex: Int,
        upcoming: [Int],
        queueCount: Int
    ) -> [Int] {
        guard (0..<queueCount).contains(currentIndex) else { return [] }
        var seen: Set<Int> = [currentIndex]
        let before = played.filter { (0..<queueCount).contains($0) && seen.insert($0).inserted }
        let after = upcoming.filter { (0..<queueCount).contains($0) && seen.insert($0).inserted }
        return before + [currentIndex] + after
    }

    /// 这一排的尺寸。`availableHeight` 是下半屏留给它的高度；放不下一张像样的封面时为 nil（不显示）。
    public struct Metrics: Equatable, Sendable {
        /// 居中那张（当前曲）的边长；两侧的按离中心的远近缩小。
        public let coverSide: Double
        /// 相邻两张的间距（按原尺寸算）。
        public let spacing: Double
        /// 离中心一整格时缩到的比例。
        public let sideScale: Double
    }

    public static let minimumCoverSide: Double = 64
    public static let maximumCoverSide: Double = 132

    public static func metrics(width: Double, availableHeight: Double) -> Metrics? {
        guard width.isFinite, availableHeight.isFinite, width > 0 else { return nil }
        // 上下各留一点给阴影；居中那张不超过宽度的三成，两侧才露得出别的几张。
        let side = min(availableHeight - 12, maximumCoverSide, width * 0.3)
        guard side >= minimumCoverSide else { return nil }
        return Metrics(coverSide: side.rounded(.down), spacing: 8, sideScale: 0.74)
    }

    /// 离中心 `distance`（点）的那一张缩放到多少：中心 1，一整格（边长 + 间距）以外都是 `sideScale`。
    public static func scale(forDistance distance: Double, metrics: Metrics) -> Double {
        let pitch = metrics.coverSide + metrics.spacing
        guard pitch > 0, distance.isFinite else { return metrics.sideScale }
        let progress = min(abs(distance) / pitch, 1)
        return 1 - (1 - metrics.sideScale) * progress
    }
}

import Foundation

/// 播放队列从上往下的排布:已播放 → 正在播放 → 接下来,和 Apple Music 一样。打开时停在正在播放那一段,
/// 往上翻是已播放(最早的在最上面,刚放完的紧挨着正在播放),往下翻是接下来。
///
/// 已播放可能有上万首:从资料库中间点一首整库开播,排在它前面的都算已播放。惰性列表要定位到某一行时,
/// 会把它前面的格子一格一格过一遍,所以已播放只画最近的一段,更早的收在这一段顶上的「显示更早的」里,
/// 点一下往上再展开一页。序号照从上往下连着数,没画出来的那些也算在内。
///
/// iPhone / iPad 的队列页与播放页「接下来」一面、Mac 队列面板和迷你播放器的队列都按这一份排。
public struct QueueHistoryLayout: Equatable, Sendable {
    /// 打开时画出来的已播放首数,也是点一次「显示更早的」多展开的首数。
    public static let pageSize = 100

    /// 已播放一共多少首。
    public let playedCount: Int
    /// 接下来一共多少首(含自动续播的相似歌曲和循环下一轮)。
    public let upcomingCount: Int
    /// 画出来的那一段在已播放(按播放先后)里的位置。
    public let visibleHistoryRange: Range<Int>

    /// - Parameter historyLimit: 已播放最多画几首,从最近的往前数。
    public init(playedCount: Int, upcomingCount: Int, historyLimit: Int) {
        let played = max(0, playedCount)
        self.playedCount = played
        self.upcomingCount = max(0, upcomingCount)
        let visible = min(played, max(0, historyLimit))
        self.visibleHistoryRange = (played - visible)..<played
    }

    /// 收在「显示更早的」里、还没画出来的已播放首数。
    public var hiddenHistoryCount: Int { visibleHistoryRange.lowerBound }

    /// 点一下「显示更早的」多出来几首;为 0 时不给这颗键。
    public var nextRevealCount: Int { min(hiddenHistoryCount, Self.pageSize) }

    /// 点「显示更早的」之后的已播放上限。
    public var expandedHistoryLimit: Int { visibleHistoryRange.count + Self.pageSize }

    /// 正在播放上面画着已播放,打开时要把列表定位到正在播放;上面什么都没有时本来就停在顶上。
    public var revealsCurrentOnAppear: Bool { !visibleHistoryRange.isEmpty }

    /// 整个队列的首数,序号的位数照它算。
    public var totalCount: Int { playedCount + 1 + upcomingCount }

    /// 画出来的第 `offset` 首已播放(0 是最上面那首)的序号。
    public func historyOrdinal(visibleOffset offset: Int) -> Int {
        hiddenHistoryCount + offset + 1
    }

    /// 正在播放那首的序号。
    public var currentOrdinal: Int { playedCount + 1 }

    /// 接下来第 `offset` 首(0 是紧接着要放的那首)的序号。
    public func upcomingOrdinal(offset: Int) -> Int {
        playedCount + 2 + offset
    }
}

public extension QueuePresentationPolicy {
    /// 已播放里最近的 `limit` 个(仍按播放先后)和一共多少个,与 `playedOccurrences` 的末尾一段一致。
    /// 不随机时已播放就是队列开头那一段,直接截,用不着把整段先展开。
    static func recentPlayedOccurrences(
        queueCount: Int,
        currentIndex: Int,
        shuffledIndices: [Int]?,
        shufflePosition: Int,
        limit: Int
    ) -> (occurrences: [QueuePresentationOccurrence], totalCount: Int) {
        guard queueCount > 0 else { return ([], 0) }
        let limit = max(0, limit)
        guard let shuffledIndices, !shuffledIndices.isEmpty else {
            let end = min(max(currentIndex, 0), queueCount)
            let start = max(0, end - limit)
            let recent = (start..<end).map { QueuePresentationOccurrence(queueIndex: $0, roundOffset: 0) }
            return (recent, end)
        }
        let played = playedOccurrences(
            queueCount: queueCount,
            currentIndex: currentIndex,
            shuffledIndices: shuffledIndices,
            shufflePosition: shufflePosition
        )
        return (Array(played.suffix(limit)), played.count)
    }
}

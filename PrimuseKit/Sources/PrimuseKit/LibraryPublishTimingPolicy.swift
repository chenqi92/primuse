import Foundation

/// 后台工作把结果交给资料库(补读标签写回、扫描中间提交)的时机。
///
/// 一次交付的代价与整库规模成正比, 与这一批有几首无关: 重发两个上万元素的
/// 可观察数组, 首页、搜索、CarPlay 各按整库重算一遍。4 万首的库上这一下就是
/// 滑动里能感觉到的"顿一下"。这里管两件事:
/// - 用户正在滑动时先攒着, 停下来稍等一会儿再一次交付;
/// - 大曲库上两次补读交付之间拉开间隔, 让交付占的总开销不随曲库变大而变大。
/// 收尾那一批(读完、停止、进后台)不归这里管, 调用方必须立刻交付。
public enum LibraryPublishTimingPolicy {
    /// 某一刻的滑动状态。`lastActivityAt` 是最近一次看到在滑(或刚停下)的时刻。
    public struct ScrollActivity: Sendable, Equatable {
        public var isScrolling: Bool
        public var lastActivityAt: Date?

        public init(isScrolling: Bool, lastActivityAt: Date?) {
            self.isScrolling = isScrolling
            self.lastActivityAt = lastActivityAt
        }

        public static let idle = ScrollActivity(isScrolling: false, lastActivityAt: nil)
    }

    /// 停下后再等多久才算滑完: 惯性滚动刚停、紧接着又一次轻扫, 都算同一段滑动。
    public static let scrollSettleDelay: TimeInterval = 1
    /// 一直在滑时最多压多久。再往后界面上的标签就旧得能看出来了, 宁可顿一下。
    public static let maximumScrollHold: TimeInterval = 15
    /// 一直在滑时最多攒几批。补读快的时候 15 秒能读上千首, 攒太多一次交付本身也更贵。
    public static let maximumScrollHoldBatches = 8

    public static func isSettled(_ activity: ScrollActivity, now: Date) -> Bool {
        guard !activity.isScrolling else { return false }
        guard let last = activity.lastActivityAt else { return true }
        return now.timeIntervalSince(last) >= scrollSettleDelay
    }

    public enum ScrollGate: Sendable, Equatable {
        /// 没在滑, 照常交付。
        case proceed
        /// 在滑(或刚停), 先攒着。
        case hold
        /// 在滑, 但已经压够久或攒够多, 这次照样交付。
        case proceedDespiteScrolling
    }

    /// 已经到点、本该交付的这一次, 要不要因为滑动往后压。
    /// - Parameters:
    ///   - holdingSince: 这一批从什么时候开始因为滑动被压着; 还没压过传 nil。
    ///   - pendingCount: 攒着没交付的条数。
    ///   - batchSize: 平时多少条交付一次, 用来折算攒的上限。
    public static func scrollGate(
        activity: ScrollActivity,
        holdingSince: Date?,
        pendingCount: Int,
        batchSize: Int,
        now: Date
    ) -> ScrollGate {
        guard !isSettled(activity, now: now) else { return .proceed }
        if let holdingSince, now.timeIntervalSince(holdingSince) >= maximumScrollHold {
            return .proceedDespiteScrolling
        }
        if pendingCount >= max(1, batchSize) * maximumScrollHoldBatches {
            return .proceedDespiteScrolling
        }
        return .hold
    }

    /// 小曲库也会触发首页、索引和系统建议更新，快读时仍需合并发布。
    public static let minimumPublishSpacing: TimeInterval = 10
    /// 从这个规模起按曲库大小继续拉开间隔。
    public static let largeLibrarySongCount = 10_000
    /// 每千首歌至少隔一秒交付一次: 一次交付的代价跟着曲库线性涨, 间隔也跟着涨,
    /// 交付占的总开销就不随曲库变大而变大。
    public static let spacingPerThousandSongs: TimeInterval = 1
    /// 间隔上限。再长读好的标签迟迟不出现, 而且被杀进程时要重读的也更多。
    public static let maximumLargeLibrarySpacing: TimeInterval = 60

    /// 两次补读交付之间至少隔多久(收尾那一批除外)。
    public static func minimumBackfillPublishSpacing(librarySongCount: Int) -> TimeInterval {
        guard librarySongCount >= largeLibrarySongCount else { return minimumPublishSpacing }
        let scaled = TimeInterval(librarySongCount) / 1000 * spacingPerThousandSongs
        return min(maximumLargeLibrarySpacing, scaled)
    }

    /// 补读攒下的结果是否到了该交付的时候(不算滑动; 收尾那一批调用方自己放行)。
    /// 攒满一批或到达档位间隔后，还要满足最小间隔，避免快读时反复更新派生内容。
    public static func isBackfillPublishDue(
        pendingCount: Int,
        batchSize: Int,
        flushInterval: TimeInterval,
        sinceLastPublish: TimeInterval,
        librarySongCount: Int
    ) -> Bool {
        guard pendingCount >= max(1, batchSize) || sinceLastPublish >= flushInterval else {
            return false
        }
        return sinceLastPublish >= minimumBackfillPublishSpacing(librarySongCount: librarySongCount)
    }
}

public enum SearchIndexWorkPacing {
    /// 按实际处理时间让出 CPU；仅 yield 或固定几毫秒无法约束慢批次的占用。
    public static func delay(workSeconds: TimeInterval, thermalLevel: Int) -> TimeInterval {
        guard workSeconds.isFinite, workSeconds > 0 else { return 0 }
        let idleRatio: Double
        switch thermalLevel {
        case 0: idleRatio = 4
        case 1: idleRatio = 9
        case 2: idleRatio = 39
        default: idleRatio = 99
        }
        return min(30, workSeconds * idleRatio)
    }
}

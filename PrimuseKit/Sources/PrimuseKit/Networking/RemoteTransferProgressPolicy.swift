import Foundation

/// 设备当前有没有可用的网络路径，供不在主线程上的取数代码直接查。
///
/// App 的路径监视器在回调线程上同步写入；取数线程、请求执行器读它来决定
/// 「没网时别再重试」。只记「从什么时候起不通」，通了就清掉。
public enum NetworkPathState {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var unsatisfiedSinceUptime: TimeInterval?

    /// 路径监视器每次回调都调用。连续的「不通」保留最早的时刻。
    public static func record(
        unsatisfied: Bool,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        lock.lock()
        defer { lock.unlock() }
        if unsatisfied {
            if unsatisfiedSinceUptime == nil { unsatisfiedSinceUptime = now }
        } else {
            unsatisfiedSinceUptime = nil
        }
    }

    /// 从什么时候起（系统运行时间）确定没有网络；有网或还不知道时为 nil。
    public static var unavailableSince: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return unsatisfiedSinceUptime
    }

    public static var isUnavailable: Bool { unavailableSince != nil }
}

/// 一次范围读取该等多久。
///
/// 以前一块读取有 30 秒的总时限：拿下载地址花掉一半，剩下的时间里数据还在
/// 一点点到，读取照样被取消，慢网上的章节永远开不了播。现在按「多久没有任何
/// 动静」判断：服务器回了响应、来了字节都算动静；另设一个宽松的总上限，
/// 防止每隔几秒来几个字节的连接把播放器无限拖住。
public struct RangeFetchDeadline: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        case waiting
        /// 这么久一点动静都没有。
        case stalled
        /// 一直有动静，但总时长超过上限。
        case exceededLimit
    }

    public static let defaultStallLimit: TimeInterval = 30
    public static let defaultTotalLimit: TimeInterval = 180

    public let stallLimit: TimeInterval
    public let totalLimit: TimeInterval

    public init(
        stallLimit: TimeInterval = Self.defaultStallLimit,
        totalLimit: TimeInterval = Self.defaultTotalLimit
    ) {
        self.stallLimit = max(1, stallLimit)
        self.totalLimit = max(self.stallLimit, totalLimit)
    }

    public func verdict(
        startedAt: TimeInterval,
        lastActivityAt: TimeInterval?,
        now: TimeInterval
    ) -> Verdict {
        guard now.isFinite, startedAt.isFinite else { return .stalled }
        if now - startedAt >= totalLimit { return .exceededLimit }
        let lastActivity = max(startedAt, lastActivityAt.flatMap { $0.isFinite ? $0 : nil } ?? startedAt)
        return now - lastActivity >= stallLimit ? .stalled : .waiting
    }
}

/// 远程读取没拿到音频时，原因归哪一类。三类给用户的说法不同：
/// 没网要说连不上；连上了但太慢要说网络太慢；服务端拒绝的走各自的错误。
public enum RemoteReadFailure: Sendable, Equatable {
    case noConnection
    case tooSlow
}

public enum RemoteReadFailurePolicy {
    /// 网络断开要持续这么久，等待中的读取才提前结束。刚切换 Wi-Fi、
    /// 蜂窝换基站时路径会短暂不通，马上就报错反而打断了能续上的播放。
    public static let sustainedOfflineInterval: TimeInterval = 3

    /// - Parameters:
    ///   - startedAt: 这次开播 / 续播 / 拖动开始等待的时刻。
    ///   - offlineSince: 设备从什么时候起没有网络（`NetworkPathState`）。
    ///   - lastConnectivityFailureAt: 这个来源最近一次因为连不上而读取失败。
    ///   - lastSlowStallAt: 这个来源最近一次「有数据但太慢」被放弃。
    ///   - lastTransferAt: 这个来源最近一次送来数据或响应。
    ///   - minimumOfflineDuration: 只看网络状态时，要不通多久才算。已经拿到
    ///     读取错误的地方传 0；还在等的看门狗传 `sustainedOfflineInterval`。
    public static func classify(
        now: TimeInterval,
        startedAt: TimeInterval,
        offlineSince: TimeInterval?,
        lastConnectivityFailureAt: TimeInterval?,
        lastSlowStallAt: TimeInterval?,
        lastTransferAt: TimeInterval?,
        minimumOfflineDuration: TimeInterval
    ) -> RemoteReadFailure? {
        if let offlineSince, now - offlineSince >= max(0, minimumOfflineDuration) {
            // 断网之后还收到过数据，说明路径状态落后了，不按它下结论。
            let deliveredAfterOutage = lastTransferAt.map { $0 > max(startedAt, offlineSince) } ?? false
            if !deliveredAfterOutage { return .noConnection }
        }
        let delivered = lastTransferAt.map { $0 > startedAt } ?? false
        if let failure = lastConnectivityFailureAt, failure >= startedAt, !delivered {
            return .noConnection
        }
        if let stall = lastSlowStallAt, stall >= startedAt {
            return .tooSlow
        }
        return nil
    }
}

import Foundation

/// 用户点「缓存」整源下载时，单首歌失败后的重试节奏。
///
/// 自动离线那条管线（常驻队列 + 日志）本来就有分类退避和来源冷却，手动批量
/// 一直是一次定生死：网络抖一下、WebDAV 反代偶发一个 5xx、连接被中途掐断，
/// 这首歌当场记成失败，用户只能整批重来。十几首里失败七八首就是这么来的。
///
/// 退避同时也是给服务端的喘息：家用 NAS 和反代在并发下最容易在同一时刻连续
/// 报错，立刻重试只会把同一批错误再撞一遍。
public enum OfflineBatchRetryPolicy {

    /// 一首歌最多尝试几次（含第一次）。
    ///
    /// 3 次：真正的瞬时故障基本在第二次就过去了，第三次留给退避窗口正好覆盖
    /// 一次短暂的服务端重启。再多就变成对着一台已经不行的服务器空转。
    public static let maximumAttempts = 3

    /// 第 `attempt` 次尝试失败之后，要不要再来一次。
    ///
    /// `isRetryable` 由调用方按失败分类给出：凭据错误和权限拒绝重试没有意义，
    /// 只会拿同一份错凭据反复敲服务端。
    public static func shouldRetry(afterAttempt attempt: Int, isRetryable: Bool) -> Bool {
        guard isRetryable else { return false }
        guard attempt >= 1 else { return false }
        return attempt < maximumAttempts
    }

    /// 第 `attempt` 次尝试失败之后等多久再重试。
    ///
    /// 指数退避 2s → 4s，上限 16s。服务端明说限流时至少等 30 秒 —— 这种情况下
    /// 几秒钟后重试必然再吃一个 429。
    public static func retryDelay(afterAttempt attempt: Int, isRateLimited: Bool) -> TimeInterval {
        let exponent = Double(max(attempt, 1) - 1)
        let backoff = min(pow(2, exponent) * 2, 16)
        return isRateLimited ? max(backoff, 30) : backoff
    }
}

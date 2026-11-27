import Foundation

/// 锁屏歌词是按"行"重新发布 `nowPlayingInfo` 的: MediaRemote 会在调用线程
/// (主线程) 上同步做 XPC, 因此把歌词行引起的重发限制成每秒最多一次。被限流
/// 的那一行不会丢失 —— 调用方在窗口结束后(或下一个时钟 tick)把当时的行发
/// 出去, 锁屏始终显示当前行。播放/暂停/切歌/拖动等状态变化不走这里。
public enum NowPlayingLyricsPublishPolicy {
    public static let minimumPublishInterval: TimeInterval = 1

    public static func shouldPublish(
        lastPublishedAt: Date?,
        now: Date,
        lineChanged: Bool
    ) -> Bool {
        guard lineChanged else { return false }
        guard let lastPublishedAt else { return true }
        let elapsed = now.timeIntervalSince(lastPublishedAt)
        // 系统时钟被回拨时不能把发布无限期卡住。
        guard elapsed >= 0 else { return true }
        return elapsed >= minimumPublishInterval
    }

    /// 距离下一次允许发布还要等多久。0 表示现在就可以发布。
    public static func delayUntilNextPublish(
        lastPublishedAt: Date?,
        now: Date
    ) -> TimeInterval {
        guard let lastPublishedAt else { return 0 }
        let elapsed = now.timeIntervalSince(lastPublishedAt)
        guard elapsed >= 0 else { return 0 }
        return max(0, minimumPublishInterval - elapsed)
    }
}

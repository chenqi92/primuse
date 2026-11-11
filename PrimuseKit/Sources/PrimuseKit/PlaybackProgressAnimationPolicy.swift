import Foundation

/// 跟着播放时钟走的细进度线(迷你条、停靠条)什么时候接一段线性动画、什么时候直接跳。
///
/// 播放时钟每 `clockTickInterval` 秒推进一次,进度线不接动画就一格一格地跳;接一段
/// 与时钟间隔同长的线性动画,两次推进首尾相接,看起来就是连续往前走。
///
/// 只有「同一首歌、正在播、往前走了正常的一小步」才接动画。换歌、seek、往回拖、
/// 暂停时都直接跳到位 —— 否则换歌时进度线会从上一首的位置一路倒扫回起点,
/// seek 时会慢吞吞地滑过去。
public enum PlaybackProgressAnimationPolicy {
    /// 与播放器的时钟间隔对齐(AudioPlayerService.timeUpdateInterval)。
    public static let clockTickInterval: TimeInterval = 0.5

    /// 一跳里往前走多少秒以内算正常推进。倍速播放时一跳会多走一些,两倍速正好一秒;
    /// 再往上就当成跳转。
    public static let maximumAnimatedAdvance: TimeInterval = 1

    /// 从 `previous` 推进到 `current` 这一下要不要接线性动画。
    ///
    /// - Parameters:
    ///   - isSameItem: 两次读数是不是同一首(同一个条目)。
    ///   - isPlaying: 正在播。暂停时时钟不走,变化只可能来自 seek。
    public static func animatesAdvance(
        from previous: TimeInterval,
        to current: TimeInterval,
        isSameItem: Bool,
        isPlaying: Bool
    ) -> Bool {
        guard isSameItem, isPlaying,
              previous.isFinite, current.isFinite else { return false }
        let advance = current - previous
        return advance > 0 && advance <= maximumAnimatedAdvance
    }

    /// 进度比例,夹在 0...1 之间;时长未知或不合法时为 0。
    public static func fraction(time: TimeInterval, duration: TimeInterval) -> Double {
        guard duration.isFinite, duration > 0, time.isFinite else { return 0 }
        return min(max(time / duration, 0), 1)
    }
}

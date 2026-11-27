import Foundation

/// Pure policy for recognizing the end of a MusicKit track.
///
/// `ApplicationMusicPlayer` does not consistently settle on `.stopped`: some
/// OS versions pause and reset `playbackTime`, while others remain `.playing`
/// with a frozen clock. Callers therefore retain the furthest observed time and
/// use a short stall watchdog near the reported duration.
public enum AppleMusicPlaybackEndPolicy {
    public static func isNearEnd(
        duration: TimeInterval,
        playbackTime: TimeInterval,
        furthestObservedTime: TimeInterval
    ) -> Bool {
        guard duration.isFinite, duration > 0 else { return false }
        let tolerance = min(5, max(1.5, duration * 0.02))
        let observedTime = max(playbackTime, furthestObservedTime)
        return observedTime >= max(0, duration - tolerance)
    }

    /// MusicKit 收摊一条播完的 queue 时会把 currentEntry 清掉、或把
    /// playbackTime 归零。这两个信号跟时长无关 —— 资料库歌曲的
    /// `Song.duration` 可能是 nil, 此时 `isNearEnd` 永远为 false,
    /// 光靠近尾判定就再也认不出曲末。用户在控制中心手动暂停时时钟停在
    /// 原地而不是归零, 所以这个信号不会把暂停误当成播完。
    ///
    /// 时长已知时还要播到过离结尾不远的地方: 播到一半被外部打断时 MusicKit 也会
    /// 暂停并把时钟归零, 那不是播完。容差比 `isNearEnd` 宽得多, 资料库与目录给的
    /// 时长差几秒、轮询漏掉最后几拍时照样认得出曲末。
    public static func clockResetAfterPlayback(
        playbackTime: TimeInterval,
        furthestObservedTime: TimeInterval,
        hasCurrentEntry: Bool,
        duration: TimeInterval = 0
    ) -> Bool {
        guard furthestObservedTime > 5 else { return false }
        if duration.isFinite, duration > 0,
           furthestObservedTime < duration - max(20, duration * 0.1) {
            return false
        }
        return !hasCurrentEntry || playbackTime <= 0.05
    }

    public static func shouldAdvance(
        hasObservedActivePlayback: Bool,
        isStopped: Bool,
        isPaused: Bool,
        wasPausedByUser: Bool,
        isPlaybackInterrupted: Bool,
        isNearEnd: Bool,
        clockResetAfterPlayback: Bool = false,
        stalledNearEndSampleCount: Int,
        stallSampleThreshold: Int
    ) -> Bool {
        guard hasObservedActivePlayback else { return false }
        if isPlaybackInterrupted { return false }
        if isStopped { return true }
        if isPaused && !wasPausedByUser && (isNearEnd || clockResetAfterPlayback) { return true }
        return isNearEnd
            && stallSampleThreshold > 0
            && stalledNearEndSampleCount >= stallSampleThreshold
    }
}

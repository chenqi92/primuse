import Foundation

/// Apple Music 的歌由 `ApplicationMusicPlayer` 出声, Primuse 自己的播放时钟不走,
/// 起播、MusicKit 自己换歌和收听进度都只经过播放状态镜像。听歌记录
/// (Last.fm / ListenBrainz、听歌统计、最近播放) 要从镜像的一拍拍采样里推出来:
/// 这一拍是不是新的一次播放, 以及两拍之间算真听了多少秒。
public enum AppleMusicListeningPolicy {
    /// 一次播放的身份。
    public struct Occurrence: Equatable, Sendable {
        public let requestID: UUID
        /// Primuse 托管队列里的条目。同一首歌在队列里出现两次时靠它区分。
        public let queueEntryID: UUID?
        /// MusicKit 条目里那首歌自己的 id。规范化 id 起播几拍内可能从目录版
        /// 跳成资料库版, 这个不跳。
        public let rawSongID: String?
        public let songID: String

        public init(requestID: UUID, queueEntryID: UUID?, rawSongID: String?, songID: String) {
            self.requestID = requestID
            self.queueEntryID = queueEntryID
            self.rawSongID = rawSongID
            self.songID = songID
        }
    }

    /// 镜像的一拍。`uptime` 用单调时钟, 改系统时间不影响。
    public struct Sample: Equatable, Sendable {
        public let playbackTime: TimeInterval
        public let isPlaying: Bool
        public let uptime: TimeInterval

        public init(playbackTime: TimeInterval, isPlaying: Bool, uptime: TimeInterval) {
            self.playbackTime = playbackTime
            self.isPlaying = isPlaying
            self.uptime = uptime
        }
    }

    /// 正在记的这次播放。
    public struct Progress: Equatable, Sendable {
        public fileprivate(set) var occurrence: Occurrence
        /// 开这次播放时记下的歌曲 id。规范化 id 中途换了, 已经开出去的
        /// scrobble 会话仍按这个 id 认。
        public let sessionSongID: String
        public fileprivate(set) var sample: Sample
        public fileprivate(set) var listenedSeconds: TimeInterval

        fileprivate init(occurrence: Occurrence, sample: Sample) {
            self.occurrence = occurrence
            self.sessionSongID = occurrence.songID
            self.sample = sample
            self.listenedSeconds = 0
        }
    }

    public enum Step: Equatable, Sendable {
        /// 新的一次播放: 记最近播放、开 scrobble 与听歌统计的会话。
        case started
        /// 还是这一次, 两拍之间真听了这么多秒。
        case continued(listened: TimeInterval)
    }

    /// 两拍之间播放时间前进量允许比单调时钟多出的部分。镜像在播放时间没变时
    /// 也会被别的字段唤醒, 下一次播放时间更新可能离上一拍很近。
    static let samplingTolerance: TimeInterval = 0.5
    /// 单曲循环在 MusicKit 里不换条目, 只能从「曲尾跳回开头」认出又放了一遍。
    static let restartWindow: TimeInterval = 5
    /// 先真听过一段才认曲尾回到开头是重放。换歌那一拍播放时间可能还是上一首
    /// 曲尾的值, 下一拍才归零, 那时这一次还没听几秒。
    static let restartMinimumListened: TimeInterval = 10

    public static func advance(
        _ progress: inout Progress?,
        occurrence: Occurrence,
        sample: Sample,
        duration: TimeInterval
    ) -> Step {
        guard var current = progress,
              isSameOccurrence(current.occurrence, occurrence),
              !restartedFromTheTop(
                previous: current.sample,
                current: sample,
                duration: duration,
                listenedSoFar: current.listenedSeconds
              ) else {
            progress = Progress(occurrence: occurrence, sample: sample)
            return .started
        }
        let listened = listenedSeconds(from: current.sample, to: sample)
        current.occurrence = occurrence
        current.sample = sample
        current.listenedSeconds += listened
        progress = current
        return .continued(listened: listened)
    }

    static func isSameOccurrence(_ lhs: Occurrence, _ rhs: Occurrence) -> Bool {
        guard lhs.requestID == rhs.requestID else { return false }
        if let left = lhs.queueEntryID, let right = rhs.queueEntryID { return left == right }
        if lhs.songID == rhs.songID { return true }
        if let left = lhs.rawSongID, let right = rhs.rawSongID { return left == right }
        return false
    }

    /// 只有前后两拍都在出声才算听了。往回拖按 0 算; 向前拖跳过的部分不算,
    /// 前进量不超过这段时间实际流逝的秒数 (留一点采样余量)。卡住缓冲时
    /// 播放时间不动, 也是 0。
    static func listenedSeconds(from previous: Sample, to current: Sample) -> TimeInterval {
        guard previous.isPlaying, current.isPlaying else { return 0 }
        let advanced = current.playbackTime - previous.playbackTime
        let elapsed = current.uptime - previous.uptime
        guard advanced.isFinite, elapsed.isFinite, advanced > 0, elapsed >= 0 else { return 0 }
        return min(advanced, elapsed + samplingTolerance)
    }

    static func restartedFromTheTop(
        previous: Sample,
        current: Sample,
        duration: TimeInterval,
        listenedSoFar: TimeInterval
    ) -> Bool {
        guard current.isPlaying,
              listenedSoFar >= restartMinimumListened,
              current.playbackTime < previous.playbackTime,
              current.playbackTime <= restartWindow else { return false }
        return AppleMusicPlaybackEndPolicy.isNearEnd(
            duration: duration,
            playbackTime: previous.playbackTime,
            furthestObservedTime: previous.playbackTime
        )
    }
}

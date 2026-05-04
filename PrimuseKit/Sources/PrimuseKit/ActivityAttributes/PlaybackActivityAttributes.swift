import ActivityKit
import Foundation

public struct PlaybackActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var isPlaying: Bool
        public var elapsedTime: TimeInterval
        public var nextSongTitle: String?
        /// 当前歌词行 — 锁屏 / Dynamic Island expanded view 显示。
        /// nil 时不显示歌词区, 退化为只有 song title + artist + progress。
        public var currentLyricLine: String?
        /// 下一行歌词 — 让用户预览即将到的内容, 看锁屏体验更连贯。
        public var nextLyricLine: String?
        /// 当前播放的"开始时间锚点" — `now - elapsed`, 让 ProgressView 用
        /// `timerInterval:` API 自动 tick (系统级动画, 不依赖我们 push)。
        /// 暂停 / 没在播 时为 nil, UI 端退化为静态进度。
        public var startedAt: Date?

        public init(
            isPlaying: Bool,
            elapsedTime: TimeInterval,
            nextSongTitle: String? = nil,
            currentLyricLine: String? = nil,
            nextLyricLine: String? = nil,
            startedAt: Date? = nil
        ) {
            self.isPlaying = isPlaying
            self.elapsedTime = elapsedTime
            self.nextSongTitle = nextSongTitle
            self.currentLyricLine = currentLyricLine
            self.nextLyricLine = nextLyricLine
            self.startedAt = startedAt
        }
    }

    public var songTitle: String
    public var artistName: String
    public var albumTitle: String
    public var duration: TimeInterval
    /// Filename of cover image stored in the App Group shared container.
    /// The widget extension loads this from the shared container at render time.
    public var coverImageName: String?

    public init(songTitle: String, artistName: String, albumTitle: String, duration: TimeInterval, coverImageName: String? = nil) {
        self.songTitle = songTitle
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.duration = duration
        self.coverImageName = coverImageName
    }
}

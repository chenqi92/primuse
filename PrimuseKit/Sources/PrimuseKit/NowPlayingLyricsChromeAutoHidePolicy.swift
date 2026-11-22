import Foundation

/// 歌词页停一会儿自动收起播放控件(「播放页按钮 › 歌词界面」里的开关,默认关)。
/// 只在竖屏歌词顶替封面、上滑也能收起控件的那几种版面上计时;正在放、有歌词时才收。
/// 倒计时从最后一次操作(点按、滑歌词、拖进度条)算起,进度条还拖着时不收。
public enum NowPlayingLyricsChromeAutoHidePolicy {
    /// 和全屏歌词控件自动隐藏同一个节奏。
    public static let idleDelay: TimeInterval = 4

    public struct Conditions: Equatable, Sendable {
        /// 设置里开着。只管音乐,有声内容的文字稿不计时。
        public var isEnabled: Bool
        /// 歌词顶替了封面。
        public var showsLyrics: Bool
        /// 全屏歌词有自己的一套自动隐藏。
        public var isImmersive: Bool
        /// 眼前的版面会照收起状态让出控件(竖屏那几种);横屏、分栏不收。
        public var hostsCollapsibleLyrics: Bool
        /// 播放页就是眼前这一页:前台、没收起、没有弹出页、没进全屏效果。
        public var isSurfaceActive: Bool
        public var isPlaying: Bool
        public var hasLyrics: Bool
        public var isVoiceOverRunning: Bool
        /// 正按住上一首 / 下一首走快退快进的预览。
        public var isScrubbing: Bool
        public var isCollapsed: Bool

        public init(
            isEnabled: Bool,
            showsLyrics: Bool,
            isImmersive: Bool,
            hostsCollapsibleLyrics: Bool,
            isSurfaceActive: Bool,
            isPlaying: Bool,
            hasLyrics: Bool,
            isVoiceOverRunning: Bool,
            isScrubbing: Bool,
            isCollapsed: Bool
        ) {
            self.isEnabled = isEnabled
            self.showsLyrics = showsLyrics
            self.isImmersive = isImmersive
            self.hostsCollapsibleLyrics = hostsCollapsibleLyrics
            self.isSurfaceActive = isSurfaceActive
            self.isPlaying = isPlaying
            self.hasLyrics = hasLyrics
            self.isVoiceOverRunning = isVoiceOverRunning
            self.isScrubbing = isScrubbing
            self.isCollapsed = isCollapsed
        }
    }

    /// 要不要留意操作:开关开着、正看着会收起控件的那页歌词。暂停、已经收起时也留意,
    /// 不用每次播放暂停、叫回控件都重新挂一遍。
    public static func tracksActivity(_ conditions: Conditions) -> Bool {
        conditions.isEnabled
            && conditions.showsLyrics
            && !conditions.isImmersive
            && conditions.hostsCollapsibleLyrics
            && conditions.isSurfaceActive
    }

    /// 此刻能不能开始倒计时。VoiceOver 下不收:控件没了就摸不到。
    public static func mayAutoHide(_ conditions: Conditions) -> Bool {
        tracksActivity(conditions)
            && conditions.isPlaying
            && conditions.hasLyrics
            && !conditions.isVoiceOverRunning
            && !conditions.isScrubbing
            && !conditions.isCollapsed
    }

    /// 还要等多久才收,0 是该收了。还有没结束的操作(手指拖着进度条不动)时从头等一整段。
    public static func remainingDelay(sinceLastActivity elapsed: TimeInterval, isInteracting: Bool) -> TimeInterval {
        guard !isInteracting, elapsed.isFinite, elapsed >= 0 else { return idleDelay }
        return max(0, idleDelay - elapsed)
    }
}

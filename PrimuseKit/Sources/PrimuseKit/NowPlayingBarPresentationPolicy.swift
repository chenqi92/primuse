import Foundation

/// 正在播放那一条的第二行写什么。
public enum NowPlayingBarSubtitle: Sendable, Equatable {
    /// 播放失败的原因。从列表里点的歌可能在播放页没打开时就失败了,这一行是唯一还能说明原因的地方。
    case error(String)
    /// 艺术家。
    case artist(String)

    public var text: String {
        switch self {
        case .error(let message): return message
        case .artist(let name): return name
        }
    }
}

/// 外壳里正在播放那一条(标签栏附件迷你条、通栏停靠条、悬浮胶囊)共用的取值规则。
///
/// 三种画法收的是同一份数据,文字、朗读标签与进度的算法只在这里写一次 —— 换一种画法不会让
/// 其中一条说得不一样、或者进度走得不一样。
public enum NowPlayingBarPresentationPolicy {
    /// 第二行:出错时写原因,否则写艺术家;都没有就不写。出错时不去取艺术家。
    public static func subtitle(
        playbackError: String?,
        artistName: @autoclosure () -> String?
    ) -> NowPlayingBarSubtitle? {
        if let playbackError { return .error(playbackError) }
        if let artistName = artistName(), !artistName.isEmpty { return .artist(artistName) }
        return nil
    }

    /// 整条的朗读标签:「正在播放: 歌名: 第二行」,空的部分略过。第二行只在画出来时才念。
    public static func accessibilityLabel(
        nowPlaying: String,
        title: String,
        subtitle: NowPlayingBarSubtitle?
    ) -> String {
        var parts = [nowPlaying, title]
        if let subtitle { parts.append(subtitle.text) }
        return parts.filter { !$0.isEmpty }.joined(separator: ": ")
    }

    /// 可用的总时长。未知、无限或非正数时是 0(进度一律画成空)。
    public static func duration(_ duration: Double) -> Double {
        duration.isFinite && duration > 0 ? duration : 0
    }

    /// 播放进度,0...1。直播电台没有进度;时长或时刻不可用时是 0。
    public static func progress(elapsed: Double, duration: Double, isLiveRadio: Bool) -> Double {
        let duration = Self.duration(duration)
        guard !isLiveRadio, duration > 0, elapsed.isFinite else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }

    /// 进度的这次变化是不是一次普通的时钟推进(往前走、不超过一秒)。
    ///
    /// 引擎每半秒报一次进度,正常推进时用同样时长的线性动画把两次采样之间补平;换歌、拖动、跳转
    /// 都要硬跳 —— 否则换歌时进度会从上一首的位置一路倒扫回起点。
    public static func isClockAdvance(from previous: Double, to current: Double, duration: Double) -> Bool {
        let duration = Self.duration(duration)
        guard duration > 0 else { return false }
        let advanced = (current - previous) * duration
        return advanced > 0 && advanced <= 1
    }
}

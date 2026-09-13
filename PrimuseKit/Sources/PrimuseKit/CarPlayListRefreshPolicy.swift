import Foundation

/// CarPlay 侧关心的播放状态快照。
public struct CarPlayPlayerState: Equatable, Sendable {
    public var songID: String?
    public var songTitle: String?
    public var stationID: String?
    public var stationName: String?
    public var isPlaying: Bool
    public var shuffleEnabled: Bool
    public var repeatModeRawValue: String
    public var currentIndex: Int
    public var radioMetadataTitle: String?

    public init(
        songID: String? = nil,
        songTitle: String? = nil,
        stationID: String? = nil,
        stationName: String? = nil,
        isPlaying: Bool = false,
        shuffleEnabled: Bool = false,
        repeatModeRawValue: String = "",
        currentIndex: Int = 0,
        radioMetadataTitle: String? = nil
    ) {
        self.songID = songID
        self.songTitle = songTitle
        self.stationID = stationID
        self.stationName = stationName
        self.isPlaying = isPlaying
        self.shuffleEnabled = shuffleEnabled
        self.repeatModeRawValue = repeatModeRawValue
        self.currentIndex = currentIndex
        self.radioMetadataTitle = radioMetadataTitle
    }
}

public enum CarPlayListRefreshPolicy {
    /// 首页与各详情页里的每一行,文字和封面都只取决于「在放哪一首 / 哪个台」。
    ///
    /// 播放暂停、随机、循环、队列位置、电台曲目元数据都不改变任何一行的内容,
    /// 但它们变得非常勤。为它们重建整张列表,等于把所有行退回占位图再逐个重取,
    /// 用户看到的就是封面不停闪。电台列表是例外 —— 它要显示正在播放指示和当前
    /// 曲目名,由调用方单独刷新。
    public static func listsNeedRebuild(
        from previous: CarPlayPlayerState?,
        to next: CarPlayPlayerState
    ) -> Bool {
        guard let previous else { return true }
        return previous.songID != next.songID
            || previous.songTitle != next.songTitle
            || previous.stationID != next.stationID
            || previous.stationName != next.stationName
    }
}

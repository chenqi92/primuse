import Foundation

/// 直播流在播放过程中推过来的「此刻在放什么」。
///
/// 两条链路会产出它：AVPlayer 的 timed metadata(Shoutcast 的 ICY 会被系统
/// 翻译成 timed metadata，HLS 则是分片里的 ID3)，以及自解码链路直接读到的
/// 带内 ICY 元数据。两边归一到同一个类型，播放页就只需要认一种数据。
public struct RadioLiveMetadata: Equatable, Sendable {
    /// 解析过的 `StreamTitle`。可能是一首歌，也可能是节目名或台宣。
    public let title: RadioStreamTitle?
    /// 此刻这首歌/这档节目的配图。电台给的话通常比台标更贴切。
    public let artworkURL: String?
    /// 元数据里顺带给出的电台主页。
    public let homepageURL: String?

    public init(title: RadioStreamTitle?, artworkURL: String?, homepageURL: String?) {
        self.title = title
        self.artworkURL = artworkURL
        self.homepageURL = homepageURL
    }

    public init(icy: RadioICYMetadata) {
        self.init(
            title: RadioStreamTitleParser.parse(icy.streamTitle),
            artworkURL: icy.artworkURL,
            homepageURL: icy.homepageURL
        )
    }

    public static let empty = RadioLiveMetadata(
        title: nil,
        artworkURL: nil,
        homepageURL: nil
    )

    public var isEmpty: Bool {
        title == nil && artworkURL == nil && homepageURL == nil
    }

    /// 界面直接显示的文本。
    public var displayText: String? { title?.rawText }
}

/// 一条播放历史。电台没有播放列表，但「刚才放过什么」对听众是有意义的 ——
/// 播放页可以用它做一条向下滚动的节目/曲目流。
public struct RadioTitleHistoryEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: RadioStreamTitle
    public let artworkURL: String?
    public let startedAt: Date

    public init(
        id: UUID = UUID(),
        title: RadioStreamTitle,
        artworkURL: String? = nil,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.artworkURL = artworkURL
        self.startedAt = startedAt
    }
}

public enum RadioTitleHistoryPolicy {
    /// 保留的条数。电台一小时能推二三十条，留三十条够翻回上一小时，
    /// 又不至于让播放页背着一份无限增长的数组。
    public static let maximumEntries = 30

    /// 追加一条。同一首歌电台会每隔几秒重复推送，重复的不入历史 ——
    /// 否则列表会被同一行刷屏。
    public static func appending(
        _ metadata: RadioLiveMetadata,
        to history: [RadioTitleHistoryEntry],
        at date: Date = Date()
    ) -> [RadioTitleHistoryEntry] {
        guard let title = metadata.title else { return history }
        if let latest = history.first,
           RadioStreamTitleParser.isSameTrack(latest.title, title) {
            return history
        }
        var result = history
        result.insert(
            RadioTitleHistoryEntry(
                title: title,
                artworkURL: metadata.artworkURL,
                startedAt: date
            ),
            at: 0
        )
        if result.count > maximumEntries {
            result.removeLast(result.count - maximumEntries)
        }
        return result
    }
}

/// 直播流里的一条字幕轨。
///
/// 实测(2026-09 抽样 400 个热门电台，其中 13 个 HLS)没有一个广播电台带
/// WebVTT 字幕轨 —— 这条链路是为「电视伴音流」和将来可能出现的带字幕广播
/// 准备的：检测不到就完全不启用，一分钱开销都不产生。
public struct RadioSubtitleTrack: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let languageCode: String?

    public init(id: String, displayName: String, languageCode: String?) {
        self.id = id
        self.displayName = displayName
        self.languageCode = languageCode
    }
}

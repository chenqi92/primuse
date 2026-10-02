import Foundation

/// 一档已订阅的播客节目。节目信息来自它的 RSS,订阅时间、刷新水位和单档设置是本机记的。
///
/// `id` 由订阅时的 feed 地址算出来,之后 feed 搬家(`itunes:new-feed-url`)只改 `feedURL`,
/// id 不变 —— 播放进度、下载和首页挑选都挂在 id 上。
public struct PodcastShow: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var feedURL: URL
    public var title: String
    public var author: String?
    public var summary: String?
    public var artworkURL: URL?
    public var websiteURL: URL?
    public var language: String?
    public var categories: [String]
    /// `itunes:type` 为 serial:按集数从头听的连载,单集列表默认从旧到新。
    public var isSerial: Bool
    public var isExplicit: Bool
    /// Apple 播客目录里的 collectionId;从目录订阅的才有。
    public var directoryID: Int?
    public var subscribedAt: Date
    public var lastRefreshedAt: Date?
    public var latestEpisodeAt: Date?
    public var httpETag: String?
    public var httpLastModified: String?
    public var settings: PodcastShowSettings
    /// 「全部标为已播」「之前的都标为已播」:发布时间不晚于它的单集都算听过。
    /// 用一条水位线而不是逐集记,几百集的节目标一次也只占一个日期。
    public var playedThrough: Date?
    /// 水位线以下又被单独标回「未播」的单集。
    public var reopenedEpisodeIDs: Set<String>
    /// 订阅定义(设置、水位线)最后一次被用户改动的时间,多设备合并时按它取新。
    public var definitionModifiedAt: Date

    public init(
        id: String,
        feedURL: URL,
        title: String,
        author: String? = nil,
        summary: String? = nil,
        artworkURL: URL? = nil,
        websiteURL: URL? = nil,
        language: String? = nil,
        categories: [String] = [],
        isSerial: Bool = false,
        isExplicit: Bool = false,
        directoryID: Int? = nil,
        subscribedAt: Date,
        lastRefreshedAt: Date? = nil,
        latestEpisodeAt: Date? = nil,
        httpETag: String? = nil,
        httpLastModified: String? = nil,
        settings: PodcastShowSettings = PodcastShowSettings(),
        playedThrough: Date? = nil,
        reopenedEpisodeIDs: Set<String> = [],
        definitionModifiedAt: Date? = nil
    ) {
        self.id = id
        self.feedURL = feedURL
        self.title = title
        self.author = author
        self.summary = summary
        self.artworkURL = artworkURL
        self.websiteURL = websiteURL
        self.language = language
        self.categories = categories
        self.isSerial = isSerial
        self.isExplicit = isExplicit
        self.directoryID = directoryID
        self.subscribedAt = subscribedAt
        self.lastRefreshedAt = lastRefreshedAt
        self.latestEpisodeAt = latestEpisodeAt
        self.httpETag = httpETag
        self.httpLastModified = httpLastModified
        self.settings = settings
        self.playedThrough = playedThrough
        self.reopenedEpisodeIDs = reopenedEpisodeIDs
        self.definitionModifiedAt = definitionModifiedAt ?? subscribedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, feedURL, title, author, summary, artworkURL, websiteURL, language, categories
        case isSerial, isExplicit, directoryID, subscribedAt, lastRefreshedAt, latestEpisodeAt
        case httpETag, httpLastModified, settings, playedThrough, reopenedEpisodeIDs, definitionModifiedAt
    }

    // 存盘格式以后会加字段:缺的一律取默认值,别让一个新字段把整份订阅读丢。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        feedURL = try c.decode(URL.self, forKey: .feedURL)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        artworkURL = try c.decodeIfPresent(URL.self, forKey: .artworkURL)
        websiteURL = try c.decodeIfPresent(URL.self, forKey: .websiteURL)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        categories = try c.decodeIfPresent([String].self, forKey: .categories) ?? []
        isSerial = try c.decodeIfPresent(Bool.self, forKey: .isSerial) ?? false
        isExplicit = try c.decodeIfPresent(Bool.self, forKey: .isExplicit) ?? false
        directoryID = try c.decodeIfPresent(Int.self, forKey: .directoryID)
        subscribedAt = try c.decodeIfPresent(Date.self, forKey: .subscribedAt) ?? .distantPast
        lastRefreshedAt = try c.decodeIfPresent(Date.self, forKey: .lastRefreshedAt)
        latestEpisodeAt = try c.decodeIfPresent(Date.self, forKey: .latestEpisodeAt)
        httpETag = try c.decodeIfPresent(String.self, forKey: .httpETag)
        httpLastModified = try c.decodeIfPresent(String.self, forKey: .httpLastModified)
        settings = try c.decodeIfPresent(PodcastShowSettings.self, forKey: .settings) ?? PodcastShowSettings()
        playedThrough = try c.decodeIfPresent(Date.self, forKey: .playedThrough)
        reopenedEpisodeIDs = try c.decodeIfPresent(Set<String>.self, forKey: .reopenedEpisodeIDs) ?? []
        definitionModifiedAt = try c.decodeIfPresent(Date.self, forKey: .definitionModifiedAt) ?? subscribedAt
    }

    /// 这一集是不是被「标为已播」的水位线盖住了(单集自己的听完记录另算)。
    public func isMarkedPlayed(_ episode: PodcastEpisode) -> Bool {
        guard let playedThrough, let published = episode.publishedAt else { return false }
        return published <= playedThrough && !reopenedEpisodeIDs.contains(episode.id)
    }

    /// 单集列表实际用的顺序:用户选过就用选的,否则连载从旧到新、其余从新到旧。
    public var effectiveEpisodeOrder: PodcastEpisodeOrder {
        settings.episodeOrder ?? (isSerial ? .oldestFirst : .newestFirst)
    }
}

/// 每档节目自己的设置。全部有默认值,没动过的节目跟全局走。
public struct PodcastShowSettings: Codable, Hashable, Sendable {
    /// nil = 跟节目类型(连载从旧到新,其余从新到旧)。
    public var episodeOrder: PodcastEpisodeOrder?
    /// 刷新到新单集时自动下载。
    public var autoDownloadsNewEpisodes: Bool
    /// 从这一档的每一集开头跳过多少秒(片头)。
    public var skipIntroSeconds: Int
    /// 离结尾还剩多少秒就当播完(片尾)。
    public var skipOutroSeconds: Int

    public init(
        episodeOrder: PodcastEpisodeOrder? = nil,
        autoDownloadsNewEpisodes: Bool = false,
        skipIntroSeconds: Int = 0,
        skipOutroSeconds: Int = 0
    ) {
        self.episodeOrder = episodeOrder
        self.autoDownloadsNewEpisodes = autoDownloadsNewEpisodes
        self.skipIntroSeconds = skipIntroSeconds
        self.skipOutroSeconds = skipOutroSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case episodeOrder, autoDownloadsNewEpisodes, skipIntroSeconds, skipOutroSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        episodeOrder = try c.decodeIfPresent(PodcastEpisodeOrder.self, forKey: .episodeOrder)
        autoDownloadsNewEpisodes = try c.decodeIfPresent(Bool.self, forKey: .autoDownloadsNewEpisodes) ?? false
        skipIntroSeconds = try c.decodeIfPresent(Int.self, forKey: .skipIntroSeconds) ?? 0
        skipOutroSeconds = try c.decodeIfPresent(Int.self, forKey: .skipOutroSeconds) ?? 0
    }

    /// 片头/片尾可选的秒数,设置页的菜单用。
    public static let skipChoices = [0, 5, 10, 15, 20, 30, 45, 60, 90, 120]
}

public enum PodcastEpisodeOrder: String, Codable, CaseIterable, Sendable {
    case newestFirst
    case oldestFirst
}

/// `itunes:episodeType`。预告和花絮在列表里单独标出来,不算进「从头听」的顺序。
public enum PodcastEpisodeKind: String, Codable, Sendable {
    case full
    case trailer
    case bonus

    public init(feedValue: String?) {
        switch feedValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "trailer": self = .trailer
        case "bonus": self = .bonus
        default: self = .full
        }
    }
}

public struct PodcastChapter: Codable, Hashable, Sendable {
    public var start: TimeInterval
    public var title: String
    public var url: URL?
    public var imageURL: URL?

    public init(start: TimeInterval, title: String, url: URL? = nil, imageURL: URL? = nil) {
        self.start = start
        self.title = title
        self.url = url
        self.imageURL = imageURL
    }
}

/// 一集。`id` 同时也是播放时那首 `Song` 的 id(带 `podcast:` 前缀),进度、听完、下载都按它记。
public struct PodcastEpisode: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var showID: String
    public var guid: String
    public var title: String
    public var subtitle: String?
    /// 节目说明原文,多半是 HTML。显示前交给 `PodcastShowNotes`。
    public var showNotes: String?
    public var publishedAt: Date?
    public var duration: TimeInterval?
    public var enclosureURL: URL
    public var enclosureType: String?
    public var enclosureLength: Int64?
    public var artworkURL: URL?
    public var season: Int?
    public var number: Int?
    public var kind: PodcastEpisodeKind
    public var link: URL?
    /// Podcasting 2.0 `podcast:chapters` 指向的 JSON。
    public var chaptersURL: URL?
    /// feed 里直接写的章节(Podlove `psc:chapters`)。
    public var chapters: [PodcastChapter]
    public var transcriptURL: URL?
    public var transcriptType: String?
    public var isExplicit: Bool
    /// 本机第一次在 feed 里看到这一集的时间,用来判断「订阅之后才出的新单集」。
    public var firstSeenAt: Date

    public init(
        id: String,
        showID: String,
        guid: String,
        title: String,
        subtitle: String? = nil,
        showNotes: String? = nil,
        publishedAt: Date? = nil,
        duration: TimeInterval? = nil,
        enclosureURL: URL,
        enclosureType: String? = nil,
        enclosureLength: Int64? = nil,
        artworkURL: URL? = nil,
        season: Int? = nil,
        number: Int? = nil,
        kind: PodcastEpisodeKind = .full,
        link: URL? = nil,
        chaptersURL: URL? = nil,
        chapters: [PodcastChapter] = [],
        transcriptURL: URL? = nil,
        transcriptType: String? = nil,
        isExplicit: Bool = false,
        firstSeenAt: Date
    ) {
        self.id = id
        self.showID = showID
        self.guid = guid
        self.title = title
        self.subtitle = subtitle
        self.showNotes = showNotes
        self.publishedAt = publishedAt
        self.duration = duration
        self.enclosureURL = enclosureURL
        self.enclosureType = enclosureType
        self.enclosureLength = enclosureLength
        self.artworkURL = artworkURL
        self.season = season
        self.number = number
        self.kind = kind
        self.link = link
        self.chaptersURL = chaptersURL
        self.chapters = chapters
        self.transcriptURL = transcriptURL
        self.transcriptType = transcriptType
        self.isExplicit = isExplicit
        self.firstSeenAt = firstSeenAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, showID, guid, title, subtitle, showNotes, publishedAt, duration
        case enclosureURL, enclosureType, enclosureLength, artworkURL, season, number, kind, link
        case chaptersURL, chapters, transcriptURL, transcriptType, isExplicit, firstSeenAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        showID = try c.decode(String.self, forKey: .showID)
        guid = try c.decodeIfPresent(String.self, forKey: .guid) ?? id
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        showNotes = try c.decodeIfPresent(String.self, forKey: .showNotes)
        publishedAt = try c.decodeIfPresent(Date.self, forKey: .publishedAt)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration)
        enclosureURL = try c.decode(URL.self, forKey: .enclosureURL)
        enclosureType = try c.decodeIfPresent(String.self, forKey: .enclosureType)
        enclosureLength = try c.decodeIfPresent(Int64.self, forKey: .enclosureLength)
        artworkURL = try c.decodeIfPresent(URL.self, forKey: .artworkURL)
        season = try c.decodeIfPresent(Int.self, forKey: .season)
        number = try c.decodeIfPresent(Int.self, forKey: .number)
        kind = try c.decodeIfPresent(PodcastEpisodeKind.self, forKey: .kind) ?? .full
        link = try c.decodeIfPresent(URL.self, forKey: .link)
        chaptersURL = try c.decodeIfPresent(URL.self, forKey: .chaptersURL)
        chapters = try c.decodeIfPresent([PodcastChapter].self, forKey: .chapters) ?? []
        transcriptURL = try c.decodeIfPresent(URL.self, forKey: .transcriptURL)
        transcriptType = try c.decodeIfPresent(String.self, forKey: .transcriptType)
        isExplicit = try c.decodeIfPresent(Bool.self, forKey: .isExplicit) ?? false
        firstSeenAt = try c.decodeIfPresent(Date.self, forKey: .firstSeenAt) ?? publishedAt ?? .distantPast
    }

    /// 音频文件的扩展名:先看地址,地址里没有就按 MIME 猜,都没有当 mp3。
    public var audioFileExtension: String {
        let pathExtension = enclosureURL.pathExtension.lowercased()
        if PodcastIdentity.knownAudioExtensions.contains(pathExtension) { return pathExtension }
        switch enclosureType?.lowercased() {
        case "audio/mp4", "audio/x-m4a", "audio/m4a", "audio/aac", "audio/x-m4b": return "m4a"
        case "audio/ogg", "audio/opus": return "ogg"
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/wav", "audio/x-wav": return "wav"
        case "video/mp4": return "mp4"
        default: return "mp3"
        }
    }

    /// 视频播客(enclosure 是视频)。目前只放声音,列表上标出来。
    public var isVideo: Bool {
        if let type = enclosureType?.lowercased(), type.hasPrefix("video/") { return true }
        return ["mp4", "m4v", "mov"].contains(enclosureURL.pathExtension.lowercased())
            && enclosureType?.lowercased().hasPrefix("audio/") != true
    }
}

/// 节目与单集的稳定 id。不依赖 CryptoKit,Linux 上也能算,结果跨版本不变。
public enum PodcastIdentity {
    /// 单集当歌播放时 `Song.id` 的前缀,播放器靠它认出「这是播客」。
    public static let episodeIDPrefix = "podcast:"
    public static let showIDPrefix = "podcast-show:"

    static let knownAudioExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "ogg", "oga", "opus", "flac", "wav", "mp4", "m4v", "mov"]

    public static func showID(feedURL: URL) -> String {
        showIDPrefix + digest(PodcastFeedURL.identityKey(for: feedURL))
    }

    public static func episodeID(showID: String, guid: String) -> String {
        episodeIDPrefix + digest(showID + "\n" + guid)
    }

    public static func isEpisodeID(_ id: String) -> Bool {
        id.hasPrefix(episodeIDPrefix)
    }

    /// 两条不同种子的 FNV-1a 64 拼成 128 位,32 个十六进制字符。
    public static func digest(_ value: String) -> String {
        var first: UInt64 = 0xcbf2_9ce4_8422_2325
        var second: UInt64 = 0x8422_2325_cbf2_9ce4
        for byte in value.utf8 {
            first ^= UInt64(byte)
            first = first &* 0x0000_0100_0000_01b3
            second = (second ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            second ^= second >> 29
        }
        return hex(first) + hex(second)
    }

    private static func hex(_ value: UInt64) -> String {
        let raw = String(value, radix: 16)
        return String(repeating: "0", count: max(0, 16 - raw.count)) + raw
    }
}

/// 用户贴进来的 feed 地址的整理。
public enum PodcastFeedURL {
    /// 把 `itpc://` `pcast://` `feed://` `podcast://`、`feed:https://…` 和没写协议的地址
    /// 整理成能直接请求的 http(s) 地址;不像地址的返回 nil。
    public static func normalized(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        let lowered = text.lowercased()
        for prefix in ["feed:https://", "feed:http://"] where lowered.hasPrefix(prefix) {
            text = String(text.dropFirst("feed:".count))
        }
        for scheme in ["itpc://", "pcast://", "feed://", "podcast://", "podcasts://"]
        where text.lowercased().hasPrefix(scheme) {
            text = "https://" + text.dropFirst(scheme.count)
        }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            guard !text.contains("://") else { return nil }
            text = "https://" + text
        }
        guard let components = URLComponents(string: text),
              let host = components.host, host.contains("."), !host.hasPrefix("."),
              let url = components.url else { return nil }
        return url
    }

    /// 判断同一档节目用的键:协议不分 http/https、主机不分大小写、去掉末尾斜杠和 #片段。
    public static func identityKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.scheme = nil
        components.fragment = nil
        components.host = components.host?.lowercased()
        if components.port == 80 || components.port == 443 { components.port = nil }
        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path
        return components.string ?? url.absoluteString
    }

    /// Apple 播客的节目页(`podcasts.apple.com/…/id123456`)里的目录 id。
    public static func appleDirectoryID(in raw: String) -> Int? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased(),
              host == "podcasts.apple.com" || host == "itunes.apple.com" else { return nil }
        for component in url.pathComponents.reversed() where component.hasPrefix("id") {
            if let id = Int(component.dropFirst(2)), id > 0 { return id }
        }
        if let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let value = query.first(where: { $0.name == "id" })?.value, let id = Int(value) {
            return id
        }
        return nil
    }
}

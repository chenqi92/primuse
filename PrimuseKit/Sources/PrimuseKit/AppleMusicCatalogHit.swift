import Foundation

/// 一条 Apple Music 目录搜索结果,已经脱掉 MusicKit 的类型。
///
/// 界面层不直接碰 MusicKit:一来目录结果与曲库歌曲的展示要一致,二来这层
/// 纯值类型可以在没有 MusicKit 的环境里断言。
public struct AppleMusicCatalogHit: Sendable, Equatable, Identifiable {
    /// MusicKit 的 item ID。播放时原样交给 `ApplicationMusicPlayer`。
    public let id: String
    public let title: String
    public let artistName: String
    public let albumTitle: String
    public let duration: TimeInterval
    public let artworkURL: URL?

    public init(
        id: String,
        title: String,
        artistName: String,
        albumTitle: String,
        duration: TimeInterval,
        artworkURL: URL?
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.duration = duration
        self.artworkURL = artworkURL
    }
}

/// 目录里的一张专辑。选中即整张入队播放,不另开详情页。
public struct AppleMusicCatalogAlbumHit: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let artistName: String
    public let artworkURL: URL?

    public init(id: String, title: String, artistName: String, artworkURL: URL?) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.artworkURL = artworkURL
    }
}

/// 目录里的一位艺术家。选中即播其热门曲目。
public struct AppleMusicCatalogArtistHit: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let artworkURL: URL?

    public init(id: String, name: String, artworkURL: URL?) {
        self.id = id
        self.name = name
        self.artworkURL = artworkURL
    }
}

/// 用户在 Apple Music 里建的歌单。
public struct AppleMusicPlaylistHit: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let curatorName: String
    public let artworkURL: URL?

    public init(id: String, name: String, curatorName: String, artworkURL: URL?) {
        self.id = id
        self.name = name
        self.curatorName = curatorName
        self.artworkURL = artworkURL
    }
}

public enum AppleMusicCatalogSearchPolicy {
    /// 一次取多少条。电视上一屏放不下太多,取多了只是白等网络。
    public static let resultLimit = 25

    /// 防抖。与搜索框自己的防抖错开,避免连击打出多次目录请求。
    public static let debounce: Duration = .milliseconds(250)

    /// 该不该发起目录搜索。未授权时直接不发 —— 搜索框每敲一下就弹一次授权
    /// 对话框是不可接受的,授权只在用户真正点播某一条时才请求。
    public static func shouldSearch(
        term: String,
        authorization: AppleMusicAuthorizationState
    ) -> Bool {
        guard authorization == .authorized else { return false }
        return !normalized(term).isEmpty
    }

    public static func normalized(_ term: String) -> String {
        term.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 专辑与艺术家在电视上横向排布,取够一屏即可。
    public static let collectionResultLimit = 12

    /// 目录结果里可能混进曲库里已经有的同一首歌。已在曲库中的条目由曲库那一段
    /// 负责展示,目录段落把它去掉,避免同一首歌在同一个搜索页出现两次。
    public static func deduplicated(
        _ hits: [AppleMusicCatalogHit],
        excludingItemIDs existing: Set<String>
    ) -> [AppleMusicCatalogHit] {
        deduplicatedByID(hits, excluding: existing)
    }

    /// 按 id 去重并剔除排除集,保持原顺序。专辑、艺术家、歌单共用。
    public static func deduplicatedByID<Hit: Identifiable>(
        _ hits: [Hit],
        excluding existing: Set<String> = []
    ) -> [Hit] where Hit.ID == String {
        var seen = Set<String>()
        return hits.filter { hit in
            guard !existing.contains(hit.id) else { return false }
            return seen.insert(hit.id).inserted
        }
    }
}

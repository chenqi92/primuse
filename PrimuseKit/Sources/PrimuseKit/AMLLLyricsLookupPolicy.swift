import Foundation

/// AMLL TTML DB（github.com/amll-dev/amll-ttml-db）的官方查询接口 `api.amll.dev`。
/// 社区人工打轴的逐字 TTML 歌词库，常带翻译、对唱分声部与和声；收录以热门歌曲为主。
/// 接口免认证、按 IP 限流（平均每秒 50 次，超了回 429）；搜索结果不带歌词正文，
/// 要按 id 再取一次，按 id 取到的内容不会变。
///
/// 这里只放纯逻辑（请求地址、响应解码、候选匹配、时长核对），好在 Linux 上直接测。
public enum AMLLLyricsLookupPolicy {
    public static let host = "api.amll.dev"
    /// 同一首歌常有好几份（不同人打的轴、合唱版），同名歌也不少，一页 50 条够用。
    public static let searchPageSize = 50
    /// 按可信度挑出来以后，最多取几份歌词核对时长。
    public static let maximumLyricsFetches = 3
    /// 歌词最后一句允许比歌曲时长晚多少秒（打轴与音频母带的细小出入）。
    public static let lyricsOverrunTolerance: TimeInterval = 3
    /// 歌词最后一句至少要唱到歌曲时长的这个比例，否则多半是 TV size、片段一类的短版本。
    public static let minimumLyricsCoverage = 0.4

    public struct Query: Sendable, Equatable {
        public var title: String
        public var artist: String?
        public var album: String?
        /// 秒；nil 或 ≤0 表示不知道。
        public var duration: TimeInterval?

        public init(title: String, artist: String?, album: String? = nil, duration: TimeInterval? = nil) {
            self.title = title
            self.artist = artist
            self.album = album
            self.duration = duration
        }
    }

    /// 接口里的一首歌。搜索结果的 `lyrics` 恒为 nil，按 id 取的才有。
    public struct SongItem: Decodable, Sendable, Equatable {
        public var id: Int64
        public var musicNames: [String]
        public var artistNames: [String]
        public var albumNames: [String]
        public var lyrics: String?

        public init(
            id: Int64,
            musicNames: [String],
            artistNames: [String],
            albumNames: [String] = [],
            lyrics: String? = nil
        ) {
            self.id = id
            self.musicNames = musicNames
            self.artistNames = artistNames
            self.albumNames = albumNames
            self.lyrics = lyrics
        }

        private enum CodingKeys: String, CodingKey {
            case id, musicNames, artistNames, albumNames, lyrics
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int64.self, forKey: .id)
            musicNames = try container.decodeIfPresent([String].self, forKey: .musicNames) ?? []
            artistNames = try container.decodeIfPresent([String].self, forKey: .artistNames) ?? []
            albumNames = try container.decodeIfPresent([String].self, forKey: .albumNames) ?? []
            lyrics = try container.decodeIfPresent(String.self, forKey: .lyrics)
        }
    }

    private struct SearchEnvelope: Decodable {
        struct Page: Decodable { let items: [SongItem] }
        let data: Page
    }

    private struct GetEnvelope: Decodable {
        let data: SongItem
    }

    // MARK: - Requests

    /// `GET /v1/lyrics/search?musicName=&artistName=&pageSize=`。两个字段在接口里都是「包含」匹配。
    public static func searchURL(title: String, artistName: String?) -> URL? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }
        var items = [URLQueryItem(name: "musicName", value: trimmedTitle)]
        if let artistName = artistName?.trimmingCharacters(in: .whitespacesAndNewlines), !artistName.isEmpty {
            items.append(URLQueryItem(name: "artistName", value: artistName))
        }
        items.append(URLQueryItem(name: "pageSize", value: String(searchPageSize)))
        return url(path: "/v1/lyrics/search", items: items)
    }

    /// `GET /v1/lyrics/get?id=`，返回元数据和完整 TTML。
    public static func lyricsURL(id: Int64) -> URL? {
        guard id >= 0 else { return nil }
        return url(path: "/v1/lyrics/get", items: [URLQueryItem(name: "id", value: String(id))])
    }

    /// 第一次搜索带上的歌手：歌手字段里有好几位时只取第一位，接口拿整串去做「包含」匹配会落空；
    /// 「未知歌手」「群星」这类写法不算歌手。
    public static func searchArtistName(_ artist: String?) -> String? {
        guard let artist else { return nil }
        return ExternalTrackMatchPolicy.artistNames(artist).first {
            !ExternalTrackMatchPolicy.artistTokens($0).isEmpty
        }
    }

    private static func url(path: String, items: [URLQueryItem]) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = items
        // URLQueryItem 不编码 `+`，服务端会把它当空格（「A+B」这类歌名就搜不到）。
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    // MARK: - Responses

    public static func decodeSearch(_ data: Data) throws -> [SongItem] {
        try JSONDecoder().decode(SearchEnvelope.self, from: data).data.items
    }

    public static func decodeSong(_ data: Data) throws -> SongItem {
        try JSONDecoder().decode(GetEnvelope.self, from: data).data
    }

    // MARK: - Matching

    /// 搜索结果里可能是这首歌的几份，按可信度从高到低。
    ///
    /// 歌名（任一别名）的主体和版本标记（现场、伴奏、混音…）都要一致，规则与歌单导入对歌共用
    /// `ExternalTrackMatchPolicy`。知道歌手时歌手要有交集；不知道歌手时，只有对上歌名的几份
    /// 全是同一组歌手才算数 —— 同名的不同歌宁可不给，也不给错。
    public static func rankedCandidates(for query: Query, in items: [SongItem]) -> [SongItem] {
        let (queryCore, queryMarkers) = ExternalTrackMatchPolicy.splitTitle(query.title)
        guard !queryCore.isEmpty else { return [] }
        let queryArtists = Set(query.artist.map(ExternalTrackMatchPolicy.artistTokens) ?? [])
        let queryAlbum = query.album.map(ExternalTrackMatchPolicy.normalize) ?? ""

        struct Scored {
            let item: SongItem
            let artists: Set<String>
            let albumMatches: Bool
            let sharedArtists: Int
            let order: Int
        }

        var scored: [Scored] = []
        for (order, item) in items.enumerated() {
            let titleMatches = item.musicNames.contains { name in
                let (core, markers) = ExternalTrackMatchPolicy.splitTitle(name)
                return core == queryCore && markers == queryMarkers
            }
            guard titleMatches else { continue }
            let artists = Set(item.artistNames.flatMap(ExternalTrackMatchPolicy.artistTokens))
            let shared = queryArtists.intersection(artists).count
            if !queryArtists.isEmpty, shared == 0 { continue }
            let albumMatches = !queryAlbum.isEmpty && item.albumNames.contains {
                ExternalTrackMatchPolicy.normalize($0) == queryAlbum
            }
            scored.append(Scored(
                item: item, artists: artists, albumMatches: albumMatches,
                sharedArtists: shared, order: order
            ))
        }

        if queryArtists.isEmpty {
            let artistGroups = Set(scored.map(\.artists))
            guard artistGroups.count == 1, artistGroups.first?.isEmpty == false else { return [] }
        }

        // 同专辑优先，其次歌手重合多的，再按接口给的顺序（相关度、收录时间）。
        scored.sort { lhs, rhs in
            if lhs.albumMatches != rhs.albumMatches { return lhs.albumMatches }
            if lhs.sharedArtists != rhs.sharedArtists { return lhs.sharedArtists > rhs.sharedArtists }
            return lhs.order < rhs.order
        }
        return scored.map(\.item)
    }

    /// 拿到歌词以后再核对一次时长：最后一句比歌曲还晚，说明是更长的版本；唱不到四成，
    /// 多半是短版。不知道歌曲时长时，只在歌手对上过的情况下放行。
    public static func lyricsFit(
        lastLyricEnd: TimeInterval?,
        songDuration: TimeInterval?,
        artistKnown: Bool
    ) -> Bool {
        guard let lastLyricEnd, lastLyricEnd.isFinite, lastLyricEnd > 0 else { return false }
        guard let songDuration, songDuration.isFinite, songDuration > 0 else { return artistKnown }
        if lastLyricEnd > songDuration + lyricsOverrunTolerance { return false }
        return lastLyricEnd >= songDuration * minimumLyricsCoverage
    }

    /// 查询里的歌手能不能拿来比对（全是「未知歌手」「群星」一类写法时等于没有）。
    public static func hasComparableArtist(_ query: Query) -> Bool {
        guard let artist = query.artist else { return false }
        return !ExternalTrackMatchPolicy.artistTokens(artist).isEmpty
    }
}

import Foundation

/// 专辑、歌手的简介从维基百科取:MusicBrainz 按名字对上条目 → 它的 Wikidata 链接 →
/// 维基百科对应语言的摘要。三家都是公开接口;MusicBrainz、Wikidata 的数据不限制使用,
/// 维基百科正文是 CC BY-SA,所以拿来的简介要一直带着「来自维基百科」和条目链接,
/// 并且不写进文件标签、不写回音乐源(那里带不上来源)。
public enum WikipediaInsightPolicy {
    /// MusicBrainz、维基媒体都要求请求带上能认出应用并联系到维护者的标识。
    public static let userAgent = "Primuse/1.0 (https://github.com/chenqi92/primuse)"
    /// MusicBrainz 要求平均每秒不超过一次,留一点余量。
    public static let musicBrainzSpacing: TimeInterval = 1.1
    /// 记在简介上的来源名。带着许可名,界面上「来源」一行就是署名。
    public static let sourceLabel = "Wikipedia (CC BY-SA 4.0)"

    public struct Candidate: Equatable, Sendable {
        public let id: String
        public let name: String
        public let artist: String

        public init(id: String, name: String, artist: String = "") {
            self.id = id
            self.name = name
            self.artist = artist
        }
    }

    // MARK: - MusicBrainz

    public static func artistSearchURL(name: String) -> URL? {
        musicBrainzSearchURL(entity: "artist", query: clause("artist", name))
    }

    public static func releaseGroupSearchURL(title: String, artist: String) -> URL? {
        musicBrainzSearchURL(
            entity: "release-group",
            query: clause("releasegroup", title) + " AND " + clause("artist", artist)
        )
    }

    public static func relationsURL(entity: String, id: String) -> URL? {
        guard id.range(of: #"^[0-9a-fA-F-]{36}$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: "https://musicbrainz.org/ws/2/\(entity)/\(id)?inc=url-rels&fmt=json")
    }

    private static func musicBrainzSearchURL(entity: String, query: String) -> URL? {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/\(entity)/")
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        return components?.url
    }

    /// Lucene 字段短语;引号和反斜杠转义,名字里的其他符号留在短语里。
    private static func clause(_ field: String, _ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\(field):\"\(escaped)\""
    }

    public static func artistCandidates(fromSearch data: Data) -> [Candidate] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let artists = root["artists"] as? [[String: Any]] else { return [] }
        return artists.compactMap { item in
            guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
            return Candidate(id: id, name: name)
        }
    }

    public static func releaseGroupCandidates(fromSearch data: Data) -> [Candidate] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = root["release-groups"] as? [[String: Any]] else { return [] }
        return groups.compactMap { item in
            guard let id = item["id"] as? String, let title = item["title"] as? String else { return nil }
            let credits = (item["artist-credit"] as? [[String: Any]] ?? []).map { credit in
                (credit["name"] as? String ?? "") + (credit["joinphrase"] as? String ?? "")
            }
            return Candidate(id: id, name: title, artist: credits.joined())
        }
    }

    /// 只认名字完全一样且只有一位的歌手;同名的好几位分不清是谁,宁可不取。
    public static func uniqueArtistID(name: String, in candidates: [Candidate]) -> String? {
        AppleMusicCatalogContinuationPolicy.uniqueArtistMatchIndex(name: name, in: candidates.map(\.name))
            .map { candidates[$0].id }
    }

    /// 专辑名和歌手都对上、且只有一张。
    public static func uniqueReleaseGroupID(title: String, artist: String, in candidates: [Candidate]) -> String? {
        AppleMusicCatalogContinuationPolicy.uniqueAlbumMatchIndex(
            title: title, artist: artist,
            in: candidates.map { .init(id: $0.id, title: $0.name, artist: $0.artist) }
        ).map { candidates[$0].id }
    }

    /// 条目外链里的 Wikidata 编号(Q 开头)。
    public static func wikidataID(fromRelations data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let relations = root["relations"] as? [[String: Any]] else { return nil }
        for relation in relations where (relation["type"] as? String) == "wikidata" {
            guard (relation["ended"] as? Bool) != true,
                  let resource = (relation["url"] as? [String: Any])?["resource"] as? String,
                  let url = URL(string: resource),
                  url.host?.lowercased() == "www.wikidata.org" else { continue }
            let id = url.lastPathComponent
            if id.range(of: #"^Q[0-9]+$"#, options: .regularExpression) != nil { return id }
        }
        return nil
    }

    // MARK: - Wikidata

    public static func sitelinksURL(wikidataID: String) -> URL? {
        guard wikidataID.range(of: #"^Q[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        var components = URLComponents(string: "https://www.wikidata.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "wbgetentities"),
            URLQueryItem(name: "ids", value: wikidataID),
            URLQueryItem(name: "props", value: "sitelinks"),
            URLQueryItem(name: "format", value: "json"),
        ]
        return components?.url
    }

    public struct Article: Equatable, Sendable {
        /// 维基百科的语言子域名,如 zh、en。
        public let site: String
        public let title: String
        /// 中文按界面是简体还是繁体转换,其他语言为空。
        public let variant: String?
    }

    /// 先用界面语言的条目,没有就用英文。
    public static func article(fromSitelinks data: Data, wikidataID: String, languageCode: String) -> Article? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entity = (root["entities"] as? [String: Any])?[wikidataID] as? [String: Any],
              let sitelinks = entity["sitelinks"] as? [String: Any] else { return nil }
        let preferred = site(forLanguageCode: languageCode)
        for candidate in [preferred, (site: "en", variant: String?.none)] {
            guard let link = sitelinks[candidate.site.replacingOccurrences(of: "-", with: "_") + "wiki"] as? [String: Any],
                  let title = link["title"] as? String, !title.isEmpty else { continue }
            return Article(site: candidate.site, title: title, variant: candidate.variant)
        }
        return nil
    }

    static func site(forLanguageCode code: String) -> (site: String, variant: String?) {
        let lower = code.lowercased()
        if lower.hasPrefix("zh") {
            let traditional = lower.contains("hant") || lower.hasSuffix("-tw") || lower.hasSuffix("-hk")
            return ("zh", traditional ? "zh-TW" : "zh-CN")
        }
        let base = lower.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? "en"
        return (base.isEmpty ? "en" : base, nil)
    }

    // MARK: - Wikipedia

    public static func summaryURL(for article: Article) -> URL? {
        guard article.site.range(of: #"^[a-z]{2,3}(-[a-z]+)?$"#, options: .regularExpression) != nil else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        guard let title = article.title.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://\(article.site).wikipedia.org/api/rest_v1/page/summary/\(title)")
    }

    public struct Summary: Equatable, Sendable {
        public let text: String
        public let pageURL: URL
    }

    /// 只要正常条目的摘要;消歧义页、没有正文、链接不在维基百科上的都不要。
    public static func summary(fromResponse data: Data) -> Summary? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["type"] as? String ?? "standard") == "standard",
              let extract = (root["extract"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !extract.isEmpty,
              let page = ((root["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"] as? String,
              let url = URL(string: page), url.scheme == "https",
              url.host?.lowercased().hasSuffix(".wikipedia.org") == true else { return nil }
        return Summary(text: extract, pageURL: url)
    }
}

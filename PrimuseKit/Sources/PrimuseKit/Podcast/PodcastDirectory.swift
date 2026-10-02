import Foundation

/// Apple 播客目录里的一档节目(搜索、榜单、按 id 查)。
public struct PodcastDirectoryShow: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var title: String
    public var author: String?
    public var artworkURL: URL?
    /// 搜索和按 id 查有,榜单没有 —— 要订阅时再按 id 查一次。
    public var feedURL: URL?
    public var genre: String?
    public var episodeCount: Int?
    public var latestReleaseAt: Date?
    public var summary: String?

    public init(
        id: Int,
        title: String,
        author: String? = nil,
        artworkURL: URL? = nil,
        feedURL: URL? = nil,
        genre: String? = nil,
        episodeCount: Int? = nil,
        latestReleaseAt: Date? = nil,
        summary: String? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.artworkURL = artworkURL
        self.feedURL = feedURL
        self.genre = genre
        self.episodeCount = episodeCount
        self.latestReleaseAt = latestReleaseAt
        self.summary = summary
    }
}

public enum PodcastDirectoryError: Error, Equatable, Sendable {
    case badResponse
}

/// Apple 播客目录的请求与解码。只发用户输入的搜索词和地区码,不带任何本机数据。
///
/// 地区码决定目录按哪个店面过滤:中国大陆店面的结果由 Apple 按当地要求筛过(见 `PodcastAvailabilityPolicy`)。
public enum PodcastDirectory {
    /// 目录的分类(Apple 播客的一级分类 id)。界面上的名字走本地化键 `podcast_genre_<id>`。
    public static let genreIDs: [Int] = [
        1324, 1489, 1303, 1318, 1321, 1304, 1301, 1487, 1533, 1512,
        1502, 1310, 1309, 1545, 1483, 1488, 1305, 1314, 1511,
    ]

    /// feed 里 `<itunes:category>` 和美区目录给的分类名是英文;认得出的一级分类换成 id,界面按本地化键显示。
    /// 收了 Apple 改名前的旧分类名(2019 年那次调整前的 feed 还很多)。
    public static func genreID(forCategory name: String) -> Int? {
        categoryGenreIDs[PodcastText.trimmed(name).lowercased()]
    }

    private static let categoryGenreIDs: [String: Int] = [
        "arts": 1301, "business": 1321, "comedy": 1303, "education": 1304, "fiction": 1483,
        "government": 1511, "history": 1487, "health & fitness": 1512, "kids & family": 1305,
        "leisure": 1502, "music": 1310, "news": 1489, "religion & spirituality": 1314,
        "science": 1533, "society & culture": 1324, "sports": 1545, "technology": 1318,
        "true crime": 1488, "tv & film": 1309,
        "games & hobbies": 1502, "health": 1512, "news & politics": 1489, "science & medicine": 1533,
        "sports & recreation": 1545, "government & organizations": 1511, "religion": 1314, "spirituality": 1314,
    ]

    public static func searchURL(term: String, country: String, limit: Int = 30) -> URL? {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: "podcast"),
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 200)))),
        ]
        return components.url
    }

    public static func lookupURL(ids: [Int], country: String) -> URL? {
        var seen = Set<Int>()
        let unique = ids.filter { $0 > 0 && seen.insert($0).inserted }
        guard !unique.isEmpty else { return nil }
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "id", value: unique.map(String.init).joined(separator: ",")),
            URLQueryItem(name: "entity", value: "podcast"),
            URLQueryItem(name: "country", value: country),
        ]
        return components.url
    }

    /// 热门节目榜,`genreID` 为 nil 时是总榜。
    public static func chartURL(country: String, genreID: Int? = nil, limit: Int = 50) -> URL? {
        let clamped = max(1, min(limit, 200))
        var path = "https://itunes.apple.com/\(country)/rss/toppodcasts/limit=\(clamped)"
        if let genreID { path += "/genre=\(genreID)" }
        return URL(string: path + "/json")
    }

    // MARK: - Decoding

    private struct SearchPayload: Decodable {
        struct Item: Decodable {
            let kind: String?
            let collectionId: Int?
            let trackId: Int?
            let collectionName: String?
            let trackName: String?
            let artistName: String?
            let feedUrl: String?
            let artworkUrl600: String?
            let artworkUrl100: String?
            let primaryGenreName: String?
            let trackCount: Int?
            let releaseDate: String?
        }
        let results: [Item]?
    }

    public static func decodeSearch(_ data: Data) throws -> [PodcastDirectoryShow] {
        guard let payload = try? JSONDecoder().decode(SearchPayload.self, from: data) else {
            throw PodcastDirectoryError.badResponse
        }
        var seen = Set<Int>()
        return (payload.results ?? []).compactMap { item in
            guard item.kind == nil || item.kind == "podcast",
                  let id = item.collectionId ?? item.trackId, seen.insert(id).inserted,
                  let title = (item.collectionName ?? item.trackName)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { return nil }
            return PodcastDirectoryShow(
                id: id,
                title: title,
                author: item.artistName?.trimmingCharacters(in: .whitespacesAndNewlines),
                artworkURL: (item.artworkUrl600 ?? item.artworkUrl100).flatMap(URL.init(string:)),
                feedURL: item.feedUrl.flatMap { PodcastFeedURL.normalized($0) },
                genre: item.primaryGenreName,
                episodeCount: item.trackCount,
                latestReleaseAt: item.releaseDate.flatMap { PodcastFeedParser.date(from: $0) }
            )
        }
    }

    private struct ChartPayload: Decodable {
        struct Label: Decodable { let label: String? }
        struct Image: Decodable {
            let label: String?
            let attributes: [String: String]?
        }
        struct Identifier: Decodable {
            let attributes: [String: String]?
        }
        struct Category: Decodable {
            let attributes: [String: String]?
        }
        struct Entry: Decodable {
            let name: Label?
            let artist: Label?
            let image: [Image]?
            let id: Identifier?
            let summary: Label?
            let category: Category?

            enum CodingKeys: String, CodingKey {
                case name = "im:name"
                case artist = "im:artist"
                case image = "im:image"
                case id, summary, category
            }
        }
        struct Feed: Decodable {
            let entry: [Entry]?

            enum CodingKeys: String, CodingKey { case entry }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                // 只有一条时 entry 是对象不是数组。
                if let list = try? container.decode([Entry].self, forKey: .entry) {
                    entry = list
                } else if let single = try? container.decode(Entry.self, forKey: .entry) {
                    entry = [single]
                } else {
                    entry = nil
                }
            }
        }
        let feed: Feed?
    }

    public static func decodeChart(_ data: Data) throws -> [PodcastDirectoryShow] {
        guard let payload = try? JSONDecoder().decode(ChartPayload.self, from: data) else {
            throw PodcastDirectoryError.badResponse
        }
        var seen = Set<Int>()
        return (payload.feed?.entry ?? []).compactMap { entry in
            guard let raw = entry.id?.attributes?["im:id"], let id = Int(raw), seen.insert(id).inserted,
                  let title = entry.name?.label?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
            let image = entry.image?.max { lhs, rhs in
                (Int(lhs.attributes?["height"] ?? "") ?? 0) < (Int(rhs.attributes?["height"] ?? "") ?? 0)
            }
            return PodcastDirectoryShow(
                id: id,
                title: title,
                author: entry.artist?.label,
                artworkURL: image?.label.flatMap { upscaledArtwork($0) },
                genre: entry.category?.attributes?["label"],
                summary: entry.summary?.label
            )
        }
    }

    /// 目录图片地址里的尺寸段(`/170x170bb.png`)换成 600,榜单只给小图。
    public static func upscaledArtwork(_ raw: String, size: Int = 600) -> URL? {
        let replaced = raw.replacingOccurrences(
            of: "/\\d+x\\d+(bb)?\\.(png|jpg|jpeg|webp)$",
            with: "/\(size)x\(size)bb.$2",
            options: .regularExpression
        )
        return URL(string: replaced)
    }

    // MARK: - Country

    /// 目录接口要两位地区码;StoreKit 给的是三位。认不出时退回 `fallback`。
    public static func directoryCountry(storefrontCode: String?, fallback: String = "us") -> String {
        guard let code = storefrontCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !code.isEmpty else {
            return fallback
        }
        if code.count == 2, code.allSatisfy(\.isLetter) { return code.lowercased() }
        if code.count == 3, let alpha2 = alpha3ToAlpha2[code] { return alpha2.lowercased() }
        return fallback
    }

    /// App Store 店面覆盖的国家和地区(ISO 3166-1 三位 → 两位)。
    static let alpha3ToAlpha2: [String: String] = [
        "AFG": "AF", "ALB": "AL", "DZA": "DZ", "AGO": "AO", "AIA": "AI", "ATG": "AG", "ARG": "AR", "ARM": "AM",
        "AUS": "AU", "AUT": "AT", "AZE": "AZ", "BHS": "BS", "BHR": "BH", "BRB": "BB", "BLR": "BY", "BEL": "BE",
        "BLZ": "BZ", "BEN": "BJ", "BMU": "BM", "BTN": "BT", "BOL": "BO", "BIH": "BA", "BWA": "BW", "BRA": "BR",
        "VGB": "VG", "BRN": "BN", "BGR": "BG", "BFA": "BF", "KHM": "KH", "CMR": "CM", "CAN": "CA", "CPV": "CV",
        "CYM": "KY", "TCD": "TD", "CHL": "CL", "CHN": "CN", "COL": "CO", "COD": "CD", "COG": "CG", "CRI": "CR",
        "CIV": "CI", "HRV": "HR", "CYP": "CY", "CZE": "CZ", "DNK": "DK", "DMA": "DM", "DOM": "DO", "ECU": "EC",
        "EGY": "EG", "SLV": "SV", "EST": "EE", "SWZ": "SZ", "FJI": "FJ", "FIN": "FI", "FRA": "FR", "GAB": "GA",
        "GMB": "GM", "GEO": "GE", "DEU": "DE", "GHA": "GH", "GRC": "GR", "GRD": "GD", "GTM": "GT", "GNB": "GW",
        "GUY": "GY", "HND": "HN", "HKG": "HK", "HUN": "HU", "ISL": "IS", "IND": "IN", "IDN": "ID", "IRQ": "IQ",
        "IRL": "IE", "ISR": "IL", "ITA": "IT", "JAM": "JM", "JPN": "JP", "JOR": "JO", "KAZ": "KZ", "KEN": "KE",
        "KOR": "KR", "XKX": "XK", "KWT": "KW", "KGZ": "KG", "LAO": "LA", "LVA": "LV", "LBN": "LB", "LBR": "LR",
        "LBY": "LY", "LTU": "LT", "LUX": "LU", "MAC": "MO", "MDG": "MG", "MWI": "MW", "MYS": "MY", "MDV": "MV",
        "MLI": "ML", "MLT": "MT", "MRT": "MR", "MUS": "MU", "MEX": "MX", "FSM": "FM", "MDA": "MD", "MNG": "MN",
        "MNE": "ME", "MSR": "MS", "MAR": "MA", "MOZ": "MZ", "MMR": "MM", "NAM": "NA", "NRU": "NR", "NPL": "NP",
        "NLD": "NL", "NZL": "NZ", "NIC": "NI", "NER": "NE", "NGA": "NG", "MKD": "MK", "NOR": "NO", "OMN": "OM",
        "PAK": "PK", "PLW": "PW", "PAN": "PA", "PNG": "PG", "PRY": "PY", "PER": "PE", "PHL": "PH", "POL": "PL",
        "PRT": "PT", "QAT": "QA", "ROU": "RO", "RUS": "RU", "RWA": "RW", "KNA": "KN", "LCA": "LC", "VCT": "VC",
        "STP": "ST", "SAU": "SA", "SEN": "SN", "SRB": "RS", "SYC": "SC", "SLE": "SL", "SGP": "SG", "SVK": "SK",
        "SVN": "SI", "SLB": "SB", "ZAF": "ZA", "ESP": "ES", "LKA": "LK", "SUR": "SR", "SWE": "SE", "CHE": "CH",
        "TWN": "TW", "TJK": "TJ", "TZA": "TZ", "THA": "TH", "TON": "TO", "TTO": "TT", "TUN": "TN", "TUR": "TR",
        "TKM": "TM", "TCA": "TC", "UGA": "UG", "UKR": "UA", "ARE": "AE", "GBR": "GB", "USA": "US", "URY": "UY",
        "UZB": "UZ", "VUT": "VU", "VEN": "VE", "VNM": "VN", "YEM": "YE", "ZMB": "ZM", "ZWE": "ZW",
    ]
}

/// 播客能用到哪一步,按 App Store 店面决定。
///
/// 中国大陆店面:只能从 Apple 播客目录(按中国店面筛过)里搜索订阅,不提供手填 RSS 地址和 OPML 导入 ——
/// 能订阅任意 RSS 等于绕过内容审核,2020 年 Pocket Casts、Castro 因此被下架。其他店面全部开放。
/// 店面还没取到时按受限处理:地区判不出来时宁可少给一个入口。
public struct PodcastAvailabilityPolicy: Equatable, Sendable {
    public var allowsCustomFeeds: Bool
    public var directoryCountry: String

    public init(allowsCustomFeeds: Bool, directoryCountry: String) {
        self.allowsCustomFeeds = allowsCustomFeeds
        self.directoryCountry = directoryCountry
    }

    public static func resolve(storefrontCountryCode: String?, localeRegionCode: String?) -> Self {
        let context = AIRegionResolver.resolve(
            storefrontCountryCode: storefrontCountryCode,
            localeRegionCode: localeRegionCode
        )
        let country: String
        switch context.region {
        case .mainlandChina:
            country = "cn"
        case .international:
            country = PodcastDirectory.directoryCountry(storefrontCode: context.countryCode)
        case .unknown:
            country = PodcastDirectory.directoryCountry(storefrontCode: localeRegionCode)
        }
        return PodcastAvailabilityPolicy(
            allowsCustomFeeds: context.region == .international,
            directoryCountry: country
        )
    }

    /// 店面还没取到时的保守值。
    public static let restricted = PodcastAvailabilityPolicy(allowsCustomFeeds: false, directoryCountry: "us")
}

import Foundation

/// Configuration for a user-importable scraper source.
/// Describes API endpoints, request format, and JavaScript parsing scripts.
struct ScraperConfig: Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let version: Int
    var icon: String?
    var color: String?
    var rateLimit: Int?  // milliseconds between requests
    var headers: [String: String]?
    var capabilities: [String]  // "metadata", "cover", "lyrics"
    var sslTrustDomains: [String]?  // domains to bypass SSL validation
    var cookie: String?

    var search: EndpointConfig?
    var detail: EndpointConfig?
    var cover: EndpointConfig?
    var lyrics: EndpointConfig?
    var lyricsFallback: LyricsFallbackConfig?
    var responseValidation: ScraperResponseValidation?

    /// 用户本地的敏感配置（XOR key、加密 magic、二次请求 URL 模板等）。
    /// **decode 时**接受（允许跟主 JSON 一起导入），**encode 时不输出**——
    /// 所以不会被写回公开 JSON、不进 CloudKit 同步、不进任何仓库。
    /// 持久化到磁盘走 ConfigStore 的旁路文件 `<id>.secrets.json`。
    var secrets: [String: String]?

    /// Wall-clock time of last user mutation. Drives CloudKit conflict
    /// resolution; absent when the value comes from a freshly-imported JSON.
    var modifiedAt: Date?
    /// Soft-delete flag. Hidden from the regular UI but kept on disk +
    /// CloudKit until the 30-day prune sweeps it.
    var isDeleted: Bool?
    var deletedAt: Date?

    var supportsMetadata: Bool { capabilities.contains("metadata") }
    var supportsCover: Bool { capabilities.contains("cover") }
    var supportsLyrics: Bool { capabilities.contains("lyrics") }
    /// 在 capabilities 里声明 "lyricsWordLevel" 即视为支持逐字歌词
    var supportsWordLevelLyrics: Bool { capabilities.contains("lyricsWordLevel") }
    var supportsCookie: Bool { cookie != nil || headers?.keys.contains("Cookie") == true }

    init(
        id: String,
        name: String,
        version: Int,
        icon: String? = nil,
        color: String? = nil,
        rateLimit: Int? = nil,
        headers: [String: String]? = nil,
        capabilities: [String],
        sslTrustDomains: [String]? = nil,
        cookie: String? = nil,
        search: EndpointConfig? = nil,
        detail: EndpointConfig? = nil,
        cover: EndpointConfig? = nil,
        lyrics: EndpointConfig? = nil,
        lyricsFallback: LyricsFallbackConfig? = nil,
        responseValidation: ScraperResponseValidation? = nil,
        secrets: [String: String]? = nil,
        modifiedAt: Date? = nil,
        isDeleted: Bool? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.icon = icon
        self.color = color
        self.rateLimit = rateLimit
        self.headers = headers
        self.capabilities = capabilities
        self.sslTrustDomains = sslTrustDomains
        self.cookie = cookie
        self.search = search
        self.detail = detail
        self.cover = cover
        self.lyrics = lyrics
        self.lyricsFallback = lyricsFallback
        self.responseValidation = responseValidation
        self.secrets = secrets
        self.modifiedAt = modifiedAt
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, version, icon, color, rateLimit, headers, capabilities
        case sslTrustDomains, cookie
        case search, detail, cover, lyrics, lyricsFallback, responseValidation
        case secrets
        case modifiedAt, isDeleted, deletedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.version = try c.decode(Int.self, forKey: .version)
        self.icon = try c.decodeIfPresent(String.self, forKey: .icon)
        self.color = try c.decodeIfPresent(String.self, forKey: .color)
        self.rateLimit = try c.decodeIfPresent(Int.self, forKey: .rateLimit)
        self.headers = try c.decodeIfPresent([String: String].self, forKey: .headers)
        self.capabilities = try c.decode([String].self, forKey: .capabilities)
        self.sslTrustDomains = try c.decodeIfPresent([String].self, forKey: .sslTrustDomains)
        self.cookie = try c.decodeIfPresent(String.self, forKey: .cookie)
        self.search = try c.decodeIfPresent(EndpointConfig.self, forKey: .search)
        self.detail = try c.decodeIfPresent(EndpointConfig.self, forKey: .detail)
        self.cover = try c.decodeIfPresent(EndpointConfig.self, forKey: .cover)
        self.lyrics = try c.decodeIfPresent(EndpointConfig.self, forKey: .lyrics)
        self.lyricsFallback = try c.decodeIfPresent(LyricsFallbackConfig.self, forKey: .lyricsFallback)
        self.responseValidation = try c.decodeIfPresent(ScraperResponseValidation.self, forKey: .responseValidation)
        self.secrets = try c.decodeIfPresent([String: String].self, forKey: .secrets)
        self.modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt)
        self.isDeleted = try c.decodeIfPresent(Bool.self, forKey: .isDeleted)
        self.deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
    }

    /// **encode 时不输出 secrets**——保护用户本地敏感配置不外泄。
    /// secrets 的持久化由 ConfigStore 旁路处理。
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(version, forKey: .version)
        try c.encodeIfPresent(icon, forKey: .icon)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encodeIfPresent(rateLimit, forKey: .rateLimit)
        try c.encodeIfPresent(headers, forKey: .headers)
        try c.encode(capabilities, forKey: .capabilities)
        try c.encodeIfPresent(sslTrustDomains, forKey: .sslTrustDomains)
        try c.encodeIfPresent(cookie, forKey: .cookie)
        try c.encodeIfPresent(search, forKey: .search)
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encodeIfPresent(cover, forKey: .cover)
        try c.encodeIfPresent(lyrics, forKey: .lyrics)
        try c.encodeIfPresent(lyricsFallback, forKey: .lyricsFallback)
        try c.encodeIfPresent(responseValidation, forKey: .responseValidation)
        // secrets 故意省略
        try c.encodeIfPresent(modifiedAt, forKey: .modifiedAt)
        try c.encodeIfPresent(isDeleted, forKey: .isDeleted)
        try c.encodeIfPresent(deletedAt, forKey: .deletedAt)
    }
}

struct EndpointConfig: Codable, Sendable {
    let url: String       // URL template with {{var}} placeholders
    let method: String    // "GET" or "POST"
    var params: [String: String]?
    var headers: [String: String]?   // endpoint-specific headers (merged with global)
    var bodyTemplate: String?        // POST body template (for complex JSON bodies)
    let script: String    // JavaScript parsing script
}

/// An optional second GET when encrypted lyric parameters are unavailable.
struct LyricsFallbackConfig: Codable, Sendable {
    enum ContentEncoding: String, Codable, Sendable {
        case base64UTF8, utf8
    }
    let url: String
    let contentField: String
    let encoding: ContentEncoding
    var requiredVariables: [String] = []

    init(url: String, contentField: String, encoding: ContentEncoding, requiredVariables: [String] = []) {
        self.url = url
        self.contentField = contentField
        self.encoding = encoding
        self.requiredVariables = requiredVariables
    }

    private enum CodingKeys: String, CodingKey { case url, contentField, encoding, requiredVariables }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        contentField = try c.decode(String.self, forKey: .contentField)
        encoding = try c.decode(ContentEncoding.self, forKey: .encoding)
        requiredVariables = try c.decodeIfPresent([String].self, forKey: .requiredVariables) ?? []
    }
}

/// Numeric business status fields; missing fields remain optional for heterogeneous responses.
struct ScraperResponseValidation: Codable, Sendable {
    /// Dot-separated JSON paths. A trailing * in a component selects keys by prefix.
    let codePaths: [String]
    let successCodes: [Int]

    func firstFailure(in data: Data) -> Int? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        for path in codePaths {
            var values: [Any] = [json]
            for component in path.split(separator: ".") {
                values = values.flatMap { value -> [Any] in
                    guard let object = value as? [String: Any] else { return [] }
                    if component.hasSuffix("*") {
                        let prefix = String(component.dropLast())
                        return object.keys.sorted().filter { $0.hasPrefix(prefix) }.compactMap { object[$0] }
                    }
                    return object[String(component)].map { [$0] } ?? []
                }
            }
            if let code = values.compactMap({ $0 as? Int }).first(where: { !successCodes.contains($0) }) {
                return code
            }
        }
        return nil
    }
}

/// Preserve manifests imported before explicit fallback/validation fields existed.
/// Resolve at runtime so user files, versions, secrets and CloudKit timestamps stay intact.
enum LegacyScraperCompatibility {
    static func lyricsFallback(for config: ScraperConfig) -> LyricsFallbackConfig? {
        if let configured = config.lyricsFallback { return configured }
        guard config.id == "kugou" else { return nil }
        return LyricsFallbackConfig(
            url: "https://lyrics.kugou.com/download?ver=1&client=pc&id={{id}}&accesskey={{accesskey}}&fmt=lrc&charset=utf8",
            contentField: "content", encoding: .base64UTF8, requiredVariables: ["id", "accesskey"]
        )
    }

    static func responseValidation(for config: ScraperConfig, url: URL?) -> ScraperResponseValidation? {
        if let configured = config.responseValidation { return configured }
        guard config.id == "qqmusic" || url?.host?.lowercased() == "u.y.qq.com" else { return nil }
        return ScraperResponseValidation(codePaths: ["code", "req*.code"], successCodes: [0])
    }
}

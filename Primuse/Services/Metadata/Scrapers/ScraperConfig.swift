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
        self.secrets = secrets
        self.modifiedAt = modifiedAt
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, version, icon, color, rateLimit, headers, capabilities
        case sslTrustDomains, cookie
        case search, detail, cover, lyrics
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

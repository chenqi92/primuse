import Foundation
import CryptoKit
import PrimuseKit

/// Configuration for a user-importable scraper source.
/// Describes API endpoints, request format, and fixed response rules.
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
    var dynamicCover: EndpointConfig?
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
        dynamicCover: EndpointConfig? = nil,
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
        self.dynamicCover = dynamicCover
        self.lyrics = lyrics
        self.lyricsFallback = lyricsFallback
        self.responseValidation = responseValidation
        self.secrets = secrets
        self.modifiedAt = modifiedAt
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
    }


    /// 默认配置与导入配置共用协议，移出此列表后仍可通过 JSON 导入。
    static let builtInConfigs: [ScraperConfig] = {
        let json = #"""
        [{
            "id": "m8tec",
            "name": "m8tec",
            "version": 1,
            "capabilities": [
                "dynamicCover"
            ],
            "dynamicCover": {
                "url": "https://artwork.m8tec.top/api/v1/artwork/search",
                "method": "GET",
                "params": {
                    "artist": "{{artist}}",
                    "album": "{{album}}"
                },
                "assetHosts": [
                    "*.itunes.apple.com",
                    "*.mzstatic.com"
                ],
                "rule": {"format": "motionArtwork"},
                "playlist": "boundedHLS"
            },
            "icon": "photo.badge.arrow.down",
            "color": "#8866DD",
            "rateLimit": 1000
        }]
        """#
        return try! JSONDecoder().decode([ScraperConfig].self, from: Data(json.utf8))
    }()

    private enum CodingKeys: String, CodingKey {
        case id, name, version, icon, color, rateLimit, headers, capabilities
        case sslTrustDomains, cookie
        case search, detail, cover, dynamicCover, lyrics, lyricsFallback, responseValidation
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
        self.dynamicCover = try c.decodeIfPresent(EndpointConfig.self, forKey: .dynamicCover)
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
        try c.encodeIfPresent(dynamicCover, forKey: .dynamicCover)
        try c.encodeIfPresent(lyrics, forKey: .lyrics)
        try c.encodeIfPresent(lyricsFallback, forKey: .lyricsFallback)
        try c.encodeIfPresent(responseValidation, forKey: .responseValidation)
        // secrets 故意省略
        try c.encodeIfPresent(modifiedAt, forKey: .modifiedAt)
        try c.encodeIfPresent(isDeleted, forKey: .isDeleted)
        try c.encodeIfPresent(deletedAt, forKey: .deletedAt)
    }
}

enum ScraperNetworkScope {
    static func endpoints(_ config: ScraperConfig) -> [String: EndpointConfig] {
        ["search": config.search, "detail": config.detail, "cover": config.cover,
         "lyrics": config.lyrics, "dynamicCover": config.dynamicCover].compactMapValues { $0 }
    }
    static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty, !host.contains("{"), !host.contains("%"),
              url.user == nil, url.password == nil else { return nil }
        return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }
    static func origin(template: String, trustDomains: [String]) -> String? {
        URL(string: ConfigurableScraper.enforceHTTPPolicy(template, trustDomains: trustDomains)).flatMap(origin)
    }
    static func credentialOrigins(_ config: ScraperConfig) -> Set<String> {
        let urls = endpoints(config).values.filter { $0.method.uppercased() != "LOCAL" }.map(\.url)
        return Set(urls.compactMap { origin(template: $0, trustDomains: config.sslTrustDomains ?? []) })
    }
    static func permitsAutomaticUpdate(from current: ScraperConfig, to incoming: ScraperConfig) -> Bool {
        guard Set(incoming.capabilities).isSubset(of: Set(current.capabilities)),
              Set((incoming.sslTrustDomains ?? []).map { $0.lowercased() }).isSubset(of: Set((current.sslTrustDomains ?? []).map { $0.lowercased() })) else { return false }
        let old = endpoints(current)
        for (name, endpoint) in endpoints(incoming) {
            guard let previous = old[name], !endpoint.hasLegacyCode,
                  endpoint.method.uppercased() == previous.method.uppercased(),
                  Set((endpoint.assetHosts ?? []).map { $0.lowercased() }).isSubset(of: Set((previous.assetHosts ?? []).map { $0.lowercased() })) else { return false }
            if endpoint.method.uppercased() != "LOCAL" {
                guard let before = origin(template: previous.url, trustDomains: current.sslTrustDomains ?? []),
                      before == origin(template: endpoint.url, trustDomains: incoming.sslTrustDomains ?? []) else { return false }
            }
        }
        let oldFallback = LegacyScraperCompatibility.lyricsFallback(for: current)
        if let fallback = LegacyScraperCompatibility.lyricsFallback(for: incoming) {
            guard let oldFallback,
                  let before = origin(template: oldFallback.url, trustDomains: current.sslTrustDomains ?? []),
                  before == origin(template: fallback.url, trustDomains: incoming.sslTrustDomains ?? []) else { return false }
        }
        return true
    }
    static func isPublicHeader(_ name: String) -> Bool {
        ["user-agent", "accept", "accept-language", "accept-encoding", "content-type"].contains(name.lowercased())
    }
}

struct EndpointConfig: Codable, Sendable {
    let url: String
    var method: String
    var params: [String: String]?
    var headers: [String: String]?
    var bodyTemplate: String?
    // Retained only to preserve unsupported legacy configurations for editing/export.
    var script: String
    var optional: Bool?
    var requiredIdSegments: [Int]?
    var sign: [String: String]?
    var crypto: [String: String]?
    var requestScript: String?
    var responseScript: String?
    var playlistScript: String?
    var assetHosts: [String]?
    var rule: ScraperJSONRule?
    var responsePath: String?
    var playlist: String?

    init(url: String, method: String, params: [String: String]? = nil, headers: [String: String]? = nil,
         bodyTemplate: String? = nil, script: String = "", optional: Bool? = nil, requiredIdSegments: [Int]? = nil,
         sign: [String: String]? = nil, crypto: [String: String]? = nil, requestScript: String? = nil,
         responseScript: String? = nil, playlistScript: String? = nil, assetHosts: [String]? = nil,
         rule: ScraperJSONRule? = nil, responsePath: String? = nil, playlist: String? = nil) {
        self.url = url; self.method = method; self.params = params; self.headers = headers
        self.bodyTemplate = bodyTemplate; self.script = script; self.optional = optional
        self.requiredIdSegments = requiredIdSegments; self.sign = sign; self.crypto = crypto
        self.requestScript = requestScript; self.responseScript = responseScript; self.playlistScript = playlistScript
        self.assetHosts = assetHosts; self.rule = rule; self.responsePath = responsePath; self.playlist = playlist
        migrateLegacyRule()
    }
    private enum CodingKeys: String, CodingKey {
        case url, method, params, headers, bodyTemplate, script, optional, requiredIdSegments, sign, crypto
        case requestScript, responseScript, playlistScript, assetHosts, rule, responsePath, playlist
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url); method = try c.decode(String.self, forKey: .method)
        params = try c.decodeIfPresent([String: String].self, forKey: .params)
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers)
        bodyTemplate = try c.decodeIfPresent(String.self, forKey: .bodyTemplate)
        script = try c.decodeIfPresent(String.self, forKey: .script) ?? ""
        optional = try c.decodeIfPresent(Bool.self, forKey: .optional)
        requiredIdSegments = try c.decodeIfPresent([Int].self, forKey: .requiredIdSegments)
        sign = try c.decodeIfPresent([String: String].self, forKey: .sign)
        crypto = try c.decodeIfPresent([String: String].self, forKey: .crypto)
        requestScript = try c.decodeIfPresent(String.self, forKey: .requestScript)
        responseScript = try c.decodeIfPresent(String.self, forKey: .responseScript)
        playlistScript = try c.decodeIfPresent(String.self, forKey: .playlistScript)
        assetHosts = try c.decodeIfPresent([String].self, forKey: .assetHosts)
        rule = try c.decodeIfPresent(ScraperJSONRule.self, forKey: .rule)
        responsePath = try c.decodeIfPresent(String.self, forKey: .responsePath)
        playlist = try c.decodeIfPresent(String.self, forKey: .playlist)
        migrateLegacyRule()
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(url, forKey: .url); try c.encode(method, forKey: .method)
        try c.encodeIfPresent(params, forKey: .params); try c.encodeIfPresent(headers, forKey: .headers)
        try c.encodeIfPresent(bodyTemplate, forKey: .bodyTemplate)
        if !script.isEmpty { try c.encode(script, forKey: .script) }
        try c.encodeIfPresent(optional, forKey: .optional); try c.encodeIfPresent(requiredIdSegments, forKey: .requiredIdSegments)
        try c.encodeIfPresent(sign, forKey: .sign); try c.encodeIfPresent(crypto, forKey: .crypto)
        try c.encodeIfPresent(requestScript, forKey: .requestScript); try c.encodeIfPresent(responseScript, forKey: .responseScript)
        try c.encodeIfPresent(playlistScript, forKey: .playlistScript); try c.encodeIfPresent(assetHosts, forKey: .assetHosts)
        try c.encodeIfPresent(rule, forKey: .rule); try c.encodeIfPresent(responsePath, forKey: .responsePath)
        try c.encodeIfPresent(playlist, forKey: .playlist)
    }
    var hasLegacyCode: Bool {
        !script.isEmpty || [requestScript, responseScript, playlistScript].contains { $0?.isEmpty == false }
    }
    func validateRules() throws {
        guard !hasLegacyCode else { throw ScraperConfigError.legacyScriptUnsupported }
        try rule?.validate()
        guard playlist == nil || playlist == "boundedHLS", (responsePath?.count ?? 0) <= 512,
              sign == nil || sign?["type"] == "md5-wrap",
              crypto == nil || crypto?["algorithm"] == "aes-128-ecb" else {
            throw ScraperConfigError.validationFailed("Unsupported data rule")
        }
    }
    private mutating func migrateLegacyRule() {
        if let requestScript {
            let hash = Self.fingerprint(requestScript)
            if hash == "53f8547973f1a3db5a2dba4591155ee252c906850d54d71dca577cd7972d9c94", crypto?["algorithm"] == "aes-128-ecb" {
                self.requestScript = nil
            } else if hash == "b54d47e288f059995c272f7a41398270445dc63117fac1f15c549213faccf997", sign?["type"] == "md5-wrap" {
                self.requestScript = nil
                sign?["deviceIDSecret"] = "requestDeviceID"
            }
        }
        if let responseScript, Self.fingerprint(responseScript) == "43ebc9ef0b7e16676feff49461ac742a43754dc0e85034ff7bfba3f0c0b0e968",
           crypto?["algorithm"] == "aes-128-ecb" {
            self.responseScript = nil
        }
        guard rule == nil else { return }
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "return response;" { rule = .init() }
        else if trimmed == "return [];" { rule = .init(format: .empty) }
        else if ["return null;", "return undefined;"].contains(trimmed) { rule = .init(format: .none) }
        else if let format = Self.legacyFormats[Self.fingerprint(script)] {
            rule = .init(format: format)
        } else if trimmed.range(of: #"^return response(?:\.[A-Za-z_][A-Za-z_0-9]*)+;$"#, options: .regularExpression) != nil {
            rule = .init(path: String(trimmed.dropFirst("return response.".count).dropLast()))
        }
        if var converted = rule, [.envelopeCatalogSearch, .envelopeCatalogDetail, .envelopeCatalogCover, .quotedCatalogSearch].contains(converted.format),
           let match = script.range(of: #"https?://[^\s'"]+"#, options: .regularExpression) {
            converted.artworkBaseURL = String(script[match])
            rule = converted
        }
        if rule != nil { script = "" }
        if let format = rule?.format, [.hashCatalogDetail, .hashCatalogCover, .quotedCatalogDetail, .quotedCatalogCover, .groupedCatalogDetail, .groupedCatalogCover].contains(format) {
            method = "LOCAL"
        }
    }
    private static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // Exact fingerprints prevent an edited or malicious script from being treated as a known adapter.
    private static let legacyFormats: [String: ScraperJSONRule.Format] = [
        "096b2de8e3fb6d2d23e9cde1270c60c4f40b24ae9a8207ac50b831dbb6f51231": .hashCatalogSearch,
        "92492a74e0c4bd0f115d6828a30ba31c2964d774f830d0c4cdd0f9a00da5287c": .hashCatalogMotionArtwork,
        "39e09fceba48e04985e8930380ab9d97f28556e732a4d45c67cb78fc17fc55c9": .albumCatalogMotionArtwork,
        "a0fb70efe3003241ae456466b0a00e00a4d3243cd3b7528a9440716262861f34": .hashCatalogSearch,
        "a81947aad9081b165b54f510dbffd3ea07c905ade5f54bd1bf01c279fb9e6dc3": .hashCatalogDetail,
        "c63031a6c0aeaf61772e1bfdbefba92c8d73551736ed5ae9b93c0a9013d10988": .hashCatalogCover,
        "400ccb30d3f1dd06a13ecf3c1637eea40e9354f743da8724a310c11666f7f71e": .hashCatalogLyrics,
        "54689e4bef5201715a211480e7e53f11ee7e69dbb684b1005a595114ae6f93f7": .quotedCatalogSearch,
        "34146b3d6490fe6d6b8189e6f1b254c4679c8c21b9ec75c9cfd18739a57ca686": .quotedCatalogDetail,
        "25ba87be44dc063b632887a4e4b6932b7ad2c6428073b4bf6e34bce4c75ac790": .quotedCatalogCover,
        "0940895d1347b87084b3d720f14ec09d375433950f4d497d1fb0851de21df345": .quotedCatalogLyrics,
        "145ce693749b89faa44ef9d70a4e7eac9af72927bca37a9d1ecb40517e74e29b": .groupedCatalogSearch,
        "6a0e007ca4bb83f318f3598d1cc701fd9a0c172778a4ab2f4067d80b6294398d": .groupedCatalogDetail,
        "5174568f892d21a6cf07c2f0199f5cd56bfc22ddd36c5e7abe58f5a4497dc764": .groupedCatalogCover,
        "beeb27fb9936f271ac0c57490a0d6b5342b0ed04a2cbfcfff72991ea3156ed07": .albumCatalogSearch,
        "e09b4a9ab1a2dbfccbaddf458375b0aa9ee2fcd097dd2d68acbd689f09625293": .albumCatalogDetail,
        "2cece8a220e219bf622bc4299f243cb003e110f570ebc00e7da52d195b5799ac": .albumCatalogCover,
        "c43aa92202a46a4a7c4542e85d29acf46d1f9fe005ca52b83d68a70c2eb496d7": .albumCatalogLyrics,
        "61b6e3d6d9b8c76e16dcd5208eb193fea8adc111e1572bd8f4644faea1ef62de": .envelopeCatalogSearch,
        "515968d17bb2fb6eb4743b1c4e08a8b3aca5aaa8eac23e551791276c45def1ee": .envelopeCatalogDetail,
        "a1e3be7f6a2c62c04997728575859375d29792ca942df0d71dc78ccbfdc17a50": .envelopeCatalogCover,
        "806a75aa7e3a866f35842971d53ea9246be419a99401ed181fa90bf77d988dec": .envelopeCatalogLyrics,
    ]
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
        guard config.lyrics?.rule?.format == .hashCatalogLyrics,
              var address = config.lyrics.flatMap({ URLComponents(string: $0.url) }) else { return nil }
        address.path = "/download"
        address.query = nil
        guard let url = address.string else { return nil }
        return LyricsFallbackConfig(url: url + "?ver=1&client=pc&id={{id}}&accesskey={{accesskey}}&fmt=lrc&charset=utf8", contentField: "content", encoding: .base64UTF8,
            requiredVariables: ["id", "accesskey"])

    }

    static func responseValidation(for config: ScraperConfig, url: URL?) -> ScraperResponseValidation? {
        if let configured = config.responseValidation { return configured }
        guard config.search?.rule?.format == .envelopeCatalogSearch else { return nil }
        return ScraperResponseValidation(codePaths: ["code", "req*.code"], successCodes: [0])
    }
}

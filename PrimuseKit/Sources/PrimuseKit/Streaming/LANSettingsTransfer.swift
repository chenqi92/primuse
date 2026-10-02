import Foundation

/// 扫码直传带给 Apple TV 的设置。电视登录的 Apple ID 常常和手机不同,iCloud 键值同步、
/// CloudKit 与 iCloud 钥匙串都到不了它,所以把「同一个 Apple ID 的电视本来能收到、而电视
/// 用得上」的那部分设置随第一段一起带过去。
///
/// - `values`:UserDefaults 里的设置,键就是本机存储用的真实键,值是 `encodeValue` 编出的
///   属性列表字节。电视只认 `LANSettingsTransferPolicy` 放行的键。
/// - `scraperConfigs`:自定义刮削源配置,各是一份 ScraperConfig JSON(与 CloudKit 记录同一份
///   字节,不含 secrets),`secrets` 是它本机旁路文件里的内容。
/// - `secrets`:钥匙串里的秘密(刮削 Cookie、歌词服务器凭据、AI 服务商密钥),键是钥匙串账户名。
/// - `backdropImages`:播放页背景「我的图片」,已缩成电视画面尺寸的 JPEG。只跟着播放背景设置
///   一起装:电视上的「我的图片」整份换成这一份。
///
/// 解码从不失败:缺字段按空处理、解不开的字段丢掉,旧版 TV 不认这个字段,新版 TV 遇到更新的
/// 手机多出来的字段也照常解。这样设置出了问题也不会连累音乐源那一段被拒。
public struct LANSettingsBundle: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var values: [String: Data]
    public var scraperConfigs: [LANScraperConfigEntry]
    public var secrets: [String: String]
    public var backdropImages: [LANBackdropImageEntry]

    public init(version: Int = LANSettingsBundle.currentVersion, values: [String: Data] = [:],
                scraperConfigs: [LANScraperConfigEntry] = [], secrets: [String: String] = [:],
                backdropImages: [LANBackdropImageEntry] = []) {
        self.version = version
        self.values = values
        self.scraperConfigs = scraperConfigs
        self.secrets = secrets
        self.backdropImages = backdropImages
    }

    public var isEmpty: Bool {
        values.isEmpty && scraperConfigs.isEmpty && secrets.isEmpty && backdropImages.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case version, values, scraperConfigs, secrets, backdropImages
    }

    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        version = (try? container?.decodeIfPresent(Int.self, forKey: .version)) ?? 0
        values = (try? container?.decodeIfPresent([String: Data].self, forKey: .values)) ?? [:]
        scraperConfigs = (try? container?.decodeIfPresent(
            [LANScraperConfigEntry].self, forKey: .scraperConfigs
        )) ?? []
        secrets = (try? container?.decodeIfPresent([String: String].self, forKey: .secrets)) ?? [:]
        backdropImages = (try? container?.decodeIfPresent(
            [LANBackdropImageEntry].self, forKey: .backdropImages
        )) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(values, forKey: .values)
        try container.encode(scraperConfigs, forKey: .scraperConfigs)
        try container.encode(secrets, forKey: .secrets)
        // 没有图片就不写这个字段,载荷和以前一模一样。
        if !backdropImages.isEmpty {
            try container.encode(backdropImages, forKey: .backdropImages)
        }
    }

    /// UserDefaults 里的一个值(Data / String / 数字 / 布尔 / 数组 / 字典)编成属性列表字节。
    /// 外面包一层单元素数组,不依赖顶层能不能直接放标量。
    public static func encodeValue(_ value: Any) -> Data? {
        guard PropertyListSerialization.propertyList([value], isValidFor: .binary) else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: [value], format: .binary, options: 0)
    }

    public static func decodeValue(_ data: Data) -> Any? {
        guard let wrapped = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let array = wrapped as? [Any], array.count == 1 else { return nil }
        return array[0]
    }
}

/// 一份自定义刮削源配置。`json` 是 ScraperConfig 自己编出来的 JSON(编码时本来就不带 secrets)。
public struct LANScraperConfigEntry: Codable, Sendable, Equatable {
    public var id: String
    public var json: Data
    public var secrets: [String: String]?

    public init(id: String, json: Data, secrets: [String: String]? = nil) {
        self.id = id
        self.json = json
        self.secrets = secrets
    }
}

/// 播放页背景的一张自选图片。`id` 是 `data` 的内容哈希(64 位小写十六进制),接收端据此核对。
public struct LANBackdropImageEntry: Codable, Sendable, Equatable {
    public var id: String
    public var data: Data

    public init(id: String, data: Data) {
        self.id = id
        self.data = data
    }
}

/// 接收端显示「已同步设置」时的分类,按声明顺序排列。
public enum LANSettingsCategory: String, CaseIterable, Sendable, Comparable {
    case scraping
    case lyricsServers
    case intelligence
    case artistNames
    case playerEffect
    case playerBackdrop

    private var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }
}

/// 扫码直传放行哪些设置。规则是「同一个 Apple ID 的 Apple TV 经 iCloud 能收到、电视又用得上的」:
/// 刮削、歌词 API 服务、智能功能(含推荐意图)、艺术家名称规则、沉浸风格、播放页背景(连同
/// 「我的图片」)。播放设置(电视没有淡入淡出、回放增益、均衡器)、歌词字号、搜索记录、电台订阅
/// 不带;证书信任、同步开关这类按设备做的决定更不能带 —— 电视收到不在表里的键一律丢掉。
///
/// App 层定义的键在这里写成字面值(PrimuseKit 看不到 App 里的类型),发送端在 Debug 构建里
/// 断言它们与 App 里的常量一致。
public enum LANSettingsTransferPolicy {
    public static let scraperSettingsKey = "primuse_scraper_settings_v3"
    public static let lyricsAPIServersKey = "primuse_lyrics_api_servers_v1"
    public static let aiSettingsKey = "ai.settings.v1"
    public static let lyricsTranscriptionKey = "lyrics.transcription.settings.v1"
    public static let playerEffectKey = "primuse.fullscreenPlayerEffect"
    public static let playerBackdropKey = PlayerBackdropSettings.storageKey

    /// 单个设置值、单份刮削配置、单条秘密的上限;配置总量另有上限。请求体整体仍受
    /// `LANTransferSizePolicy.maximumSealedBytes` 约束,这些上限让设置永远挤不掉音乐源。
    public static let maximumValueBytes = 1024 * 1024
    public static let maximumScraperConfigBytes = 4 * 1024 * 1024
    public static let maximumTotalScraperConfigBytes = 8 * 1024 * 1024
    public static let maximumScraperConfigs = 200
    public static let maximumSecretBytes = 64 * 1024
    public static let maximumSecretAccountLength = 1024
    /// 播放背景图片:张数与总量上限。单张受 `maximumValueBytes` 约束。
    public static let maximumBackdropImages = 8
    public static let maximumTotalBackdropImageBytes = 6 * 1024 * 1024

    private static let valueCategories: [String: LANSettingsCategory] = [
        scraperSettingsKey: .scraping,
        lyricsAPIServersKey: .lyricsServers,
        aiSettingsKey: .intelligence,
        lyricsTranscriptionKey: .intelligence,
        AIRecommendationIntentStoragePolicy.storageKey: .intelligence,
        AIRecommendationIntentPresetVisibilityPolicy.storageKey: .intelligence,
        AIRecommendationIntentSelectionPolicy.storageKey: .intelligence,
        ArtistNameConfiguration.storageKey: .artistNames,
        playerEffectKey: .playerEffect,
        playerBackdropKey: .playerBackdrop,
    ]

    public static var allowedValueKeys: Set<String> { Set(valueCategories.keys) }

    public static func category(forValueKey key: String) -> LANSettingsCategory? {
        valueCategories[key]
    }

    /// 秘密只认这几类钥匙串账户:自定义刮削源的 Cookie、歌词 API 服务的 Authorization、
    /// AI 服务商密钥。源凭据走 `CredentialBundle`,本机专用的中继凭据等一概不在其列。
    public static func category(forSecretAccount account: String) -> LANSettingsCategory? {
        guard !account.isEmpty, account.utf8.count <= maximumSecretAccountLength else { return nil }
        if account.hasPrefix("scraper.cookie.config."), account.count > "scraper.cookie.config.".count {
            return .scraping
        }
        if account.hasPrefix("lyrics.apiServer."), account.hasSuffix(".authorization"),
           account.count > "lyrics.apiServer.".count + ".authorization".count {
            return .lyricsServers
        }
        if account.hasPrefix("ai.provider."), account.hasSuffix(".apiKey"),
           account.count > "ai.provider.".count + ".apiKey".count {
            return .intelligence
        }
        return nil
    }

    /// 与 App 里 `ScraperConfigStore` 的文件名规则一致:它既是配置 id,也是磁盘文件名。
    public static func isSafeScraperConfigID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 64,
              id.range(of: ".secrets.", options: [.caseInsensitive]) == nil else { return false }
        return id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }

    /// 两端都过一遍:发送端不多带,接收端不多收。
    public static func sanitized(_ bundle: LANSettingsBundle) -> LANSettingsBundle {
        var result = LANSettingsBundle(version: bundle.version)
        for (key, data) in bundle.values
        where valueCategories[key] != nil && !data.isEmpty && data.count <= maximumValueBytes {
            result.values[key] = data
        }
        var seenConfigIDs = Set<String>()
        var totalConfigBytes = 0
        for entry in bundle.scraperConfigs {
            guard result.scraperConfigs.count < maximumScraperConfigs,
                  isSafeScraperConfigID(entry.id),
                  seenConfigIDs.insert(entry.id).inserted,
                  !entry.json.isEmpty, entry.json.count <= maximumScraperConfigBytes,
                  totalConfigBytes + entry.json.count <= maximumTotalScraperConfigBytes else { continue }
            totalConfigBytes += entry.json.count
            var kept = entry
            if let secrets = entry.secrets {
                let bytes = secrets.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
                kept.secrets = secrets.isEmpty || bytes > maximumSecretBytes ? nil : secrets
            }
            result.scraperConfigs.append(kept)
        }
        for (account, secret) in bundle.secrets
        where category(forSecretAccount: account) != nil
            && !secret.isEmpty && secret.utf8.count <= maximumSecretBytes {
            result.secrets[account] = secret
        }
        // 图片只跟着播放背景设置走:设置没带,图片也不收。
        if result.values[playerBackdropKey] != nil {
            var seenImageIDs = Set<String>()
            var totalImageBytes = 0
            for entry in bundle.backdropImages {
                guard result.backdropImages.count < maximumBackdropImages,
                      LibraryArtworkContentIDPolicy.isValid(entry.id),
                      seenImageIDs.insert(entry.id).inserted,
                      !entry.data.isEmpty, entry.data.count <= maximumValueBytes,
                      totalImageBytes + entry.data.count <= maximumTotalBackdropImageBytes else { continue }
                totalImageBytes += entry.data.count
                result.backdropImages.append(entry)
            }
        }
        return result
    }

    /// 设置值的应用顺序。刮削设置必须排在最前、紧跟自定义刮削配置之后:它载入时会删掉找不到
    /// 配置的自定义源行,又会给没有行的配置补一行;其余按键名,顺序稳定。
    public static func applicationOrder<Keys: Collection>(of keys: Keys) -> [String] where Keys.Element == String {
        keys.sorted { lhs, rhs in
            let lhsFirst = lhs == scraperSettingsKey
            let rhsFirst = rhs == scraperSettingsKey
            if lhsFirst != rhsFirst { return lhsFirst }
            return lhs < rhs
        }
    }

    /// 这包设置涉及哪些分类(按声明顺序、不重复)。
    public static func categories(in bundle: LANSettingsBundle) -> [LANSettingsCategory] {
        var result = Set<LANSettingsCategory>()
        for key in bundle.values.keys {
            if let category = category(forValueKey: key) { result.insert(category) }
        }
        if !bundle.scraperConfigs.isEmpty { result.insert(.scraping) }
        for account in bundle.secrets.keys {
            if let category = category(forSecretAccount: account) { result.insert(category) }
        }
        return result.sorted()
    }
}

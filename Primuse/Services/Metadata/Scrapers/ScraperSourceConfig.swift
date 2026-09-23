import Foundation

struct ScraperSourceConfig: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var type: MusicScraperType
    var isEnabled: Bool
    var priority: Int
    /// 旧版本把 Cookie 写在这一行里，跟着整份 `ScraperSettings` 经 iCloud 键值同步明文漫游。
    /// 现在只是兼容字段：`ScraperSettings.save` 落盘前抹掉，读到非空值只当作旧 blob 里
    /// 尚未搬进钥匙串的数据。取 Cookie 走 `ScraperSourceCookieStore`。
    var cookie: String?
    var extraConfig: [String: String]?

    var displayName: String { type.displayName }

    /// Cookie 在钥匙串里的账户名。自定义源按配置 id 记：行 id 在各设备上可能不同
    /// （配置先经 CloudKit 到达时本机会自己补一行、再被别的设备的 blob 整份换掉），
    /// 配置 id 才是跨设备稳定的那个。内置源不支持 Cookie，按行 id 兜底只为不丢数据。
    var cookieKeychainAccount: String {
        switch type {
        case .custom(let configID): "scraper.cookie.config.\(configID)"
        default: "scraper.cookie.source.\(id)"
        }
    }

    var isConfigured: Bool { true }

    /// Default sources: built-in only, all disabled. Scraping is opt-in — users
    /// enable a built-in source or import a custom one before any network
    /// metadata lookup happens.
    static func defaultSources() -> [ScraperSourceConfig] {
        MusicScraperType.builtInOrder.enumerated().map { index, type in
            ScraperSourceConfig(
                id: UUID().uuidString,
                type: type,
                isEnabled: defaultEnabled(for: type),
                priority: index
            )
        }
    }

    /// Whether a built-in scraper should be enabled when first added to a
    /// fresh install or when migrated into an existing install.
    static func defaultEnabled(for type: MusicScraperType) -> Bool {
        switch type {
        case .itunes, .musicBrainz, .lrclib, .lyricsServer: false
        case .custom: true
        }
    }

    /// Create a source config for a custom scraper config
    static func fromCustomConfig(_ config: ScraperConfig) -> ScraperSourceConfig {
        ScraperSourceConfig(
            id: UUID().uuidString,
            type: .custom(config.id),
            isEnabled: true,
            priority: 999  // will be re-assigned when added
        )
    }
}

/// 自定义刮削源的 Cookie 存取。刮削源列表整份经 iCloud 键值同步（明文），Cookie 不能
/// 跟着走：单独放钥匙串，「凭据」同步开关开着时走 iCloud 钥匙串，关着就只留本机，
/// 与 AI API key 同一套规矩（`KeychainService.setPassword` 里判定）。
enum ScraperSourceCookieStore {
    /// 钥匙串里的值优先；行里还带着 Cookie 只可能是旧版本写的 blob 尚未搬家，兜底照用。
    /// 只有声明了 Cookie 的自定义源才去查钥匙串，别让不相干的源每次刮削都撞一次未命中。
    static func cookie(for config: ScraperSourceConfig) -> String? {
        guard config.type.supportsCookie else { return nil }
        if let stored = KeychainService.getPassword(for: config.cookieKeychainAccount), !stored.isEmpty {
            return stored
        }
        guard let legacy = config.cookie, !legacy.isEmpty else { return nil }
        return legacy
    }

    /// 空白视为删除。
    @discardableResult
    static func save(_ cookie: String?, for config: ScraperSourceConfig) -> Bool {
        let account = config.cookieKeychainAccount
        guard let trimmed = cookie?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return KeychainService.deletePassword(for: account) }
        return KeychainService.setPassword(trimmed, for: account)
    }

    @discardableResult
    static func remove(for config: ScraperSourceConfig) -> Bool {
        KeychainService.deletePassword(for: config.cookieKeychainAccount)
    }

    /// 把旧 blob 里的 Cookie 搬进钥匙串并从行里抹掉，返回是否有搬动（调用方据此重写本机 blob）。
    /// 写不进钥匙串的那行保留原值，下次读取再试。搬家不算一次编辑，调用方不能因此
    /// `markChanged`：抹白的 blob 一推上去，老设备会丢 Cookie、再写回来同步过来，两边打乒乓。
    static func migrateLegacyCookies(in settings: inout ScraperSettings) -> Bool {
        var migrated = false
        for index in settings.sources.indices {
            guard let legacy = settings.sources[index].cookie else { continue }
            let trimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty,
               !KeychainService.setPassword(trimmed, for: settings.sources[index].cookieKeychainAccount) {
                plog("⚠️ Scraper cookie migration failed for source \(settings.sources[index].id.prefix(8))…")
                continue
            }
            settings.sources[index].cookie = nil
            migrated = true
        }
        if migrated {
            plog("🔐 Moved legacy scraper cookies into the Keychain")
        }
        return migrated
    }
}

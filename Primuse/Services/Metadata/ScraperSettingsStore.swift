import Foundation

struct ScraperSettings: Codable, Sendable {
    static let defaultsKey = "primuse_scraper_settings_v3"
    private static let v2Key = "primuse_scraper_settings_v2"

    var sources: [ScraperSourceConfig]
    var onlyFillMissingFields: Bool
    /// 本地/网盘等普通源确实没有歌词时，播放时自动按启用顺序向在线歌词源取一次。
    var autoFetchOnlineLyrics: Bool

    init(
        sources: [ScraperSourceConfig]? = nil,
        onlyFillMissingFields: Bool = true,
        autoFetchOnlineLyrics: Bool = true
    ) {
        self.sources = sources ?? ScraperSourceConfig.defaultSources()
        self.onlyFillMissingFields = onlyFillMissingFields
        self.autoFetchOnlineLyrics = autoFetchOnlineLyrics
    }

    private enum CodingKeys: String, CodingKey {
        case sources
        case onlyFillMissingFields
        case autoFetchOnlineLyrics
    }

    /// 旧版本写入的设置没有 autoFetchOnlineLyrics，缺省按开启处理。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sources = try container.decode([ScraperSourceConfig].self, forKey: .sources)
        self.onlyFillMissingFields = try container.decode(Bool.self, forKey: .onlyFillMissingFields)
        self.autoFetchOnlineLyrics = try container.decodeIfPresent(Bool.self, forKey: .autoFetchOnlineLyrics) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sources, forKey: .sources)
        try container.encode(onlyFillMissingFields, forKey: .onlyFillMissingFields)
        try container.encode(autoFetchOnlineLyrics, forKey: .autoFetchOnlineLyrics)
    }

    static func load(defaults: UserDefaults = .standard) -> ScraperSettings {
        load(defaults: defaults, persistReconciliation: false)
    }

    /// Loads and reconciles settings without mutating UserDefaults. Background
    /// scraper tasks call `load()` concurrently, so persistence is deliberately
    /// confined to the main-actor settings store.
    ///
    /// 旧版本写进 blob 的 Cookie 也只在 store 这条路径上搬进钥匙串（见
    /// `finishLoad`）；后台的 `load()` 读到残留值就原样带着，由
    /// `ScraperSourceCookieStore.cookie(for:)` 兜底。
    private static func load(
        defaults: UserDefaults,
        persistReconciliation: Bool
    ) -> ScraperSettings {
        // Try v3 first
        if let data = defaults.data(forKey: defaultsKey),
           let settings = try? JSONDecoder().decode(ScraperSettings.self, from: data) {
            let (reconciled, didChange) = reconcileLoadedSettings(settings)
            return finishLoad(
                reconciled,
                defaults: defaults,
                persist: persistReconciliation,
                needsSave: didChange
            )
        }

        // Migrate from v2 (had hardcoded third-party scraper types)
        if let data = defaults.data(forKey: v2Key),
           let settings = try? JSONDecoder().decode(ScraperSettings.self, from: data) {
            // v2 sources with old hardcoded types are auto-migrated by MusicScraperType.init(rawValue:)
            // which converts unknown raw values to .custom(id)
            // Filter out custom sources whose configs don't exist (removed hardcoded scrapers)
            var migrated = settings
            migrated.sources = settings.sources.filter { source in
                switch source.type {
                case .musicBrainz, .lrclib, .itunes, .lyricsServer: true
                case .custom(let id): ScraperConfigStore.shared.exists(id: id)
                }
            }
            // Ensure built-in sources exist
            for builtIn in MusicScraperType.builtInOrder {
                if !migrated.sources.contains(where: { $0.type == builtIn }) {
                    migrated.sources.append(ScraperSourceConfig(
                        id: UUID().uuidString,
                        type: builtIn,
                        // v2 时代的内置源都默认开启；歌词服务器是后来加的，按新默认值处理。
                        isEnabled: builtIn == .lyricsServer
                            ? ScraperSourceConfig.defaultEnabled(for: builtIn)
                            : true,
                        priority: migrated.sources.count
                    ))
                }
            }
            let (reconciled, _) = reconcileLoadedSettings(migrated)
            let finished = finishLoad(
                reconciled,
                defaults: defaults,
                persist: persistReconciliation,
                needsSave: true
            )
            if persistReconciliation {
                defaults.removeObject(forKey: v2Key)
            }
            return finished
        }

        let (reconciled, didChange) = reconcileLoadedSettings(ScraperSettings())
        return finishLoad(
            reconciled,
            defaults: defaults,
            persist: persistReconciliation,
            needsSave: didChange
        )
    }

    /// 主线程 store 路径的收尾：把旧 blob 里的 Cookie 搬进钥匙串，再把抹白后的 blob
    /// 写回本机。这里只写 UserDefaults、不 `markChanged`，和补齐内置源的对账一样不算编辑。
    private static func finishLoad(
        _ settings: ScraperSettings,
        defaults: UserDefaults,
        persist: Bool,
        needsSave: Bool
    ) -> ScraperSettings {
        guard persist else { return settings }
        var result = settings
        let migratedCookies = ScraperSourceCookieStore.migrateLegacyCookies(in: &result)
        if needsSave || migratedCookies {
            result.save(defaults: defaults)
        }
        return result
    }

    fileprivate static func loadPersistingReconciliation(
        defaults: UserDefaults = .standard
    ) -> ScraperSettings {
        load(defaults: defaults, persistReconciliation: true)
    }

    /// 落盘的 blob 会经 iCloud 键值同步：Cookie 一律抹掉，只留在钥匙串里。
    func save(defaults: UserDefaults = .standard) {
        var stripped = self
        for index in stripped.sources.indices {
            stripped.sources[index].cookie = nil
        }
        guard let data = try? JSONEncoder().encode(stripped) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Sorted enabled sources
    var enabledSources: [ScraperSourceConfig] {
        sources.filter(\.isEnabled).sorted { $0.priority < $1.priority }
    }

    private static func reconcileLoadedSettings(_ settings: ScraperSettings) -> (ScraperSettings, Bool) {
        var reconciled = settings
        var didChange = false
        var seenTypes = Set<MusicScraperType>()

        reconciled.sources = reconciled.sources
            .sorted { $0.priority < $1.priority }
            .filter { source in
                if case .custom(let id) = source.type,
                   !ScraperConfigStore.shared.exists(id: id) {
                    didChange = true
                    return false
                }
                guard seenTypes.insert(source.type).inserted else {
                    didChange = true
                    return false
                }
                return true
            }

        var nextPriority = (reconciled.sources.map(\.priority).max() ?? -1) + 1
        let hadITunes = reconciled.sources.contains(where: { $0.type == .itunes })

        for builtIn in MusicScraperType.builtInOrder where !reconciled.sources.contains(where: { $0.type == builtIn }) {
            reconciled.sources.append(
                ScraperSourceConfig(
                    id: UUID().uuidString,
                    type: builtIn,
                    isEnabled: ScraperSourceConfig.defaultEnabled(for: builtIn),
                    priority: nextPriority
                )
            )
            nextPriority += 1
            didChange = true
        }

        // First-time iTunes migration: when iTunes is being added to existing
        // settings (which had MusicBrainz/LRCLIB enabled by the old defaults),
        // realign with the new defaults — iTunes on top, others demoted to
        // disabled. Built-in sources can't be removed via UI, so this branch
        // runs at most once per install.
        if !hadITunes, reconciled.sources.contains(where: { $0.type == .itunes }) {
            for index in reconciled.sources.indices {
                switch reconciled.sources[index].type {
                case .musicBrainz, .lrclib:
                    if reconciled.sources[index].isEnabled {
                        reconciled.sources[index].isEnabled = false
                        didChange = true
                    }
                default: break
                }
            }
            if let itunesIdx = reconciled.sources.firstIndex(where: { $0.type == .itunes }), itunesIdx != 0 {
                let itunes = reconciled.sources.remove(at: itunesIdx)
                reconciled.sources.insert(itunes, at: 0)
                didChange = true
            }
        }

        for config in ScraperConfigStore.shared.allConfigs where !reconciled.sources.contains(where: { $0.type == .custom(config.id) }) {
            var source = ScraperSourceConfig.fromCustomConfig(config)
            source.priority = nextPriority
            reconciled.sources.append(source)
            nextPriority += 1
            didChange = true
        }

        reconciled.sources.sort { $0.priority < $1.priority }
        for index in reconciled.sources.indices {
            if reconciled.sources[index].priority != index {
                reconciled.sources[index].priority = index
                didChange = true
            }
        }

        return (reconciled, didChange)
    }
}

@MainActor
@Observable
final class ScraperSettingsStore {
    /// 行里不带 Cookie（加载时已搬进钥匙串），界面判断有没有 Cookie 看 `cookieSourceIDs`。
    var sources: [ScraperSourceConfig] { didSet { persist() } }
    var onlyFillMissingFields: Bool { didSet { persist() } }
    var autoFetchOnlineLyrics: Bool { didSet { persist() } }
    /// 钥匙串里存着 Cookie 的源（按行 id）。Cookie 改动不经 `sources`，界面靠这个集合刷新。
    private(set) var cookieSourceIDs: Set<String> = []

    private let defaults: UserDefaults
    private var suppressPersist = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let settings = ScraperSettings.loadPersistingReconciliation(defaults: defaults)
        self.sources = settings.sources.sorted { $0.priority < $1.priority }
        self.onlyFillMissingFields = settings.onlyFillMissingFields
        self.autoFetchOnlineLyrics = settings.autoFetchOnlineLyrics
        self.cookieSourceIDs = Self.sourceIDsWithCookie(in: self.sources)

        CloudKVSSync.shared.register(key: ScraperSettings.defaultsKey) { [weak self] in
            self?.reloadFromDefaults()
        }
    }

    private func reloadFromDefaults() {
        let settings = ScraperSettings.loadPersistingReconciliation(defaults: defaults)
        suppressPersist = true
        defer { suppressPersist = false }
        sources = settings.sources.sorted { $0.priority < $1.priority }
        onlyFillMissingFields = settings.onlyFillMissingFields
        autoFetchOnlineLyrics = settings.autoFetchOnlineLyrics
        cookieSourceIDs = Self.sourceIDsWithCookie(in: sources)
    }

    private static func sourceIDsWithCookie(in sources: [ScraperSourceConfig]) -> Set<String> {
        Set(sources.filter { ScraperSourceCookieStore.cookie(for: $0) != nil }.map(\.id))
    }

    func hasCookie(for id: String) -> Bool {
        cookieSourceIDs.contains(id)
    }

    /// 编辑框回填用：从钥匙串取。
    func cookie(for id: String) -> String? {
        guard let source = sources.first(where: { $0.id == id }) else { return nil }
        return ScraperSourceCookieStore.cookie(for: source)
    }

    var enabledSources: [ScraperSourceConfig] {
        sources.filter(\.isEnabled)
    }

    func toggleSource(id: String) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].isEnabled.toggle()
    }

    func reorderSources(fromOffsets: IndexSet, toOffset: Int) {
        sources.move(fromOffsets: fromOffsets, toOffset: toOffset)
        for i in sources.indices {
            sources[i].priority = i
        }
    }

    /// Cookie 只进钥匙串，不动 `sources`、不推 KVS；ScraperManager 的 cacheKey 每次
    /// 都从钥匙串取值，改了自然换新实例。
    func updateCookie(id: String, cookie: String?) {
        guard let source = sources.first(where: { $0.id == id }) else { return }
        guard ScraperSourceCookieStore.save(cookie, for: source) else {
            plog("⚠️ Scraper cookie save failed for source \(id.prefix(8))…")
            return
        }
        if ScraperSourceCookieStore.cookie(for: source) != nil {
            cookieSourceIDs.insert(id)
        } else {
            cookieSourceIDs.remove(id)
        }
    }

    /// Add a custom scraper source from an imported config
    func addCustomSource(_ config: ScraperConfig) {
        // Remove existing source for same config if present
        sources.removeAll { source in
            if case .custom(let id) = source.type, id == config.id { return true }
            return false
        }
        var newSource = ScraperSourceConfig.fromCustomConfig(config)
        newSource.priority = sources.count
        sources.append(newSource)
    }

    /// Idempotent: ensure a custom-source row exists for the given config (used by
    /// CloudKit sync after a remote config arrives).
    func ensureCustomSourcePresent(for config: ScraperConfig) {
        let alreadyPresent = sources.contains { source in
            if case .custom(let id) = source.type, id == config.id { return true }
            return false
        }
        guard !alreadyPresent else { return }
        addCustomSource(config)
    }

    /// Remove a custom scraper source, its config and its Keychain cookie
    func removeCustomSource(id: String) {
        if let index = sources.firstIndex(where: { $0.id == id }) {
            if case .custom(let configId) = sources[index].type {
                ScraperConfigStore.shared.delete(id: configId)
            }
            ScraperSourceCookieStore.remove(for: sources[index])
            cookieSourceIDs.remove(id)
            sources.remove(at: index)
        }
    }

    func resetToDefaults() {
        // Keep custom sources, reset built-in only
        let customSources = sources.filter { !$0.type.isBuiltIn }
        var defaults = ScraperSourceConfig.defaultSources()
        defaults.append(contentsOf: customSources)
        for i in defaults.indices { defaults[i].priority = i }
        sources = defaults
        onlyFillMissingFields = true
        autoFetchOnlineLyrics = true
    }

    func snapshot() -> ScraperSettings {
        ScraperSettings(
            sources: sources,
            onlyFillMissingFields: onlyFillMissingFields,
            autoFetchOnlineLyrics: autoFetchOnlineLyrics
        )
    }

    private func persist() {
        guard !suppressPersist else { return }
        snapshot().save(defaults: defaults)
        CloudKVSSync.shared.markChanged(key: ScraperSettings.defaultsKey)
    }
}

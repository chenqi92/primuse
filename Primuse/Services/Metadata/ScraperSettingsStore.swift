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
    private static func load(
        defaults: UserDefaults,
        persistReconciliation: Bool
    ) -> ScraperSettings {
        // Try v3 first
        if let data = defaults.data(forKey: defaultsKey),
           let settings = try? JSONDecoder().decode(ScraperSettings.self, from: data) {
            let (reconciled, didChange) = reconcileLoadedSettings(settings)
            if persistReconciliation, didChange {
                reconciled.save(defaults: defaults)
            }
            return reconciled
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
            if persistReconciliation {
                reconciled.save(defaults: defaults)
                defaults.removeObject(forKey: v2Key)
            }
            return reconciled
        }

        let (reconciled, didChange) = reconcileLoadedSettings(ScraperSettings())
        if persistReconciliation, didChange {
            reconciled.save(defaults: defaults)
        }
        return reconciled
    }

    fileprivate static func loadPersistingReconciliation(
        defaults: UserDefaults = .standard
    ) -> ScraperSettings {
        load(defaults: defaults, persistReconciliation: true)
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
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
    var sources: [ScraperSourceConfig] { didSet { persist() } }
    var onlyFillMissingFields: Bool { didSet { persist() } }
    var autoFetchOnlineLyrics: Bool { didSet { persist() } }

    private let defaults: UserDefaults
    private var suppressPersist = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let settings = ScraperSettings.loadPersistingReconciliation(defaults: defaults)
        self.sources = settings.sources.sorted { $0.priority < $1.priority }
        self.onlyFillMissingFields = settings.onlyFillMissingFields
        self.autoFetchOnlineLyrics = settings.autoFetchOnlineLyrics

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

    func updateCookie(id: String, cookie: String?) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].cookie = cookie
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

    /// Remove a custom scraper source and its config
    func removeCustomSource(id: String) {
        if let index = sources.firstIndex(where: { $0.id == id }) {
            if case .custom(let configId) = sources[index].type {
                ScraperConfigStore.shared.delete(id: configId)
            }
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

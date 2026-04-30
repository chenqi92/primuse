import Foundation

struct ScraperSettings: Codable, Sendable {
    static let defaultsKey = "primuse_scraper_settings_v3"
    private static let v2Key = "primuse_scraper_settings_v2"

    var sources: [ScraperSourceConfig]
    var onlyFillMissingFields: Bool

    init(sources: [ScraperSourceConfig]? = nil, onlyFillMissingFields: Bool = true) {
        self.sources = sources ?? ScraperSourceConfig.defaultSources()
        self.onlyFillMissingFields = onlyFillMissingFields
    }

    static func load(defaults: UserDefaults = .standard) -> ScraperSettings {
        // Try v3 first
        if let data = defaults.data(forKey: defaultsKey),
           let settings = try? JSONDecoder().decode(ScraperSettings.self, from: data) {
            let (reconciled, didChange) = reconcileLoadedSettings(settings)
            if didChange {
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
                case .musicBrainz, .lrclib: true
                case .custom(let id): ScraperConfigStore.shared.exists(id: id)
                }
            }
            // Ensure built-in sources exist
            for builtIn in MusicScraperType.builtInOrder {
                if !migrated.sources.contains(where: { $0.type == builtIn }) {
                    migrated.sources.append(ScraperSourceConfig(
                        id: UUID().uuidString,
                        type: builtIn,
                        isEnabled: true,
                        priority: migrated.sources.count
                    ))
                }
            }
            defaults.removeObject(forKey: v2Key)
            let (reconciled, _) = reconcileLoadedSettings(migrated)
            reconciled.save(defaults: defaults)
            return reconciled
        }

        let (reconciled, didChange) = reconcileLoadedSettings(ScraperSettings())
        if didChange {
            reconciled.save(defaults: defaults)
        }
        return reconciled
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

        for builtIn in MusicScraperType.builtInOrder where !reconciled.sources.contains(where: { $0.type == builtIn }) {
            reconciled.sources.append(
                ScraperSourceConfig(
                    id: UUID().uuidString,
                    type: builtIn,
                    isEnabled: true,
                    priority: nextPriority
                )
            )
            nextPriority += 1
            didChange = true
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

    private let defaults: UserDefaults
    private var suppressPersist = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let settings = ScraperSettings.load(defaults: defaults)
        self.sources = settings.sources.sorted { $0.priority < $1.priority }
        self.onlyFillMissingFields = settings.onlyFillMissingFields

        CloudKVSSync.shared.register(key: ScraperSettings.defaultsKey) { [weak self] in
            self?.reloadFromDefaults()
        }
    }

    private func reloadFromDefaults() {
        let settings = ScraperSettings.load(defaults: defaults)
        suppressPersist = true
        defer { suppressPersist = false }
        sources = settings.sources.sorted { $0.priority < $1.priority }
        onlyFillMissingFields = settings.onlyFillMissingFields
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
    }

    func snapshot() -> ScraperSettings {
        ScraperSettings(sources: sources, onlyFillMissingFields: onlyFillMissingFields)
    }

    private func persist() {
        guard !suppressPersist else { return }
        snapshot().save(defaults: defaults)
        CloudKVSSync.shared.markChanged(key: ScraperSettings.defaultsKey)
    }
}

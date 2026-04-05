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
            return settings
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
            migrated.save(defaults: defaults)
            defaults.removeObject(forKey: v2Key)
            return migrated
        }

        return ScraperSettings()
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Sorted enabled sources
    var enabledSources: [ScraperSourceConfig] {
        sources.filter(\.isEnabled).sorted { $0.priority < $1.priority }
    }
}

@MainActor
@Observable
final class ScraperSettingsStore {
    var sources: [ScraperSourceConfig] { didSet { persist() } }
    var onlyFillMissingFields: Bool { didSet { persist() } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let settings = ScraperSettings.load(defaults: defaults)
        self.sources = settings.sources.sorted { $0.priority < $1.priority }
        self.onlyFillMissingFields = settings.onlyFillMissingFields
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
        snapshot().save(defaults: defaults)
    }
}

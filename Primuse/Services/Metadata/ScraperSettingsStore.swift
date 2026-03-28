import Foundation

struct ScraperSettings: Codable, Sendable {
    static let defaultsKey = "primuse_scraper_settings_v2"
    private static let legacyKey = "primuse_scraper_settings_v1"

    var sources: [ScraperSourceConfig]
    var onlyFillMissingFields: Bool

    init(sources: [ScraperSourceConfig]? = nil, onlyFillMissingFields: Bool = true) {
        self.sources = sources ?? ScraperSourceConfig.defaultSources()
        self.onlyFillMissingFields = onlyFillMissingFields
    }

    static func load(defaults: UserDefaults = .standard) -> ScraperSettings {
        // Try v2 first
        if let data = defaults.data(forKey: defaultsKey),
           let settings = try? JSONDecoder().decode(ScraperSettings.self, from: data) {
            return settings
        }

        // Migrate from v1
        if let data = defaults.data(forKey: legacyKey),
           let v1 = try? JSONDecoder().decode(LegacySettings.self, from: data) {
            let settings = migrateFromV1(v1)
            settings.save(defaults: defaults)
            defaults.removeObject(forKey: legacyKey)
            return settings
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

    // MARK: - Migration

    private struct LegacySettings: Codable {
        var musicBrainzMetadataEnabled = true
        var musicBrainzCoverEnabled = true
        var lrclibLyricsEnabled = true
        var onlyFillMissingFields = true
    }

    private static func migrateFromV1(_ v1: LegacySettings) -> ScraperSettings {
        var sources = ScraperSourceConfig.defaultSources()

        // Apply v1 settings to matching sources
        if let mbIndex = sources.firstIndex(where: { $0.type == .musicBrainz }) {
            sources[mbIndex].isEnabled = v1.musicBrainzMetadataEnabled || v1.musicBrainzCoverEnabled
        }
        if let lrclibIndex = sources.firstIndex(where: { $0.type == .lrclib }) {
            sources[lrclibIndex].isEnabled = v1.lrclibLyricsEnabled
        }

        return ScraperSettings(sources: sources, onlyFillMissingFields: v1.onlyFillMissingFields)
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
        // Reassign priorities to match new order
        for i in sources.indices {
            sources[i].priority = i
        }
    }

    func updateCookie(id: String, cookie: String?) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].cookie = cookie
    }

    func resetToDefaults() {
        sources = ScraperSourceConfig.defaultSources()
        onlyFillMissingFields = true
    }

    func snapshot() -> ScraperSettings {
        ScraperSettings(sources: sources, onlyFillMissingFields: onlyFillMissingFields)
    }

    private func persist() {
        snapshot().save(defaults: defaults)
    }
}

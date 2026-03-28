import Foundation

struct ScraperSettings: Codable, Sendable {
    static let defaultsKey = "primuse_scraper_settings_v1"

    var musicBrainzMetadataEnabled = true
    var musicBrainzCoverEnabled = true
    var lrclibLyricsEnabled = true
    var onlyFillMissingFields = true

    static func load(defaults: UserDefaults = .standard) -> ScraperSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(ScraperSettings.self, from: data) else {
            return ScraperSettings()
        }
        return settings
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

@MainActor
@Observable
final class ScraperSettingsStore {
    var musicBrainzMetadataEnabled: Bool { didSet { persist() } }
    var musicBrainzCoverEnabled: Bool { didSet { persist() } }
    var lrclibLyricsEnabled: Bool { didSet { persist() } }
    var onlyFillMissingFields: Bool { didSet { persist() } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let settings = ScraperSettings.load(defaults: defaults)
        self.musicBrainzMetadataEnabled = settings.musicBrainzMetadataEnabled
        self.musicBrainzCoverEnabled = settings.musicBrainzCoverEnabled
        self.lrclibLyricsEnabled = settings.lrclibLyricsEnabled
        self.onlyFillMissingFields = settings.onlyFillMissingFields
    }

    func snapshot() -> ScraperSettings {
        ScraperSettings(
            musicBrainzMetadataEnabled: musicBrainzMetadataEnabled,
            musicBrainzCoverEnabled: musicBrainzCoverEnabled,
            lrclibLyricsEnabled: lrclibLyricsEnabled,
            onlyFillMissingFields: onlyFillMissingFields
        )
    }

    private func persist() {
        snapshot().save(defaults: defaults)
    }
}

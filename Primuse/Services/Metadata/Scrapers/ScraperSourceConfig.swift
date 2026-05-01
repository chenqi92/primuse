import Foundation

struct ScraperSourceConfig: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var type: MusicScraperType
    var isEnabled: Bool
    var priority: Int
    var cookie: String?
    var extraConfig: [String: String]?

    var displayName: String { type.displayName }

    var isConfigured: Bool { true }

    /// Default sources: built-in only. iTunes is enabled by default (high-quality
    /// covers and broad catalog); MusicBrainz/LRCLIB are present but disabled so
    /// users can opt-in if they want lyric or open-database lookups.
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
        case .itunes: true
        case .musicBrainz, .lrclib: false
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

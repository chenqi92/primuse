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

    /// Default sources: built-in only (MusicBrainz + LRCLIB)
    static func defaultSources() -> [ScraperSourceConfig] {
        MusicScraperType.builtInOrder.enumerated().map { index, type in
            ScraperSourceConfig(
                id: UUID().uuidString,
                type: type,
                isEnabled: true,
                priority: index
            )
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

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

    static func defaultSources() -> [ScraperSourceConfig] {
        MusicScraperType.defaultOrder.enumerated().map { index, type in
            ScraperSourceConfig(
                id: UUID().uuidString,
                type: type,
                isEnabled: type.defaultEnabled,
                priority: index
            )
        }
    }
}

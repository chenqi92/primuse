import SwiftUI

/// Represents a scraper source type — either a built-in scraper or a user-imported custom config.
enum MusicScraperType: Sendable, Identifiable, Hashable {
    case musicBrainz
    case lrclib
    case custom(String)  // config ID

    var id: String {
        switch self {
        case .musicBrainz: "musicBrainz"
        case .lrclib: "lrclib"
        case .custom(let configId): "custom_\(configId)"
        }
    }

    /// Raw string for Codable compatibility
    var rawValue: String {
        switch self {
        case .musicBrainz: "musicBrainz"
        case .lrclib: "lrclib"
        case .custom(let configId): "custom:\(configId)"
        }
    }

    init(rawValue: String) {
        switch rawValue {
        case "musicBrainz": self = .musicBrainz
        case "lrclib": self = .lrclib
        default:
            if rawValue.hasPrefix("custom:") {
                self = .custom(String(rawValue.dropFirst(7)))
            } else {
                // Legacy migration: old hardcoded types → custom
                self = .custom(rawValue)
            }
        }
    }

    var displayName: String {
        switch self {
        case .musicBrainz: "MusicBrainz"
        case .lrclib: "LRCLIB"
        case .custom(let configId):
            ScraperConfigStore.shared.config(for: configId)?.name ?? configId
        }
    }

    var iconName: String {
        switch self {
        case .musicBrainz: "globe"
        case .lrclib: "text.quote"
        case .custom(let configId):
            ScraperConfigStore.shared.config(for: configId)?.icon ?? "puzzlepiece"
        }
    }

    var themeColor: Color {
        switch self {
        case .musicBrainz: Color(red: 0.73, green: 0.28, blue: 0.56)
        case .lrclib: Color(red: 0.39, green: 0.4, blue: 0.95)
        case .custom(let configId):
            if let hex = ScraperConfigStore.shared.config(for: configId)?.color {
                Color(hex: hex)
            } else {
                .accentColor
            }
        }
    }

    var localizedDescription: String {
        switch self {
        case .musicBrainz: return String(localized: "scraper_musicbrainz_desc")
        case .lrclib: return String(localized: "scraper_lrclib_desc")
        case .custom(let configId):
            let caps = ScraperConfigStore.shared.config(for: configId)?.capabilities.joined(separator: ", ") ?? ""
            return String(localized: "custom_scraper_desc") + " (\(caps))"
        }
    }

    var supportsMetadata: Bool {
        switch self {
        case .musicBrainz: true
        case .lrclib: false
        case .custom(let id): ScraperConfigStore.shared.config(for: id)?.supportsMetadata ?? false
        }
    }

    var supportsCover: Bool {
        switch self {
        case .musicBrainz: true
        case .lrclib: false
        case .custom(let id): ScraperConfigStore.shared.config(for: id)?.supportsCover ?? false
        }
    }

    var supportsLyrics: Bool {
        switch self {
        case .musicBrainz: false
        case .lrclib: true
        case .custom(let id): ScraperConfigStore.shared.config(for: id)?.supportsLyrics ?? false
        }
    }

    var supportsCookie: Bool {
        switch self {
        case .musicBrainz, .lrclib: false
        case .custom(let id): ScraperConfigStore.shared.config(for: id)?.supportsCookie ?? false
        }
    }

    var isBuiltIn: Bool {
        switch self {
        case .musicBrainz, .lrclib: true
        case .custom: false
        }
    }

    /// Built-in scrapers in default order
    static var builtInOrder: [MusicScraperType] {
        [.musicBrainz, .lrclib]
    }
}

// MARK: - Codable

extension MusicScraperType: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self.init(rawValue: raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Color hex init

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: Double
        if hex.count == 6 {
            r = Double((int >> 16) & 0xFF) / 255.0
            g = Double((int >> 8) & 0xFF) / 255.0
            b = Double(int & 0xFF) / 255.0
        } else {
            r = 0.5; g = 0.5; b = 0.5
        }
        self.init(red: r, green: g, blue: b)
    }
}

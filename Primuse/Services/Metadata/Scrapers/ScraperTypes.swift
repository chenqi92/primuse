import SwiftUI

enum MusicScraperType: String, Codable, Sendable, CaseIterable, Identifiable {
    case source_b
    case source_e
    case source_d
    case source_c
    case source_a
    case musicBrainz
    case lrclib

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .source_b: "外部来源B"
        case .source_e: "酷我音乐"
        case .source_d: "咪咕音乐"
        case .source_c: "QQ音乐"
        case .source_a: "外部来源A"
        case .musicBrainz: "MusicBrainz"
        case .lrclib: "LRCLIB"
        }
    }

    var iconName: String {
        switch self {
        case .source_b: "waveform"
        case .source_e: "headphones"
        case .source_d: "music.note.list"
        case .source_c: "music.note"
        case .source_a: "cloud"
        case .musicBrainz: "globe"
        case .lrclib: "text.quote"
        }
    }

    var themeColor: Color {
        switch self {
        case .source_b: Color(red: 0.13, green: 0.59, blue: 0.95) // blue
        case .source_e: Color(red: 1.0, green: 0.4, blue: 0.0)     // orange
        case .source_d: Color(red: 1.0, green: 0.02, blue: 0.33)   // red
        case .source_c: Color(red: 0.19, green: 0.76, blue: 0.49) // green
        case .source_a: Color(red: 0.9, green: 0.0, blue: 0.15)  // red
        case .musicBrainz: Color(red: 0.73, green: 0.28, blue: 0.56) // purple
        case .lrclib: Color(red: 0.39, green: 0.4, blue: 0.95)  // indigo
        }
    }

    var localizedDescription: String {
        switch self {
        case .source_b: String(localized: "scraper_source_b_desc")
        case .source_e: String(localized: "scraper_source_e_desc")
        case .source_d: String(localized: "scraper_source_d_desc")
        case .source_c: String(localized: "scraper_qq_desc")
        case .source_a: String(localized: "scraper_source_a_desc")
        case .musicBrainz: String(localized: "scraper_musicbrainz_desc")
        case .lrclib: String(localized: "scraper_lrclib_desc")
        }
    }

    var supportsMetadata: Bool {
        switch self {
        case .lrclib: false
        default: true
        }
    }

    var supportsCover: Bool {
        switch self {
        case .lrclib: false
        default: true
        }
    }

    var supportsLyrics: Bool {
        switch self {
        case .musicBrainz: false
        default: true
        }
    }

    var supportsCookie: Bool {
        switch self {
        case .source_a, .source_c: true
        default: false
        }
    }

    var defaultEnabled: Bool {
        true
    }

    var defaultRequestInterval: Duration {
        switch self {
        case .musicBrainz, .source_a: .seconds(1)
        case .source_c: .milliseconds(500)
        case .source_b, .source_e, .source_d: .milliseconds(300)
        case .lrclib: .milliseconds(200)
        }
    }

    /// Default priority order (lower = higher priority)
    static var defaultOrder: [MusicScraperType] {
        [.source_b, .source_e, .source_d, .source_c, .source_a, .musicBrainz, .lrclib]
    }
}

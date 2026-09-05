import Foundation
import PrimuseKit

enum SettingsStrings {
    static func text(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: "SettingsSearch")
    }
}

enum SettingsCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case library, playback, appearance, sync, integrations, appleTV, security, about
    var id: String { rawValue }

    var title: String { Bundle.main.localizedString(forKey: titleKey, value: titleKey, table: nil) }
    var titleKey: String {
        switch self {
        case .library: "library"
        case .playback: "playback"
        case .appearance: "appearance"
        case .sync: "sync"
        case .integrations: "services_integrations"
        case .appleTV: "settings_appletv_section"
        case .security: "security"
        case .about: "about"
        }
    }
    var icon: String {
        switch self {
        case .playback: "waveform"
        case .appearance: "paintpalette"
        case .library: "books.vertical"
        case .sync: "arrow.triangle.2.circlepath"
        case .integrations: "sparkles"
        case .appleTV: "appletv"
        case .security: "lock.shield"
        case .about: "info.circle"
        }
    }
}

enum SettingsPage: String, CaseIterable, Identifiable, Hashable, Sendable {
    case playback, equalizer, effects, lyrics, transcription
    case appearance, themeColor, player, fullscreen, appIcon, home, libraryDisplay
    case sources, scraping, artists, duplicates, deleted, storage
    case cacheSync, cloud, family, appleTV, relay, dlna
    case intelligence, appleMusic, scrobble, statistics, siri
    case domains, about, diagnostics, licenses, keyboard, widgets

    var id: String { "page." + rawValue }
    var category: SettingsCategory {
        switch self {
        case .playback, .equalizer, .effects, .keyboard, .siri: .playback
        case .lyrics, .transcription, .sources, .scraping, .artists, .duplicates, .deleted, .storage, .cacheSync: .library
        case .appearance, .themeColor, .player, .fullscreen, .appIcon, .home, .libraryDisplay, .widgets: .appearance
        case .cloud, .family: .sync
        case .appleTV, .relay: .appleTV
        case .intelligence, .appleMusic, .scrobble, .statistics, .dlna: .integrations
        case .domains: .security
        case .about, .diagnostics, .licenses: .about
        }
    }
    var titleKey: String {
        switch self {
        case .playback: "playback_settings"
        case .equalizer: "equalizer"
        case .effects: "audio_effects"
        case .lyrics: "lyrics_settings_title"
        case .transcription: "lyrics_transcription_settings_title"
        case .appearance: "appearance"
        case .themeColor: "theme_color_title"
        case .player: "player_appearance_title"
        case .fullscreen: "fullscreen_effect_settings_title"
        case .appIcon: "app_icon"
        case .home: "home_settings_title"
        case .libraryDisplay: "library_display_settings_title"
        case .sources: "manage_sources"
        case .scraping: "metadata_scraping"
        case .artists: "artist_name_settings_title"
        case .duplicates: "dup_title"
        case .deleted: "recently_deleted"
        case .storage: "storage_management"
        case .cacheSync: "cache_sync_title"
        case .cloud: "icloud_sync_title"
        case .family: "family_sharing_title"
        case .appleTV: "settings_appletv_section"
        case .relay: "settings_relay_section"
        case .dlna: "settings_dlna_section"
        case .intelligence: "ai_settings_title"
        case .appleMusic: "settings_apple_music_section"
        case .scrobble: "scrobble_title"
        case .statistics: "stats_title"
        case .siri: "Siri & Shortcuts"
        case .domains: "trusted_domains"
        case .about: "about"
        case .diagnostics: "diagnostics_title"
        case .licenses: "licenses"
        case .keyboard: "keyboard_shortcuts_title"
        case .widgets: "Widgets"
        }
    }
    var title: String {
        if self == .siri { return SettingsStrings.text(titleKey) }
        return Bundle.main.localizedString(forKey: titleKey, value: titleKey, table: self == .cacheSync ? "CacheSync" : nil)
    }
    var available: Bool {
        #if os(macOS)
        return [.playback, .equalizer, .effects, .lyrics, .transcription, .appearance, .scraping, .artists,
                .deleted, .storage, .cacheSync, .cloud, .intelligence, .appleMusic, .domains, .about, .keyboard, .widgets, .siri].contains(self)
        #else
        return self != .keyboard && self != .widgets
        #endif
    }
}

struct SettingDefinition: Identifiable, Hashable, Sendable {
    let id: String
    let titleKey: String
    var table: String? = nil
    let iosPage: SettingsPage?
    let macPage: SettingsPage?
    var keywords: [String] = []
    var anchor: String? = nil
    var macAnchor: String? = nil
    var usesKitLocalization = false
    var hint: String? = nil

    var page: SettingsPage? {
        #if os(macOS)
        macPage
        #else
        iosPage
        #endif
    }
    var title: String {
        let text = usesKitLocalization ? PMString(titleKey)
            : Bundle.main.localizedString(forKey: titleKey, value: titleKey, table: table)
        return text
    }
    var isPage: Bool { id.hasPrefix("page.") }
    var anchorID: String {
        #if os(macOS)
        macAnchor ?? anchor ?? id
        #else
        anchor ?? id
        #endif
    }
    var path: String {
        guard let page else { return "" }
        if page == .cacheSync {
            #if os(macOS)
            let parent = String(localized: "mac_sidebar_tools")
            #else
            let parent = SettingsPage.storage.title
            #endif
            return isPage ? parent : parent + " › " + page.title
        }
        #if os(macOS)
        return isPage ? String(localized: "settings_title") : page.title
        #else
        if page == .about || page == .appleTV { return page.category.title }
        return isPage ? page.category.title : page.category.title + " › " + page.title
        #endif
    }
}

enum SettingsCatalog {
    static let definitions: [SettingDefinition] = SettingsPage.allCases.map { page in
        SettingDefinition(
            id: page.id, titleKey: page.titleKey,
            table: page == .cacheSync ? "CacheSync" : (page == .siri ? "SettingsSearch" : nil),
            iosPage: page, macPage: page,
            keywords: [page.rawValue]
        )
    } + SettingsCatalogData.items

    static let available: [SettingDefinition] = definitions.filter { $0.page?.available == true }
    static let byID: [String: SettingDefinition] = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
    static let index = SettingsSearchIndex(documents: available.map {
        SettingsSearchDocument(id: $0.id, title: $0.title, path: $0.path,
                               keywords: $0.keywords + $0.keywords.map { Bundle.main.localizedString(forKey: $0, value: $0, table: nil) },
                               isPage: $0.isPage)
    })

    static func search(_ text: String, showsIntelligence: Bool = true) -> [SettingDefinition] {
        index.search(text).compactMap { byID[$0] }.filter { showsIntelligence || $0.page != .intelligence }
    }

}

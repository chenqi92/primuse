import Foundation
import PrimuseKit

enum SettingsStrings {
    static func text(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: "SettingsSearch")
    }
}

enum SettingsCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case library, playback, appearance, sync, integrations, security, about
    var id: String { rawValue }

    var title: String { Bundle.main.localizedString(forKey: titleKey, value: titleKey, table: nil) }
    var titleKey: String {
        switch self {
        case .library: "library"
        case .playback: "playback"
        case .appearance: "appearance"
        case .sync: "sync"
        case .integrations: "services_integrations"
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
        case .security: "lock.shield"
        case .about: "info.circle"
        }
    }
}

enum SettingsPage: String, CaseIterable, Identifiable, Hashable, Sendable {
    case playback, equalizer, effects, lyrics, transcription
    case appearance, themeColor, player, fullscreen, appIcon, home, libraryDisplay
    case interfaceEditor
    case sources, scraping, artists, duplicates, deleted, storage
    case cacheSync, cloud, family, appleTV, relay, dlna
    case intelligence, appleMusic, scrobble, statistics, siri, carplay
    case domains, about, diagnostics, licenses, keyboard, widgets

    var id: String { "page." + rawValue }
    var category: SettingsCategory {
        switch self {
        // 歌词的来源、翻译、转写、外观本就是同一件事，合成一页挂在播放下面；
        // 在根菜单里拆成并列的几项，反而要来回找。
        case .playback, .equalizer, .effects, .lyrics, .transcription,
             .keyboard, .siri, .carplay: .playback
        case .sources, .scraping, .artists, .duplicates, .deleted, .storage, .cacheSync,
             .statistics: .library
        case .appearance, .themeColor, .player, .fullscreen, .appIcon, .home, .libraryDisplay,
             .interfaceEditor, .widgets: .appearance
        case .cloud, .family: .sync
        // Apple TV 与投放本就是对外连接的一种，不值得单开一个只有两项的分类。
        case .intelligence, .appleMusic, .scrobble, .dlna, .appleTV, .relay: .integrations
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
        case .interfaceEditor: "interface_editor_title"
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
        case .carplay: "CarPlay"
        case .domains: "trusted_domains"
        case .about: "about"
        case .diagnostics: "diagnostics_title"
        case .licenses: "licenses"
        case .keyboard: "keyboard_shortcuts_title"
        case .widgets: "Widgets"
        }
    }

    /// 列表行的符号。此前每一行在 iOS 设置页里各写各的，页面与图标的对应关系
    /// 散落在视图里，分组一改就得逐行跟着搬。
    var icon: String {
        switch self {
        case .playback: "play.circle"
        case .equalizer: "slider.horizontal.3"
        case .effects: "waveform.badge.plus"
        case .lyrics: "character.bubble"
        case .transcription: "waveform.and.person.filled"
        case .appearance: "circle.lefthalf.filled"
        case .themeColor: "paintpalette"
        case .player: "play.rectangle"
        case .fullscreen: "viewfinder.rectangular"
        case .appIcon: "app.badge"
        case .home: "house"
        case .interfaceEditor: "slider.horizontal.below.rectangle"
        case .libraryDisplay: "rectangle.grid.1x2"
        case .sources: "externaldrive.connected.to.line.below"
        case .scraping: "wand.and.stars"
        case .artists: "person.2"
        case .duplicates: "square.stack.3d.up.badge.automatic"
        case .deleted: "trash"
        case .storage: "internaldrive"
        case .cacheSync: "arrow.triangle.2.circlepath"
        case .cloud: "icloud"
        case .family: "person.2.fill"
        case .appleTV: "appletv"
        case .relay: "arrow.up.forward.app"
        case .dlna: "antenna.radiowaves.left.and.right"
        case .intelligence: "sparkles"
        case .appleMusic: "applelogo"
        case .scrobble: "music.note.list"
        case .statistics: "chart.bar.xaxis"
        case .siri: "waveform"
        case .carplay: "car"
        case .domains: "lock.shield"
        case .about: "info.circle"
        case .diagnostics: "stethoscope"
        case .licenses: "doc.text"
        case .keyboard: "keyboard"
        case .widgets: "rectangle.grid.2x2"
        }
    }
    var title: String {
        if self == .siri { return SettingsStrings.text(titleKey) }
        return Bundle.main.localizedString(forKey: titleKey, value: titleKey, table: self == .cacheSync ? "CacheSync" : nil)
    }
    /// 是否在设置根列表里单独占一行。
    ///
    /// 缓存同步就是「存储」页开着同步面板的同一个视图，转写是「歌词」页里的一个
    /// 入口 —— 它们在根菜单里再列一遍，只会让人以为是别的东西。两者仍是有效的
    /// 跳转目标，设置搜索直接命中。
    var isListed: Bool {
        // 首页的顺序、显隐、排布与条目数已经全部收进「界面编辑」，在那里改能
        // 当场看到效果；再留一个抽象的开关列表只会分叉成两个入口。仍可搜索到。
        ![.cacheSync, .transcription, .home].contains(self)
    }

    var available: Bool {
        #if os(macOS)
        return [.playback, .equalizer, .effects, .lyrics, .transcription,
                .appearance, .scraping, .artists,
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

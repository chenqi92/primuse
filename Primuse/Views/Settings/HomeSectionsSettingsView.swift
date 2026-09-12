import SwiftUI
import PrimuseKit

/// 分区标题要走 SwiftUI 的本地化键,而枚举本身存在 Kit 里(顺序与方案都按
/// rawValue 存盘),所以标题留在 app 侧作为扩展。
extension HomeSectionKind {
    var title: LocalizedStringKey {
        switch self {
        case .continueListening: return "home_section_continue_listening"
        case .radio: return "radio_title"
        case .quickAccess: return "home_section_quick_access"
        case .forYou: return "home_section_for_you"
        case .playlists: return "home_section_playlists"
        case .folders: return LocalizedStringKey(HomeDiscoveryText.string("folders"))
        case .listeningRanking: return LocalizedStringKey(HomeDiscoveryText.string("ranking"))
        case .topArtists: return "home_section_top_artists"
        case .recentlyAdded: return LocalizedStringKey(HomeDiscoveryText.string("recent_albums"))
        case .stats: return "stats_title"
        }
    }
}

enum HomeSectionConfiguration {
    static let orderKey = "primuse.home.sectionOrder.v1"
    static let defaultOrder: [HomeSectionKind] = [
        .continueListening,
        .radio,
        .quickAccess,
        .folders,
        .listeningRanking,
        .forYou,
        .playlists,
        .topArtists,
        .recentlyAdded,
        .stats,
    ]

    static func decode(_ rawValue: String) -> [HomeSectionKind] {
        let stored: [HomeSectionKind]
        if let data = rawValue.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([HomeSectionKind].self, from: data) {
            stored = decoded
        } else {
            stored = []
        }

        var seen = Set<HomeSectionKind>()
        var known = stored.filter { seen.insert($0).inserted }
        if !known.isEmpty {
            // Keep existing sections in the user's order while introducing
            // the two related modules together beside their library shortcuts.
            if seen.insert(.folders).inserted {
                let anchor = known.firstIndex(of: .playlists) ?? known.firstIndex(of: .quickAccess)
                known.insert(.folders, at: anchor.map { $0 + 1 } ?? 0)
            }
            if seen.insert(.listeningRanking).inserted {
                known.insert(.listeningRanking, at: (known.firstIndex(of: .folders) ?? 0) + 1)
            }
        }
        let missing = defaultOrder.filter { seen.insert($0).inserted }
        return known + missing
    }

    static func encode(_ sections: [HomeSectionKind]) -> String {
        guard let data = try? JSONEncoder().encode(sections) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

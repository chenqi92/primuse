import Foundation

/// Apple TV 资料库页顶部筛选条上的一项。
///
/// 显隐按 rawValue 存盘,case 名发布后不能改。
public enum TVLibraryFilter: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case albums, songs, artists, genres, folders
    /// 按年份分段的专辑墙。
    case years
    case recommendations, ranking

    public var id: String { rawValue }

    /// 能在设置里关掉的项。藏品本身(专辑、歌曲、艺人、流派、文件夹)一直在。
    public var isOptional: Bool {
        switch self {
        case .years, .recommendations, .ranking: true
        case .albums, .songs, .artists, .genres, .folders: false
        }
    }
}

/// 电视资料库筛选条的显隐。推荐与排行在电视首页已经有自己的位置,资料库里默认收起来,
/// 想要的人在设置 › 顶栏菜单里打开。存成 JSON 字符串;没改过(或改回默认)时存空串。
public struct TVLibraryFilterConfiguration: Equatable, Sendable {
    public static let storageKey = "primuse.tv.libraryFilters.v1"
    public static let defaultHidden: Set<TVLibraryFilter> = [.recommendations, .ranking]
    public static let `default` = TVLibraryFilterConfiguration(hidden: defaultHidden)

    public private(set) var hidden: Set<TVLibraryFilter>

    public init(hidden: Set<TVLibraryFilter>) {
        self.hidden = hidden.filter(\.isOptional)
    }

    public static func decode(_ rawValue: String) -> TVLibraryFilterConfiguration {
        guard !rawValue.isEmpty,
              let data = rawValue.data(using: .utf8),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return .default
        }
        // 按字符串解:以后删掉的项、更新的版本写进来的新项都只丢那一项。
        return TVLibraryFilterConfiguration(
            hidden: Set(stored.hidden.compactMap(TVLibraryFilter.init(rawValue:)))
        )
    }

    public func encoded() -> String {
        guard self != .default else { return "" }
        let stored = Stored(hidden: TVLibraryFilter.allCases.filter(hidden.contains).map(\.rawValue))
        guard let data = try? JSONEncoder().encode(stored) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private struct Stored: Codable {
        var hidden: [String]
    }

    public func isShown(_ filter: TVLibraryFilter) -> Bool { !hidden.contains(filter) }

    /// 筛选条上出现的项,按固定顺序。
    public var visibleFilters: [TVLibraryFilter] { TVLibraryFilter.allCases.filter(isShown) }

    /// 当前选中的项被关掉了就回到专辑墙。
    public func resolved(_ filter: TVLibraryFilter) -> TVLibraryFilter {
        isShown(filter) ? filter : .albums
    }

    public mutating func setShown(_ shown: Bool, for filter: TVLibraryFilter) {
        guard filter.isOptional else { return }
        if shown {
            hidden.remove(filter)
        } else {
            hidden.insert(filter)
        }
    }
}

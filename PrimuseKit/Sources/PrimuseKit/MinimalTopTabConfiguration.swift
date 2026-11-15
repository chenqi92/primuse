import Foundation

/// 极简模式顶栏上的去处。音乐、电台、有声落在资料库的分类页上，首页就是首页标签。
/// 存的是 rawValue，case 名不能改。
public enum MinimalTopTab: String, CaseIterable, Identifiable, Hashable, Sendable {
    case home
    case music
    case radio
    case spoken

    public var id: String { rawValue }

    /// 落在资料库槽位里的几格（首页以外的都是）。
    public var isLibraryTab: Bool { self != .home }
}

/// 极简模式顶栏几格的顺序与开关（外观设置、首页编辑里的「顶部切换」）。
///
/// 和经典模式首页顶上那排胶囊（`HomeFilterBarConfiguration`）各存各的：那边是首页里的筛选，
/// 这里是整个 App 的去处。关掉一格只是顶栏上不摆它，那几页照样能从深链、搜索结果进去。
/// 打开的一格还要有内容才出现（电台要资料库里开着，有声要有有声书或播客），由调用方给 `isAvailable`。
public struct MinimalTopTabConfiguration: Equatable, Sendable {
    public static let storageKey = "primuse.minimal.topTabs.v1"
    /// 老版本外观设置里的「显示首页」。没调过顶部切换时首页那一格照它，调过之后不再读。
    public static let legacyShowsHomeKey = "primuse.minimal.showsHome.v1"

    public static let defaultOrder: [MinimalTopTab] = [.home, .music, .radio, .spoken]

    /// 顶栏上一格都摆不出来时（别的设备同步来的设置、打开的那格没了内容）摆它：音乐总有页可落。
    public static let fallbackTab: MinimalTopTab = .music

    /// 全部的格，按用户排的顺序（含关掉的）。
    public private(set) var order: [MinimalTopTab]
    /// 关掉的格。
    public private(set) var hidden: Set<MinimalTopTab>

    public init(order: [MinimalTopTab] = defaultOrder, hidden: Set<MinimalTopTab> = []) {
        self.order = Self.completedOrder(order)
        self.hidden = hidden
    }

    // MARK: 存取

    /// 没调过（空串）或读不出来：默认顺序、全部打开，只有首页那一格照老的「显示首页」。
    public static func decode(_ rawValue: String, legacyShowsHome: Bool = true) -> MinimalTopTabConfiguration {
        guard !rawValue.isEmpty,
              let data = rawValue.data(using: .utf8),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return MinimalTopTabConfiguration(hidden: legacyShowsHome ? [] : [.home])
        }
        return MinimalTopTabConfiguration(
            order: stored.order.compactMap(MinimalTopTab.init(rawValue:)),
            hidden: Set((stored.hidden ?? []).compactMap(MinimalTopTab.init(rawValue:)))
        )
    }

    /// 调过一次就整份写下来（连同首页那一格），往后不再读老的「显示首页」。
    public func encoded() -> String {
        let stored = Stored(
            order: order.map(\.rawValue),
            hidden: order.filter { hidden.contains($0) }.map(\.rawValue)
        )
        guard let data = try? JSONEncoder().encode(stored) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private struct Stored: Codable {
        var order: [String]
        var hidden: [String]?
    }

    // MARK: 查询

    public func isShown(_ tab: MinimalTopTab) -> Bool {
        !hidden.contains(tab)
    }

    /// 顶栏上真正摆出来的格：打开的、且有内容的，按用户排的顺序。一格都不剩时摆 `fallbackTab`。
    public func visibleTabs(isAvailable: (MinimalTopTab) -> Bool) -> [MinimalTopTab] {
        let tabs = order.filter { isShown($0) && isAvailable($0) }
        return tabs.isEmpty ? [Self.fallbackTab] : tabs
    }

    /// 这一格能不能关：关了以后顶栏上还得剩下至少一格自己打开的。没内容的格（反正不出现）随时能关。
    public func canHide(_ tab: MinimalTopTab, isAvailable: (MinimalTopTab) -> Bool) -> Bool {
        guard isShown(tab), isAvailable(tab) else { return true }
        return order.contains { $0 != tab && isShown($0) && isAvailable($0) }
    }

    // MARK: 修改

    public mutating func setShown(_ shown: Bool, for tab: MinimalTopTab) {
        if shown {
            hidden.remove(tab)
        } else {
            hidden.insert(tab)
        }
    }

    /// 列表拖动排序（`onMove`）的偏移。
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().compactMap { order.indices.contains($0) ? order[$0] : nil }
        guard !moving.isEmpty else { return }
        let before = order[..<min(max(destination, 0), order.count)].filter { !moving.contains($0) }.count
        var remaining = order.filter { !moving.contains($0) }
        remaining.insert(contentsOf: moving, at: before)
        order = remaining
    }

    // MARK: 归一

    /// 去重，再把存盘里没有的格（新版本加的）插回默认顺序里它前一个邻居的后面。
    private static func completedOrder(_ stored: [MinimalTopTab]) -> [MinimalTopTab] {
        var seen = Set<MinimalTopTab>()
        var order = stored.filter { seen.insert($0).inserted }
        for (defaultIndex, tab) in defaultOrder.enumerated() where !seen.contains(tab) {
            let anchor = defaultOrder[..<defaultIndex].reversed().first { seen.contains($0) }
            let insertAt = anchor.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            order.insert(tab, at: insertAt)
            seen.insert(tab)
        }
        return order
    }
}

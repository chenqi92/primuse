import Foundation

/// Apple TV 顶栏上的一级页。
///
/// 顺序与显隐按 rawValue 存盘,所以 case 名一旦发布就不能改:读回来认不出的
/// 名字会被丢掉,而不是让整份配置解不出来退回默认。设置不在这里 —— 它是顶栏
/// 右上角的独立按钮,永远在,用户不会把自己关在设置外面。
public enum TVTabBarItem: String, CaseIterable, Codable, Hashable, Sendable {
    case home
    case library
    case radio
    case spokenWord
    case nowPlaying
    case playlists
    case sources
    case search

    /// 电台没有台、有声没有内容时,这一页本来就不出现
    /// (`ListeningSpaceVisibilityPolicy`)。用户打开了它也不一定看得到。
    public var dependsOnContent: Bool {
        switch self {
        case .radio, .spokenWord: true
        default: false
        }
    }
}

/// 电视顶栏的顺序与显隐。整份存成一个 JSON 字符串;没改过(或恢复默认)时存空串。
public struct TVTabBarConfiguration: Equatable, Sendable {
    public static let storageKey = "primuse.tv.tabBar.v1"

    /// 与 iPhone / iPad / Mac 一致:首页、音乐、电台、有声,再是电视端自己的几页。
    public static let defaultOrder: [TVTabBarItem] = [
        .home, .library, .radio, .spokenWord, .nowPlaying, .playlists, .sources, .search,
    ]

    public static let `default` = TVTabBarConfiguration(order: defaultOrder, hidden: [])

    /// 全部页面,按用户排的顺序(含被隐藏的)。
    public private(set) var order: [TVTabBarItem]
    public private(set) var hidden: Set<TVTabBarItem>

    public init(order: [TVTabBarItem], hidden: Set<TVTabBarItem>) {
        self.order = Self.completedOrder(order)
        self.hidden = hidden
        ensureReachablePage()
    }

    // MARK: 存取

    public static func decode(_ rawValue: String) -> TVTabBarConfiguration {
        guard !rawValue.isEmpty,
              let data = rawValue.data(using: .utf8),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return .default
        }
        // 按字符串解:以后删掉的页面、别的版本写进来的新页面都只丢那一项。
        let order = stored.order.compactMap(TVTabBarItem.init(rawValue:))
        let hidden = Set(stored.hidden.compactMap(TVTabBarItem.init(rawValue:)))
        return TVTabBarConfiguration(order: order, hidden: hidden)
    }

    /// 默认配置编成空串:「恢复默认」之后以后版本改默认顺序也能跟上。
    public func encoded() -> String {
        guard !isDefault else { return "" }
        let stored = Stored(
            order: order.map(\.rawValue),
            hidden: order.filter { hidden.contains($0) }.map(\.rawValue)
        )
        guard let data = try? JSONEncoder().encode(stored) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public var isDefault: Bool { self == .default }

    private struct Stored: Codable {
        var order: [String]
        var hidden: [String]
    }

    // MARK: 查询

    public func isShown(_ item: TVTabBarItem) -> Bool { !hidden.contains(item) }

    /// 顶栏上真正出现的页:用户打开的、且当下有内容可看的。
    /// 永远至少有一页(不依赖内容的页至少留一个打开,见 `canHide`)。
    public func visibleItems(isAvailable: (TVTabBarItem) -> Bool) -> [TVTabBarItem] {
        let items = order.filter { isShown($0) && isAvailable($0) }
        if !items.isEmpty { return items }
        // 只有存盘被写坏才会走到这里;宁可多出一页也不能让顶栏空掉。
        return [order.first { !$0.dependsOnContent } ?? .library]
    }

    /// 能不能关掉这一页。不依赖内容的页至少要留一个打开:否则电台删空、有声没内容时
    /// 顶栏上就只剩设置按钮了。
    public func canHide(_ item: TVTabBarItem) -> Bool {
        guard isShown(item) else { return false }
        guard !item.dependsOnContent else { return true }
        return order.contains { $0 != item && !$0.dependsOnContent && isShown($0) }
    }

    public func canMove(_ item: TVTabBarItem, by offset: Int) -> Bool {
        guard let index = order.firstIndex(of: item) else { return false }
        return order.indices.contains(index + offset) && offset != 0
    }

    // MARK: 修改

    /// 打开或关掉一页。关不掉(最后一个不依赖内容的页)时返回 false、不改。
    @discardableResult
    public mutating func setShown(_ shown: Bool, for item: TVTabBarItem) -> Bool {
        if shown {
            hidden.remove(item)
            return true
        }
        guard canHide(item) else { return false }
        hidden.insert(item)
        return true
    }

    /// 往前(负数)或往后(正数)挪几格;挪出边界时夹在首尾。
    public mutating func move(_ item: TVTabBarItem, by offset: Int) {
        guard let index = order.firstIndex(of: item) else { return }
        let target = min(max(index + offset, 0), order.count - 1)
        guard target != index else { return }
        order.remove(at: index)
        order.insert(item, at: target)
    }

    // MARK: 归一

    /// 去重,再把存盘里没有的页(新版本加的)插回默认顺序里它前一个邻居的后面。
    private static func completedOrder(_ stored: [TVTabBarItem]) -> [TVTabBarItem] {
        var seen = Set<TVTabBarItem>()
        var order = stored.filter { seen.insert($0).inserted }
        for (defaultIndex, item) in defaultOrder.enumerated() where !seen.contains(item) {
            let anchor = defaultOrder[..<defaultIndex].reversed().first { seen.contains($0) }
            let insertAt = anchor.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            order.insert(item, at: insertAt)
            seen.insert(item)
        }
        return order
    }

    private mutating func ensureReachablePage() {
        guard !order.contains(where: { !$0.dependsOnContent && isShown($0) }),
              let first = order.first(where: { !$0.dependsOnContent }) else { return }
        hidden.remove(first)
    }
}

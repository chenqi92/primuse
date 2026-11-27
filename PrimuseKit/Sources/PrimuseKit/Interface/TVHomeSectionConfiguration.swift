import Foundation

/// Apple TV 首页上的一排。
///
/// 顺序与显隐按 rawValue 存盘,所以 case 名一旦发布就不能改:读回来认不出的
/// 名字会被丢掉,而不是让整份配置解不出来退回默认。
public enum TVHomeSection: String, CaseIterable, Codable, Hashable, Sendable {
    /// 「今晚听」:按此刻情景挑的一整张专辑,带全部播放 / 随机 / 串烧。
    case albumPick
    /// 「居家场景」:会客、休闲、夜间聆听、专注、派对。
    case homeScenes
    /// 场景推荐(没开智能服务时是「为你推荐」)。
    case recommendations
    /// 最近播放;还没播过时是曲库里的前几首。
    case recentlyPlayed
    case likedAlbums
    case recentlyAdded
    /// 电台;末尾的卡片是电视端添加电台的入口。
    case radio
}

/// 电视首页各排的顺序与显隐。整份存成一个 JSON 字符串;没改过(或恢复默认)时存空串。
public struct TVHomeSectionConfiguration: Equatable, Sendable {
    public static let storageKey = "primuse.tv.homeSections.v1"

    /// 主视觉的情景推荐专辑在最上面,居家场景紧跟在它下面。
    public static let defaultOrder: [TVHomeSection] = [
        .albumPick, .homeScenes, .recommendations, .recentlyPlayed, .likedAlbums, .recentlyAdded, .radio,
    ]

    public static let `default` = TVHomeSectionConfiguration(order: defaultOrder, hidden: [])

    /// 全部排,按用户排的顺序(含被隐藏的)。
    public private(set) var order: [TVHomeSection]
    public private(set) var hidden: Set<TVHomeSection>

    public init(order: [TVHomeSection], hidden: Set<TVHomeSection>) {
        self.order = Self.completedOrder(order)
        self.hidden = hidden
        if self.order.allSatisfy({ hidden.contains($0) }), let first = self.order.first {
            // 只有存盘被写坏才会全关:宁可多出一排也不能让首页空掉。
            self.hidden.remove(first)
        }
    }

    // MARK: 存取

    public static func decode(_ rawValue: String) -> TVHomeSectionConfiguration {
        guard !rawValue.isEmpty,
              let data = rawValue.data(using: .utf8),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return .default
        }
        // 按字符串解:以后删掉的排、别的版本写进来的新排都只丢那一项。
        return TVHomeSectionConfiguration(
            order: stored.order.compactMap(TVHomeSection.init(rawValue:)),
            hidden: Set(stored.hidden.compactMap(TVHomeSection.init(rawValue:)))
        )
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

    public func isShown(_ section: TVHomeSection) -> Bool { !hidden.contains(section) }

    /// 首页要画的排,按顺序。某一排此刻有没有内容由首页自己判断。
    public var visibleSections: [TVHomeSection] { order.filter(isShown) }

    /// 至少留一排打开。
    public func canHide(_ section: TVHomeSection) -> Bool {
        isShown(section) && order.contains { $0 != section && isShown($0) }
    }

    public func canMove(_ section: TVHomeSection, by offset: Int) -> Bool {
        guard let index = order.firstIndex(of: section) else { return false }
        return order.indices.contains(index + offset) && offset != 0
    }

    // MARK: 修改

    /// 打开或关掉一排。关不掉(最后一排)时返回 false、不改。
    @discardableResult
    public mutating func setShown(_ shown: Bool, for section: TVHomeSection) -> Bool {
        if shown {
            hidden.remove(section)
            return true
        }
        guard canHide(section) else { return false }
        hidden.insert(section)
        return true
    }

    /// 往前(负数)或往后(正数)挪几格;挪出边界时夹在首尾。
    public mutating func move(_ section: TVHomeSection, by offset: Int) {
        guard let index = order.firstIndex(of: section) else { return }
        let target = min(max(index + offset, 0), order.count - 1)
        guard target != index else { return }
        order.remove(at: index)
        order.insert(section, at: target)
    }

    // MARK: 归一

    /// 去重,再把存盘里没有的排(新版本加的)插回默认顺序里它前一个邻居的后面。
    private static func completedOrder(_ stored: [TVHomeSection]) -> [TVHomeSection] {
        var seen = Set<TVHomeSection>()
        var order = stored.filter { seen.insert($0).inserted }
        for (defaultIndex, section) in defaultOrder.enumerated() where !seen.contains(section) {
            let anchor = defaultOrder[..<defaultIndex].reversed().first { seen.contains($0) }
            let insertAt = anchor.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            order.insert(section, at: insertAt)
            seen.insert(section)
        }
        return order
    }
}

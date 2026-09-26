import Foundation

/// 首页「电台」「有声书」两块各自展示哪些条目、按什么顺序。
///
/// 资料库里的电台和书可能上千,首页一排只放得下十来个,所以让用户自己挑:
/// 没挑过(`pinnedIDs` 为空)时自动取;挑过之后首页只放挑中的那些。
/// 挑中与否由列表是否为空决定,不另存一个「模式」开关 —— 两份状态对不上时
/// 用户看到的是「设了自动却只出来两个」这种说不清的结果。
public struct HomeSpotlightSelection: Codable, Equatable, Sendable {
    public enum Order: String, Codable, CaseIterable, Identifiable, Sendable {
        /// 最近收听的在前,没听过的按资料库顺序(挑过时按挑选顺序)补在后面。
        case recent
        /// 自动时是资料库里的顺序(电台的置顶/优先级);挑过时是用户拖出来的顺序。
        case custom
        /// 按名称。
        case name

        public var id: String { rawValue }
        public var titleKey: String { "home_spotlight_order_" + rawValue }
        public var icon: String {
            switch self {
            case .recent: "clock.arrow.circlepath"
            case .custom: "line.3.horizontal"
            case .name: "textformat"
            }
        }
    }

    public static let radioStorageKey = "primuse.home.radioSpotlight.v1"
    public static let booksStorageKey = "primuse.home.bookSpotlight.v1"

    public var order: Order
    public var pinnedIDs: [String]

    public init(order: Order = .recent, pinnedIDs: [String] = []) {
        self.order = order
        self.pinnedIDs = pinnedIDs
    }

    public var isAutomatic: Bool { pinnedIDs.isEmpty }

    public func isPinned(_ id: String) -> Bool { pinnedIDs.contains(id) }

    /// 挑中的放到末尾;已挑中的再点一次就是取消。
    public mutating func togglePin(_ id: String) {
        if let index = pinnedIDs.firstIndex(of: id) {
            pinnedIDs.remove(at: index)
        } else {
            pinnedIDs.append(id)
        }
    }

    public mutating func movePinned(fromOffsets source: IndexSet, toOffset destination: Int) {
        // 与 Array.move(fromOffsets:toOffset:) 语义一致,Kit 里不引 SwiftUI。
        let moving = source.sorted().map { pinnedIDs[$0] }
        let insertion = destination - source.filter { $0 < destination }.count
        var remaining = pinnedIDs
        for index in source.sorted(by: >) { remaining.remove(at: index) }
        remaining.insert(contentsOf: moving, at: min(max(insertion, 0), remaining.count))
        pinnedIDs = remaining
    }

    /// 把已经不存在的条目从挑选里清掉。只在管理页里调用 —— 首页渲染时
    /// 资料库可能还没装载完,那时清会把整份挑选误删。
    public mutating func prune(keeping existingIDs: Set<String>) {
        pinnedIDs.removeAll { !existingIDs.contains($0) }
    }

    /// 首页这一排实际放哪些、什么顺序。
    ///
    /// - Parameters:
    ///   - items: 资料库里的全部条目,按资料库自己的顺序。
    ///   - limit: 最多放几个。
    public func resolve<Item>(
        _ items: [Item],
        limit: Int,
        id: (Item) -> String,
        name: (Item) -> String,
        lastListenedAt: (Item) -> Date?
    ) -> [Item] {
        guard limit > 0 else { return [] }
        let base: [Item]
        if isAutomatic {
            base = items
        } else {
            var byID: [String: Item] = [:]
            for item in items where byID[id(item)] == nil { byID[id(item)] = item }
            base = pinnedIDs.compactMap { byID[$0] }
        }
        let indexed = Array(base.enumerated())
        let sorted: [(offset: Int, element: Item)]
        switch order {
        case .custom:
            sorted = indexed
        case .name:
            sorted = indexed.sorted { lhs, rhs in
                let comparison = name(lhs.element).localizedStandardCompare(name(rhs.element))
                return comparison == .orderedSame ? lhs.offset < rhs.offset : comparison == .orderedAscending
            }
        case .recent:
            // 听过的按时间倒序在前,没听过的保持原顺序在后。
            sorted = indexed.sorted { lhs, rhs in
                switch (lastListenedAt(lhs.element), lastListenedAt(rhs.element)) {
                case let (l?, r?): return l != r ? l > r : lhs.offset < rhs.offset
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return lhs.offset < rhs.offset
                }
            }
        }
        return Array(sorted.prefix(limit).map(\.element))
    }

    public static func decode(_ rawValue: String) -> Self {
        guard let data = rawValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else {
            return Self()
        }
        return decoded
    }

    public func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private enum CodingKeys: String, CodingKey { case order, pinnedIDs }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 以后删掉某种排序时退回默认,而不是整份挑选作废。
        let rawOrder = try container.decodeIfPresent(String.self, forKey: .order)
        order = rawOrder.flatMap(Order.init(rawValue:)) ?? .recent
        var seen = Set<String>()
        pinnedIDs = (try container.decodeIfPresent([String].self, forKey: .pinnedIDs) ?? [])
            .filter { seen.insert($0).inserted }
    }
}

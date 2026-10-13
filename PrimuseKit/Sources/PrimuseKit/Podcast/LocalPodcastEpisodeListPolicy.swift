import Foundation

/// 自己的文件标成播客后,一档「本地节目」里各集怎么排。
public enum LocalPodcastEpisodeOrder: String, CaseIterable, Codable, Sendable {
    /// 按日期从新到旧:新放进来的文件排在最上面。默认。
    case newestFirst
    /// 按日期从旧到新。
    case oldestFirst
    /// 曲目号与文件名,和有声书的章节同一个顺序。
    case fileOrder
    /// 文件顺序倒过来:编号最大、文件名排在最后的在最上面。
    case fileOrderReversed
    /// 自己拖出来的顺序。之后才加进来的单集排在最上面。
    case custom

    /// 播完一集接着往哪个方向放:日期与文件顺序两组都从旧往新(和订阅节目一样),
    /// 所以新的在上、倒序时倒过来;自定义就是列表从上往下。
    /// 倒过来时「播放」键从最上面那集起,就是最新的一集。
    public var listensInReverse: Bool { self == .newestFirst || self == .fileOrderReversed }

    public var isFileOrder: Bool { self == .fileOrder || self == .fileOrderReversed }

    /// 菜单里点「按文件顺序」:已经是正序的再点一次换成倒序,倒序再点回正序;别的排法先换成正序。
    public var togglingFileOrder: LocalPodcastEpisodeOrder {
        self == .fileOrder ? .fileOrderReversed : .fileOrder
    }
}

public enum LocalPodcastEpisodeFilter: String, CaseIterable, Codable, Sendable {
    case all
    /// 还没听完的,听到一半的也算。
    case unplayed
    case played

    public func includes(_ item: SpokenWordBookItem) -> Bool {
        switch self {
        case .all: true
        case .unplayed: !item.isFinished
        case .played: item.isFinished
        }
    }
}

/// 一档本地节目在本机记住的排法与筛选。
public struct LocalPodcastShowSettings: Hashable, Sendable {
    public var order: LocalPodcastEpisodeOrder
    public var filter: LocalPodcastEpisodeFilter
    /// `custom` 用的顺序(单集 id)。换成别的排法时留着,切回来不用重新拖。
    public var customOrder: [String]

    public init(
        order: LocalPodcastEpisodeOrder = .newestFirst,
        filter: LocalPodcastEpisodeFilter = .all,
        customOrder: [String] = []
    ) {
        self.order = order
        self.filter = filter
        self.customOrder = customOrder
    }

    public static let `default` = LocalPodcastShowSettings()
}

extension LocalPodcastShowSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case order, filter, customOrder
    }

    /// 认不出的排法、筛选回到默认,不让一项读不懂把整份设置丢掉。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        order = (try? container.decodeIfPresent(String.self, forKey: .order))
            .flatMap(LocalPodcastEpisodeOrder.init(rawValue:)) ?? .newestFirst
        filter = (try? container.decodeIfPresent(String.self, forKey: .filter))
            .flatMap(LocalPodcastEpisodeFilter.init(rawValue:)) ?? .all
        customOrder = (try? container.decodeIfPresent([String].self, forKey: .customOrder)) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(order.rawValue, forKey: .order)
        try container.encode(filter.rawValue, forKey: .filter)
        if !customOrder.isEmpty {
            try container.encode(customOrder, forKey: .customOrder)
        }
    }
}

/// 本地节目的单集列表:排序、播完接着放哪几集、「播放」键从哪一集起。界面、CarPlay、电视共用。
///
/// 传进来的 `items` 一律是 `SpokenWordBookGrouping` 给的章节顺序(曲目号、文件名)。
public enum LocalPodcastEpisodeListPolicy {
    public static func ordered(
        _ items: [SpokenWordBookItem],
        settings: LocalPodcastShowSettings
    ) -> [SpokenWordBookItem] {
        switch settings.order {
        case .fileOrder:
            return items
        case .fileOrderReversed:
            return items.reversed()
        case .newestFirst:
            return byDate(items, newestFirst: true)
        case .oldestFirst:
            return byDate(items, newestFirst: false)
        case .custom:
            let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var placed = Set<String>()
            let saved = settings.customOrder.compactMap { id -> SpokenWordBookItem? in
                guard placed.insert(id).inserted else { return nil }
                return byID[id]
            }
            let added = byDate(items.filter { !placed.contains($0.id) }, newestFirst: true)
            return added + saved
        }
    }

    /// 按收听先后排的同一份列表:按日期从新到旧、文件倒序时倒过来,其余就是列表顺序。
    public static func listeningSequence(
        _ ordered: [SpokenWordBookItem],
        order: LocalPodcastEpisodeOrder
    ) -> [SpokenWordBookItem] {
        order.listensInReverse ? ordered.reversed() : ordered
    }

    /// 点了某一集:先放这一集,播完按收听先后接着放还没听完的。第一项就是点的那一集。
    public static func continuation(
        from itemID: String,
        in ordered: [SpokenWordBookItem],
        order: LocalPodcastEpisodeOrder,
        limit: Int = 200
    ) -> [SpokenWordBookItem] {
        let sequence = listeningSequence(ordered, order: order)
        guard limit > 0, let index = sequence.firstIndex(where: { $0.id == itemID }) else { return [] }
        var queue = [sequence[index]]
        for item in sequence[(index + 1)...] where queue.count < limit && !item.isFinished {
            queue.append(item)
        }
        return queue
    }

    /// 「播放」键从哪一集起:有接着听的(`book.resumeItemID` 且 `canContinue`)就是它;
    /// 否则列表里排在最前、还没听完的那集;都听完了就是第一集。
    public static func startItemID(
        in ordered: [SpokenWordBookItem],
        resumeItemID: String?,
        canContinue: Bool
    ) -> String? {
        if canContinue, let resumeItemID, ordered.contains(where: { $0.id == resumeItemID }) {
            return resumeItemID
        }
        return ordered.first { !$0.isFinished }?.id ?? ordered.first?.id
    }

    /// 「之前的都标为已播放」:按收听先后排在这一集前面、还没听完的。
    public static func earlierUnfinishedIDs(
        than itemID: String,
        in ordered: [SpokenWordBookItem],
        order: LocalPodcastEpisodeOrder
    ) -> [String] {
        let sequence = listeningSequence(ordered, order: order)
        guard let index = sequence.firstIndex(where: { $0.id == itemID }) else { return [] }
        return sequence[..<index].filter { !$0.isFinished }.map(\.id)
    }

    /// 有日期的按日期,日期相同的照章节顺序(从新到旧时倒过来,编号大的在上);
    /// 没有日期的排在最后,保持章节顺序。
    private static func byDate(_ items: [SpokenWordBookItem], newestFirst: Bool) -> [SpokenWordBookItem] {
        let indexed = Array(items.enumerated())
        let dated = indexed.filter { $0.element.addedAt != nil }.sorted { lhs, rhs in
            let left = lhs.element.addedAt ?? .distantPast
            let right = rhs.element.addedAt ?? .distantPast
            if left != right { return newestFirst ? left > right : left < right }
            return newestFirst ? lhs.offset > rhs.offset : lhs.offset < rhs.offset
        }
        let undated = indexed.filter { $0.element.addedAt == nil }
        return (dated + undated).map(\.element)
    }
}

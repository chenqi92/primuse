import Foundation

/// 搜索结果页的一块区域。
///
/// 顺序与显隐按 rawValue 存盘,case 名改了用户的配置就对不上了。
public enum SearchResultSection: String, CaseIterable, Codable, Identifiable, Sendable {
    case albums
    case artists
    /// 标题 / 艺术家 / 专辑命中。
    case metadata
    case path
    case lyrics
    /// 拼音 / 模糊命中。
    case fuzzy
    /// AI 语义搜索补充的结果。
    case intelligent
    case appleMusic

    public var id: String { rawValue }

    public var titleKey: String {
        switch self {
        case .albums: "tab_albums"
        case .artists: "tab_artists"
        case .metadata: "search_section_metadata"
        case .path: "search_section_path"
        case .lyrics: "search_section_lyrics"
        case .fuzzy: "search_section_fuzzy"
        case .intelligent: "search_ai_section"
        case .appleMusic: "search_section_apple_music"
        }
    }

    public var icon: String {
        switch self {
        case .albums: "square.stack"
        case .artists: "music.mic"
        case .metadata: "music.note"
        case .path: "folder"
        case .lyrics: "text.quote"
        case .fuzzy: "textformat.abc"
        case .intelligent: "sparkles"
        case .appleMusic: "applelogo"
        }
    }

    /// 这一块是不是本机曲库里的结果。Apple Music 是在线目录,不算。
    public var isLocal: Bool { self != .appleMusic }

    /// 宽屏「全部」页里这一块的形态。
    public var blockForm: SearchResultBlockForm {
        switch self {
        case .albums, .artists, .appleMusic: .shelf
        case .lyrics: .cards
        case .metadata, .path, .fuzzy, .intelligent: .list
        }
    }
}

/// 一块结果在宽屏上怎么摆。
public enum SearchResultBlockForm: Sendable {
    /// 一整排封面(专辑、艺术家、Apple Music),独占一行,按宽度铺满一排。
    case shelf
    /// 紧凑的歌曲行。相邻的几块可以并排成栏,单独一块时把行分成几栏。
    case list
    /// 带歌词摘句的卡片,和列表一样可以并排。
    case cards
}

/// Mac「全部」页的排版:哪些块并排、每块露几条。
///
/// 页面宽度是连续变化的,规则集中在这里,渲染和「全选」圈的歌才对得上。
public enum SearchResultPageLayout {
    /// 「最佳匹配」大卡的宽度。
    public static let heroCardWidth = 280.0
    public static let columnSpacing = 24.0
    /// 一栏歌曲行放得下封面、两行文字和时长的最小宽度。
    public static let minimumColumnWidth = 340.0
    public static let maximumColumns = 3
    /// 窄于这个宽度时最佳匹配旁边放不下别的块,整页退回单栏竖排。
    public static let heroMinimumWidth = 720.0

    public struct Row: Equatable, Identifiable, Sendable {
        public let sections: [SearchResultSection]
        public var id: String { sections.map(\.rawValue).joined(separator: "+") }

        public init(_ sections: [SearchResultSection]) {
            self.sections = sections
        }
    }

    public struct Plan: Equatable, Sendable {
        /// 和最佳匹配并排的那一块;没有最佳匹配或页面太窄时为 nil。
        public let heroNeighbor: SearchResultSection?
        public let rows: [Row]
    }

    /// 这个宽度能并排几栏。
    public static func columnCount(for width: Double) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        let fitting = Int(((width + columnSpacing) / (minimumColumnWidth + columnSpacing)).rounded(.down))
        return min(max(fitting, 1), maximumColumns)
    }

    /// 排出整页。
    ///
    /// - Parameters:
    ///   - order: 用户排的顺序(已去掉关掉的块)。
    ///   - present: 这次有东西可显示的块。Apple Music 没结果时也有一张状态卡,所以算在内。
    ///   - withItems: 真有结果条目的块。最佳匹配旁边只放这种,放一张状态卡会显得空。
    ///   - hasTopMatch: 有没有最佳匹配。
    ///   - width: 结果区的可用宽度。
    public static func plan(
        order: [SearchResultSection],
        present: Set<SearchResultSection>,
        withItems: Set<SearchResultSection>,
        hasTopMatch: Bool,
        width: Double
    ) -> Plan {
        var seen = Set<SearchResultSection>()
        let visible = order.filter { present.contains($0) && seen.insert($0).inserted }
        let heroNeighbor = hasTopMatch && width >= heroMinimumWidth
            ? visible.first(where: withItems.contains)
            : nil
        let perRow = width >= heroMinimumWidth ? columnCount(for: width) : 1

        var rows: [Row] = []
        var pending: [SearchResultSection] = []
        func flush() {
            guard !pending.isEmpty else { return }
            rows.append(Row(pending))
            pending = []
        }
        for section in visible where section != heroNeighbor {
            if section.blockForm == .shelf {
                flush()
                rows.append(Row([section]))
            } else {
                pending.append(section)
                if pending.count == perRow { flush() }
            }
        }
        flush()
        return Plan(heroNeighbor: heroNeighbor, rows: rows)
    }

    /// 最佳匹配旁边那一块能用的宽度。
    public static func heroNeighborWidth(totalWidth: Double) -> Double {
        max(totalWidth - heroCardWidth - columnSpacing, 0)
    }

    /// 一行里并排 `blocksInRow` 块时每块的宽度。
    public static func blockWidth(totalWidth: Double, blocksInRow: Int) -> Double {
        let count = max(blocksInRow, 1)
        return max((totalWidth - columnSpacing * Double(count - 1)) / Double(count), 0)
    }

    /// 一块列表或卡片在「全部」页露几条。
    ///
    /// 分成几栏时按栏数取整,最后一栏不会只剩半截。最佳匹配旁边的那块按大卡的高度取,
    /// 大约五行歌或两张歌词卡。
    public static func previewCount(
        for section: SearchResultSection,
        innerColumns: Int,
        besideTopMatch: Bool
    ) -> Int {
        let columns = max(innerColumns, 1)
        switch section.blockForm {
        case .shelf:
            return 0
        case .list:
            if besideTopMatch { return columns * 5 }
            return columns == 1 ? 6 : columns * 3
        case .cards:
            if besideTopMatch { return columns * 2 }
            return columns == 1 ? 3 : columns * 2
        }
    }

    /// 一整排封面放得下几个。
    public static func shelfItemCount(width: Double, minimumItemWidth: Double, spacing: Double) -> Int {
        guard width.isFinite, width > 0, minimumItemWidth > 0 else { return 1 }
        return max(Int(((width + spacing) / (minimumItemWidth + spacing)).rounded(.down)), 1)
    }

    /// 把条目按栏竖着分:先排满第一栏再排第二栏,读排名时视线往下走。
    public static func columnMajorChunks<Element>(_ items: [Element], columns: Int) -> [[Element]] {
        guard !items.isEmpty else { return [] }
        let columnCount = min(max(columns, 1), items.count)
        let perColumn = Int((Double(items.count) / Double(columnCount)).rounded(.up))
        return stride(from: 0, to: items.count, by: perColumn).map {
            Array(items[$0..<min($0 + perColumn, items.count)])
        }
    }
}

/// 搜索结果各块的先后与显隐。
///
/// Apple Music 这一块的显隐不记在这里:它就是设置里那个「搜索 Apple Music 目录」开关,
/// 两处管同一件事只能有一份存档,否则一边关了另一边还开着。
public enum SearchResultSectionLayout {
    public static let orderKey = "primuse.search.sectionOrder.v1"
    public static let hiddenKey = "primuse.search.hiddenSections.v1"

    /// 默认维持搜索页原本的排法。
    public static let defaultOrder: [SearchResultSection] = [
        .albums,
        .artists,
        .metadata,
        .path,
        .lyrics,
        .fuzzy,
        .intelligent,
        .appleMusic,
    ]

    /// 读回用户存的顺序。
    ///
    /// 按字符串逐个解,认不出的丢掉:降级到老版本时,新版本多出来的一块不能让整份
    /// 顺序解不出来退回默认。存档里缺的块插回它在默认顺序里的位置,而不是一律垫底。
    public static func decodeOrder(_ rawValue: String) -> [SearchResultSection] {
        var seen = Set<SearchResultSection>()
        var result = decodeRawValues(rawValue)
            .compactMap(SearchResultSection.init(rawValue:))
            .filter { seen.insert($0).inserted }
        for missing in defaultOrder where !seen.contains(missing) {
            guard let defaultIndex = defaultOrder.firstIndex(of: missing) else { continue }
            let insertionIndex = result.firstIndex { section in
                (defaultOrder.firstIndex(of: section) ?? .max) > defaultIndex
            }
            result.insert(missing, at: insertionIndex ?? result.endIndex)
            seen.insert(missing)
        }
        return result
    }

    /// 顺序等于默认时存空串,以后调整默认顺序,没动过的用户会跟着走。
    public static func encodeOrder(_ sections: [SearchResultSection]) -> String {
        let normalized = decodeOrder(encodeRawValues(sections.map(\.rawValue)))
        guard normalized != defaultOrder else { return "" }
        return encodeRawValues(normalized.map(\.rawValue))
    }

    public static func decodeHidden(_ rawValue: String) -> Set<SearchResultSection> {
        let hidden = Set(decodeRawValues(rawValue).compactMap(SearchResultSection.init(rawValue:)))
        return normalizedHidden(hidden)
    }

    public static func encodeHidden(_ sections: Set<SearchResultSection>) -> String {
        let hidden = normalizedHidden(sections)
        guard !hidden.isEmpty else { return "" }
        return encodeRawValues(defaultOrder.filter(hidden.contains).map(\.rawValue))
    }

    /// 关掉这一块之后是否还剩本机结果可看。
    ///
    /// 本机的几块全关掉,搜什么都是「无结果」,看起来就像搜索坏了。所以最后一块
    /// 本机结果不让关;Apple Music 不算数,它要联网、要授权,不是随时都在。
    public static func canHide(
        _ section: SearchResultSection,
        hidden: Set<SearchResultSection>
    ) -> Bool {
        guard section.isLocal else { return true }
        let remaining = defaultOrder.filter {
            $0.isLocal && $0 != section && !hidden.contains($0)
        }
        return !remaining.isEmpty
    }

    /// 在编辑页里拖动一行。
    ///
    /// 编辑页不一定列出全部的块(没配 AI、没装 Apple Music 时那两行不出现),拖动的
    /// 下标是相对于列出来的那几行的。这里只在它们占据的位置之间重排,没列出来的块
    /// 原地不动。
    public static func reordering(
        _ order: [SearchResultSection],
        displayed: [SearchResultSection],
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) -> [SearchResultSection] {
        let full = decodeOrder(encodeRawValues(order.map(\.rawValue)))
        let displayedSet = Set(displayed)
        let slots = full.indices.filter { displayedSet.contains(full[$0]) }
        var moved = slots.map { full[$0] }
        let validSource = IndexSet(source.filter { moved.indices.contains($0) })
        guard !validSource.isEmpty else { return full }
        let clampedDestination = min(max(destination, 0), moved.count)

        let picked = validSource.map { moved[$0] }
        let insertionIndex = clampedDestination - validSource.filter { $0 < clampedDestination }.count
        for index in validSource.reversed() {
            moved.remove(at: index)
        }
        moved.insert(contentsOf: picked, at: insertionIndex)

        var result = full
        for (slot, section) in zip(slots, moved) {
            result[slot] = section
        }
        return result
    }

    private static func normalizedHidden(_ sections: Set<SearchResultSection>) -> Set<SearchResultSection> {
        var hidden = sections
        hidden.remove(.appleMusic)
        // 老存档或手改过的存档可能把本机结果全关了,至少留回默认顺序里的第一块。
        if !defaultOrder.contains(where: { $0.isLocal && !hidden.contains($0) }),
           let first = defaultOrder.first(where: \.isLocal) {
            hidden.remove(first)
        }
        return hidden
    }

    private static func decodeRawValues(_ rawValue: String) -> [String] {
        guard let data = rawValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func encodeRawValues(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

import Foundation

/// 首页的一块区域。
///
/// 顺序、显隐与每块的视图方案都按这个枚举存盘,所以它必须留在 Kit 里:
/// 存的是 rawValue,一旦某个 case 消失,用户攒下来的整份配置就解不出来了。
public enum HomeSectionKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case continueListening
    case radio
    case quickAccess
    case forYou
    case playlists
    case folders
    case listeningRanking
    case topArtists
    case recentlyAdded
    case stats

    public var id: String { rawValue }

    /// 电台不再是首页的一个分区 —— 它有了自己的模式(右上角切换),音乐态里
    /// 再放一块电台就是重复内容。case 本身保留,否则老用户存下来的排序 JSON
    /// 解不出来会被整个丢弃、自定义顺序全丢。
    public var isUserConfigurable: Bool { self != .radio }

    public var icon: String {
        switch self {
        case .continueListening: "play.circle"
        case .radio: "radio.fill"
        case .quickAccess: "pin"
        case .forYou: "sparkles"
        case .playlists: "music.note.list"
        case .folders: "folder"
        case .listeningRanking: "chart.bar.fill"
        case .topArtists: "music.mic"
        case .recentlyAdded: "clock.badge.checkmark"
        case .stats: "chart.bar.xaxis"
        }
    }
}

/// 一块区域的呈现方式。
///
/// 同一批内容换个排布,占的竖向空间能差好几倍 —— issue #106 就是「最近添加」
/// 的 2×3 网格一次吃掉六个大方格,把下面的「继续听」挤出首屏。所以方案是
/// 每块各存一份,而不是全局一个开关。
public enum HomeSectionLayoutStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 纵向列表,一行一条,最省横向空间。
    case list
    /// 横向滚动。行数单独配置(1–3 行),不再为「双行」单开一个方案 ——
    /// 双行本来就是横排的一个参数,当成两种排布只会让选项互相打架。
    case carousel
    /// 纵向网格,视觉最重,适合封面本身就是内容的区域。
    case grid

    public var id: String { rawValue }
    public var titleKey: String { "home_layout_" + rawValue }
    public var icon: String {
        switch self {
        case .list: "list.bullet"
        case .carousel: "rectangle.grid.1x2.fill"
        case .grid: "square.grid.3x2.fill"
        }
    }

    /// 老版本把「双行横排」当成独立方案存过。读回来映射成横排 + 2 行,
    /// 而不是让整块配置解不出来退回默认。
    public static let legacyDoubleCarouselRawValue = "carouselDouble"
}

public enum HomeSectionLayoutPolicy {
    /// 哪几块能换方案,以及各自换得动哪些。
    ///
    /// 不是每块都该给选择:统计概览是一张固定卡片,文件夹与听歌排行有自己的
    /// 条目数设置,硬塞一个「网格」只会做出难看的东西。给不出第二种像样排布的
    /// 区域就返回空数组 —— 编辑态据此不显示方案按钮。
    public static func supportedStyles(for section: HomeSectionKind) -> [HomeSectionLayoutStyle] {
        switch section {
        case .continueListening: [.carousel, .list]
        case .forYou: [.carousel, .list]
        case .playlists: [.list, .carousel, .grid]
        case .topArtists: [.carousel, .grid]
        case .recentlyAdded: [.grid, .carousel, .list]
        case .quickAccess: [.grid, .carousel]
        case .folders: [.list, .grid, .carousel]
        case .radio, .listeningRanking, .stats: []
        }
    }

    /// 默认维持首页原本的样子 —— 用户没动过的区域不应该因为上了这套机制就变样。
    public static func defaultStyle(for section: HomeSectionKind) -> HomeSectionLayoutStyle {
        supportedStyles(for: section).first ?? .list
    }

    public static func isConfigurable(_ section: HomeSectionKind) -> Bool {
        supportedStyles(for: section).count > 1
    }

    /// 横排的行数范围。只有横排才有行数可言。
    public static func rowsRange(
        for section: HomeSectionKind,
        style: HomeSectionLayoutStyle
    ) -> ClosedRange<Int>? {
        guard style == .carousel, supportedStyles(for: section).contains(.carousel) else { return nil }
        return 1...3
    }

    /// 继续听原本就是双行,换成「横排 + 行数」之后默认值要维持原样。
    public static func defaultRows(for section: HomeSectionKind) -> Int {
        section == .continueListening ? 2 : 1
    }

    /// 可以自定义条目数的区域及其范围。
    ///
    /// 上限受首页快照本身的取数上限约束 —— 调到比快照更多没有意义,只会让用户
    /// 以为设置没生效。文件夹与快捷入口另有自己的条目数设置,不在这里重复一份。
    public static func itemCountRange(for section: HomeSectionKind) -> ClosedRange<Int>? {
        switch section {
        case .continueListening: 4...24
        case .playlists: 3...20
        case .topArtists: 4...20
        case .recentlyAdded: 4...24
        case .forYou: 3...12
        // 展开后最多列到第几名。调到 0 就是不提供展开。
        case .listeningRanking: 0...20
        case .quickAccess, .folders, .stats, .radio: nil
        }
    }

    /// 用户没设过条目数时，设置页显示的基准值。
    ///
    /// 首页真正用的默认值还要看尺寸类（iPad 一行放得下更多），这里给的是紧凑
    /// 宽度那一档 —— 设置页不知道首页当下有多宽，与其编一个数，不如取用户
    /// 手机上最常见的那个。
    public static func defaultItemCount(for section: HomeSectionKind) -> Int {
        switch section {
        case .continueListening: 12
        case .playlists: 4
        case .topArtists: 8
        case .recentlyAdded: 6
        case .forYou: 5
        case .listeningRanking: 20
        case .quickAccess, .folders, .stats, .radio: 0
        }
    }

    /// 把存下来的值夹回该区域真正支持的范围。
    ///
    /// 存盘的是字符串,后续版本删掉某个方案、或某块不再支持某个方案时,旧值必须
    /// 退回默认而不是让界面渲染出一个不存在的排布。
    public static func resolved(
        _ style: HomeSectionLayoutStyle?,
        for section: HomeSectionKind
    ) -> HomeSectionLayoutStyle {
        guard let style, supportedStyles(for: section).contains(style) else {
            return defaultStyle(for: section)
        }
        return style
    }
}

/// 每块区域选定的方案。整体作为一个 JSON 字符串存进 AppStorage。
public struct HomeSectionLayoutConfiguration: Codable, Equatable, Sendable {
    public static let storageKey = "primuse.home.sectionLayout.v1"

    /// key 是 HomeSectionKind.rawValue,value 是 HomeSectionLayoutStyle.rawValue。
    /// 只存用户改过的区域,没有条目就按默认走。
    public var styles: [String: String]

    /// 用户自定义的显示条目数,同样只存改过的。没有条目时由界面按当前尺寸类
    /// 给默认值 —— iPad 一行放得下更多,默认值本就该和 iPhone 不同。
    public var itemCounts: [String: Int]

    /// 横排的行数,同样只存改过的。
    public var rows: [String: Int]

    public init(
        styles: [String: String] = [:],
        itemCounts: [String: Int] = [:],
        rows: [String: Int] = [:]
    ) {
        self.styles = styles
        self.itemCounts = itemCounts
        self.rows = rows
    }

    public func rowCount(for section: HomeSectionKind) -> Int {
        let style = style(for: section)
        guard let range = HomeSectionLayoutPolicy.rowsRange(for: section, style: style) else { return 1 }
        let stored = rows[section.rawValue] ?? HomeSectionLayoutPolicy.defaultRows(for: section)
        return min(max(stored, range.lowerBound), range.upperBound)
    }

    public mutating func setRowCount(_ count: Int, for section: HomeSectionKind) {
        let style = style(for: section)
        guard let range = HomeSectionLayoutPolicy.rowsRange(for: section, style: style) else { return }
        rows[section.rawValue] = min(max(count, range.lowerBound), range.upperBound)
    }

    /// 用户没设过就返回 nil,由调用方决定默认值。
    public func itemCount(for section: HomeSectionKind) -> Int? {
        guard let range = HomeSectionLayoutPolicy.itemCountRange(for: section),
              let stored = itemCounts[section.rawValue] else { return nil }
        return min(max(stored, range.lowerBound), range.upperBound)
    }

    public mutating func setItemCount(_ count: Int, for section: HomeSectionKind) {
        guard let range = HomeSectionLayoutPolicy.itemCountRange(for: section) else { return }
        itemCounts[section.rawValue] = min(max(count, range.lowerBound), range.upperBound)
    }

    /// 恢复到「跟随默认」而不是写死一个数字。
    public mutating func clearItemCount(for section: HomeSectionKind) {
        itemCounts.removeValue(forKey: section.rawValue)
    }

    public func style(for section: HomeSectionKind) -> HomeSectionLayoutStyle {
        let stored = styles[section.rawValue]
        // 老存档里的「双行横排」现在是横排 + 2 行。
        let parsed = stored == HomeSectionLayoutStyle.legacyDoubleCarouselRawValue
            ? HomeSectionLayoutStyle.carousel
            : stored.flatMap(HomeSectionLayoutStyle.init(rawValue:))
        return HomeSectionLayoutPolicy.resolved(parsed, for: section)
    }

    /// 选回默认值时把条目删掉,而不是写一条等于默认的记录 —— 这样以后调整默认值,
    /// 没主动改过的用户会跟着走。
    public mutating func setStyle(_ style: HomeSectionLayoutStyle, for section: HomeSectionKind) {
        guard HomeSectionLayoutPolicy.supportedStyles(for: section).contains(style) else { return }
        if style == HomeSectionLayoutPolicy.defaultStyle(for: section) {
            styles.removeValue(forKey: section.rawValue)
        } else {
            styles[section.rawValue] = style.rawValue
        }
    }

    /// 在该区域支持的方案里向后轮换一格 —— 编辑态点一下方案按钮就换下一种。
    public mutating func advanceStyle(for section: HomeSectionKind) {
        let options = HomeSectionLayoutPolicy.supportedStyles(for: section)
        guard options.count > 1 else { return }
        let current = style(for: section)
        let next = options[((options.firstIndex(of: current) ?? 0) + 1) % options.count]
        setStyle(next, for: section)
    }

    // 老版本存下来的 JSON 没有 itemCounts 字段,缺省解成空字典而不是整份作废。
    private enum CodingKeys: String, CodingKey { case styles, itemCounts, rows }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedStyles = try container.decodeIfPresent([String: String].self, forKey: .styles) ?? [:]
        itemCounts = try container.decodeIfPresent([String: Int].self, forKey: .itemCounts) ?? [:]
        var migratedRows = try container.decodeIfPresent([String: Int].self, forKey: .rows) ?? [:]
        // 把老的「双行横排」就地迁成横排 + 2 行,之后写回去的就是新格式。
        var migratedStyles: [String: String] = [:]
        for (key, value) in storedStyles {
            if value == HomeSectionLayoutStyle.legacyDoubleCarouselRawValue {
                migratedStyles[key] = HomeSectionLayoutStyle.carousel.rawValue
                if migratedRows[key] == nil { migratedRows[key] = 2 }
            } else {
                migratedStyles[key] = value
            }
        }
        styles = migratedStyles
        rows = migratedRows
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
}

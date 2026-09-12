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
    /// 单行横向滚动卡片。
    case carousel
    /// 双行横向滚动,同样高度里塞进一倍的条目。
    case carouselDouble
    /// 纵向网格,视觉最重,适合封面本身就是内容的区域。
    case grid

    public var id: String { rawValue }
    public var titleKey: String { "home_layout_" + rawValue }
    public var icon: String {
        switch self {
        case .list: "list.bullet"
        case .carousel: "rectangle.grid.1x2.fill"
        case .carouselDouble: "square.grid.2x2.fill"
        case .grid: "square.grid.3x2.fill"
        }
    }
}

public enum HomeSectionLayoutPolicy {
    /// 哪几块能换方案,以及各自换得动哪些。
    ///
    /// 不是每块都该给选择:统计概览是一张固定卡片,文件夹与听歌排行有自己的
    /// 条目数设置,硬塞一个「网格」只会做出难看的东西。给不出第二种像样排布的
    /// 区域就返回空数组 —— 编辑态据此不显示方案按钮。
    public static func supportedStyles(for section: HomeSectionKind) -> [HomeSectionLayoutStyle] {
        switch section {
        case .continueListening: [.carouselDouble, .carousel, .list]
        case .forYou: [.carousel, .list]
        case .playlists: [.list, .carousel, .grid]
        case .topArtists: [.carousel, .grid]
        case .recentlyAdded: [.grid, .carousel, .list]
        case .quickAccess: [.grid, .carousel]
        case .radio, .folders, .listeningRanking, .stats: []
        }
    }

    /// 默认维持首页原本的样子 —— 用户没动过的区域不应该因为上了这套机制就变样。
    public static func defaultStyle(for section: HomeSectionKind) -> HomeSectionLayoutStyle {
        supportedStyles(for: section).first ?? .list
    }

    public static func isConfigurable(_ section: HomeSectionKind) -> Bool {
        supportedStyles(for: section).count > 1
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

    public init(styles: [String: String] = [:]) {
        self.styles = styles
    }

    public func style(for section: HomeSectionKind) -> HomeSectionLayoutStyle {
        HomeSectionLayoutPolicy.resolved(
            styles[section.rawValue].flatMap(HomeSectionLayoutStyle.init(rawValue:)),
            for: section
        )
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

import Foundation

// MARK: - 页面表面

/// 外壳里每一类页面的画法。一套皮肤给每个表面挑一个实现;没写的表面就是经典实现。
///
/// 表面按「一类页面」划分,不按视图文件划分:同一类页面换一种画法时,它消费的数据与功能
/// (播放、队列、批量选择、搜索范围……)只有一份,实现只换画法。
///
/// 专辑网格、艺术家列表、歌单列表、迷你播放条这几类现在没有第二种画法,所以没有建表面 ——
/// 空壳只会让人以为那里可以换。需要时再加:加一个 case,在 `SkinSurfaceVariant` 里给出它的实现枚举。
public enum SkinSurface: String, CaseIterable, Sendable, Codable {
    /// 首页(继续听、为你推荐、排行、头图)。
    case home
    /// 资料库根页(分类入口)。
    case libraryRoot
    /// 平铺的歌曲列表。
    case songList
    /// 专辑 / 艺术家 / 歌单 / 智能歌单 / 风格五种详情页的头图与操作行。
    case collectionDetail
    /// 全屏播放页。
    case player
    /// 播放队列。
    case queue
    /// 搜索页(还没输入时的起始页与结果页)。
    case search
    /// 电台页。
    case radio
    /// 设置根页的组织方式。
    case settingsRoot
}

/// 一个表面的实现枚举都遵守它:原始值是存进皮肤定义里的标识,`classic` 必须有。
public protocol SkinSurfaceImplementation: RawRepresentable, CaseIterable, Sendable, Hashable
where RawValue == String {
    /// 这个枚举描述的是哪个表面。
    static var surface: SkinSurface { get }
    /// 经典实现。读不出来的取值(来自更新版本的皮肤、手改的数据)一律落到它。
    static var classic: Self { get }
}

/// 每个表面已有的实现。
///
/// 写成枚举而不是裸字符串:App 层按变体做穷尽 `switch`,Kit 里多登记一个实现而 App
/// 没画出来时,构建直接失败 —— 「登记了却拿不到视图」这种缺陷因此不会流到运行时。
public enum SkinSurfaceVariant {
    public enum Home: String, SkinSurfaceImplementation {
        case classic
        /// 头图是一面斜铺的封面墙海报;区块标题加重,快速访问是两列胶囊,继续听是方形大卡,
        /// 本周统计以大号时长为主。
        case poster
        public static var surface: SkinSurface { .home }
    }

    public enum LibraryRoot: String, SkinSurfaceImplementation {
        case classic
        /// 分类入口画成带封面预览的方块,而不是分组列表的行。
        case tiles
        public static var surface: SkinSurface { .libraryRoot }
    }

    public enum SongList: String, SkinSurfaceImplementation {
        case classic
        /// 顶上多一排「播放 · 随机」胶囊与歌曲数。
        case playHeader
        public static var surface: SkinSurface { .songList }
    }

    public enum CollectionDetail: String, SkinSurfaceImplementation {
        /// 整页封面取色、海报式头图、「随机 · 播放 · 下载」一排(两套外壳共用)。
        case classic
        public static var surface: SkinSurface { .collectionDetail }
    }

    public enum Player: String, SkinSurfaceImplementation {
        case classic
        /// 「更多」以分组面板呈现(常用的几项提到第一排),而不是一长条系统菜单;
        /// 竖屏播放键是实心圆,音质与来源收进底栏的胶囊,封面浮得更高。
        case sheetActions
        public static var surface: SkinSurface { .player }
    }

    public enum Queue: String, SkinSurfaceImplementation {
        case classic
        /// 工具栏多一颗循环键,正在播放单独成卡,已播放默认收起。
        case nowPlayingCard
        public static var surface: SkinSurface { .queue }
    }

    public enum Search: String, SkinSurfaceImplementation {
        case classic
        /// 起始页是最近搜索的胶囊、按流派浏览的磁贴与一行计数;结果页有「最佳结果」大卡,
        /// 分区标题加粗并带「查看全部」。
        case browse
        public static var surface: SkinSurface { .search }
    }

    public enum Radio: String, SkinSurfaceImplementation {
        case classic
        /// 正在直播的电台是最上面一张大卡,网格末尾一格「添加电台」。
        case onAir
        public static var surface: SkinSurface { .radio }
    }

    public enum SettingsRoot: String, SkinSurfaceImplementation {
        /// 分区长列表。
        case classic
        /// 常用磁贴 + 分类入口,其余设置页收进分类里。
        case hub
        public static var surface: SkinSurface { .settingsRoot }
    }
}

/// 表面实现的标识。皮肤定义里存的是这个字符串,读取时再还原成枚举。
public typealias SkinSurfaceVariantID = String

/// 已登记的表面实现,由 `SkinSurfaceVariant` 的各个枚举推导,不单独维护。
public enum SkinSurfaceRegistry {
    public static let classicVariant: SkinSurfaceVariantID = "classic"

    public static let builtIn: [SkinSurface: Set<SkinSurfaceVariantID>] = {
        var registry: [SkinSurface: Set<SkinSurfaceVariantID>] = [:]
        for surface in SkinSurface.allCases {
            registry[surface] = Set(variants(of: surface))
        }
        return registry
    }()

    public static func variants(of surface: SkinSurface) -> [SkinSurfaceVariantID] {
        switch surface {
        case .home: return ids(SkinSurfaceVariant.Home.self)
        case .libraryRoot: return ids(SkinSurfaceVariant.LibraryRoot.self)
        case .songList: return ids(SkinSurfaceVariant.SongList.self)
        case .collectionDetail: return ids(SkinSurfaceVariant.CollectionDetail.self)
        case .player: return ids(SkinSurfaceVariant.Player.self)
        case .queue: return ids(SkinSurfaceVariant.Queue.self)
        case .search: return ids(SkinSurfaceVariant.Search.self)
        case .radio: return ids(SkinSurfaceVariant.Radio.self)
        case .settingsRoot: return ids(SkinSurfaceVariant.SettingsRoot.self)
        }
    }

    /// 每个表面都取经典实现。
    public static var allClassic: [SkinSurface: SkinSurfaceVariantID] {
        SkinSurface.allCases.reduce(into: [:]) { $0[$1] = classicVariant }
    }

    private static func ids<V: SkinSurfaceImplementation>(_ type: V.Type) -> [SkinSurfaceVariantID] {
        V.allCases.map(\.rawValue)
    }
}

// MARK: - 组件级样式

/// 跨页面复用的组件的画法。它们出现在很多表面里(专辑卡在资料库、首页、搜索、艺术家页都有),
/// 不属于任何一个表面,所以单独成一组。
public struct SkinComponentStyle: Sendable, Hashable, Codable {
    public enum Card: String, CaseIterable, Sendable, Codable {
        case classic
        /// 大一号的卡片:专辑卡标题加重一档、封面圆角稍大;音乐源卡片的品牌图标块稍大。
        case tile
    }

    public let card: Card

    public init(card: Card = .classic) {
        self.card = card
    }

    public static let classic = SkinComponentStyle()
}

// MARK: - 读取

extension SkinDefinition {
    /// 这套皮肤给某个表面选的实现标识;没写的表面是经典实现。
    public func variantID(for surface: SkinSurface) -> SkinSurfaceVariantID {
        surfaces[surface] ?? SkinSurfaceRegistry.classicVariant
    }

    /// 这套皮肤给某个表面选的实现。读不出来(来自更新版本的皮肤、手改的数据)一律落到经典实现。
    public func implementation<V: SkinSurfaceImplementation>(_ type: V.Type) -> V {
        V(rawValue: variantID(for: V.surface)) ?? V.classic
    }

    public var home: SkinSurfaceVariant.Home { implementation(SkinSurfaceVariant.Home.self) }
    public var libraryRoot: SkinSurfaceVariant.LibraryRoot { implementation(SkinSurfaceVariant.LibraryRoot.self) }
    public var songList: SkinSurfaceVariant.SongList { implementation(SkinSurfaceVariant.SongList.self) }
    public var collectionDetail: SkinSurfaceVariant.CollectionDetail {
        implementation(SkinSurfaceVariant.CollectionDetail.self)
    }
    public var player: SkinSurfaceVariant.Player { implementation(SkinSurfaceVariant.Player.self) }
    public var queue: SkinSurfaceVariant.Queue { implementation(SkinSurfaceVariant.Queue.self) }
    public var search: SkinSurfaceVariant.Search { implementation(SkinSurfaceVariant.Search.self) }
    public var radio: SkinSurfaceVariant.Radio { implementation(SkinSurfaceVariant.Radio.self) }
    public var settingsRoot: SkinSurfaceVariant.SettingsRoot {
        implementation(SkinSurfaceVariant.SettingsRoot.self)
    }
}

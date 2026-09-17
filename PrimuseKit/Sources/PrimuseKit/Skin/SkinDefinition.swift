import Foundation

// MARK: - 结构插槽

/// 样式可以整块替换 UI 的位置。
///
/// 纯 token 换不出「详情页头图从一张封面变成一面封面墙」这种结构性差异,所以留出
/// 这些插槽,由样式挑一个实现。**插槽数量是封死的**:一旦允许随手再开一个口子,就会
/// 退回「每个视图里 if 样式」的老路 —— 那条路上一套样式要改两千行,第四套样式时
/// 这些视图就没人敢动了。
///
/// 需要新插槽时,应当先问「这能不能用 token 表达」,只有确实是结构差异才加,并且要
/// 同时在 `SkinSlotVariant` 里给出它的实现枚举、更新相应测试。
public enum SkinSlot: String, CaseIterable, Sendable, Codable {
    /// 根导航:系统标签栏,还是自绘顶栏(搜索 + 分类 chip)。
    case navigationHeader
    /// 底部 chrome(迷你播放器所在的那条)。
    case bottomChrome
    /// 专辑 / 歌单 / 艺术家 / 流派等集合详情页的头图。
    case detailHeader
    /// 设置根页的组织方式。
    case settingsRoot
    /// 首页区块的排布方式。
    case homeLayout
    /// 曲目列表的行样式。
    case listRow
    /// 专辑 / 歌单卡片样式。
    case card
    /// 全屏播放页的舞台。
    case playerStage
}

/// 每个插槽已有的实现。
///
/// 写成枚举而不是裸字符串:App 层对它做穷尽 `switch`,Kit 里多登记一个实现而 App
/// 没画出来时,构建直接失败 —— 「登记了却拿不到视图」这种缺陷因此不会流到运行时。
public enum SkinSlotVariant {
    public enum NavigationHeader: String, CaseIterable, Sendable {
        /// 系统标签栏 + 各页自己的导航栏。
        case classic
        /// 自绘顶栏:搜索框 + 资料库分类 chip,不显示标签栏。
        case minimal
    }

    public enum BottomChrome: String, CaseIterable, Sendable {
        case classic
        /// 悬浮胶囊:圆形封面、进度环、队列入口。
        case floatingCapsule
    }

    public enum DetailHeader: String, CaseIterable, Sendable {
        case classic
        /// 多封面时是一面缓慢重排的封面墙,单封面时是带光晕的大图。
        case coverWall
    }

    public enum SettingsRoot: String, CaseIterable, Sendable {
        /// 分区长列表。
        case classic
        /// 常用磁贴 + 分类入口,其余设置页收进分类里。
        case hub
    }

    public enum HomeLayout: String, CaseIterable, Sendable { case classic }
    public enum ListRow: String, CaseIterable, Sendable { case classic }
    public enum Card: String, CaseIterable, Sendable { case classic }
    public enum PlayerStage: String, CaseIterable, Sendable { case classic }
}

/// 插槽实现的标识。样式定义里存的是这个字符串,读取时再还原成枚举。
public typealias SkinSlotVariantID = String

/// 已登记的插槽实现,由 `SkinSlotVariant` 的各个枚举推导,不单独维护。
public enum SkinSlotRegistry {
    public static let classicVariant: SkinSlotVariantID = "classic"

    public static let builtIn: [SkinSlot: Set<SkinSlotVariantID>] = {
        var registry: [SkinSlot: Set<SkinSlotVariantID>] = [:]
        for slot in SkinSlot.allCases {
            registry[slot] = Set(variants(of: slot))
        }
        return registry
    }()

    public static func variants(of slot: SkinSlot) -> [SkinSlotVariantID] {
        switch slot {
        case .navigationHeader: return SkinSlotVariant.NavigationHeader.allCases.map(\.rawValue)
        case .bottomChrome: return SkinSlotVariant.BottomChrome.allCases.map(\.rawValue)
        case .detailHeader: return SkinSlotVariant.DetailHeader.allCases.map(\.rawValue)
        case .settingsRoot: return SkinSlotVariant.SettingsRoot.allCases.map(\.rawValue)
        case .homeLayout: return SkinSlotVariant.HomeLayout.allCases.map(\.rawValue)
        case .listRow: return SkinSlotVariant.ListRow.allCases.map(\.rawValue)
        case .card: return SkinSlotVariant.Card.allCases.map(\.rawValue)
        case .playerStage: return SkinSlotVariant.PlayerStage.allCases.map(\.rawValue)
        }
    }

    /// 每个插槽都取经典实现 —— 新样式只改 token 时的默认选择。
    public static var allClassic: [SkinSlot: SkinSlotVariantID] {
        SkinSlot.allCases.reduce(into: [:]) { $0[$1] = classicVariant }
    }
}

// MARK: - 外观、页面底色、可用性

/// 样式在浅色 / 深色上的立场。
///
/// 有些设计过的样式只在一种底色下成立(一套暗色霓虹样式放到浅色模式会垮),所以
/// 样式可以强制外观,而不是被系统设置拖着走。
public enum SkinAppearanceAffinity: String, Sendable, Codable, CaseIterable {
    /// 跟随系统 / 用户在设置里的选择。
    case adaptive
    case forcesLight
    case forcesDark
}

/// 页面底色由谁来画。
public enum SkinPageBackground: String, Sendable, Codable, CaseIterable {
    /// 不干预:List / Form / ScrollView 各自保持系统默认底色。经典样式用这一种,
    /// 这样分组列表的灰底、普通页面的白底都和今天一致。
    case system
    /// 由样式画 `canvasGlow -> canvas` 的渐变,并隐藏滚动容器自带的底色。
    case canvas
}

/// 一套样式怎样进入用户的可用列表。
public enum SkinAccess: Sendable, Equatable, Codable {
    /// 随 App 提供,始终可用。
    case included
    /// 需要先解锁。`unlockID` 由 App 层的权益来源解释,样式定义不关心它怎么来。
    case unlockable(unlockID: String)

    public var requiresUnlock: Bool {
        if case .unlockable = self { return true }
        return false
    }

    public var unlockID: String? {
        if case .unlockable(let unlockID) = self { return unlockID }
        return nil
    }
}

// MARK: - 配套包

/// 随样式一起提供的沉浸舞台与歌词海报。
///
/// 这里只存 id:舞台与海报各有自己的目录和渲染器,样式不接管它们,只声明
/// 「这几款是我带来的」。样式可用,它带来的配套才可用。
public struct SkinCompanions: Sendable, Equatable, Codable {
    public let immersiveStageIDs: [String]
    public let lyricPosterStyleIDs: [String]
    /// 切到这套样式时建议启用的舞台 / 海报。只对没有手动选过的用户生效。
    public let preferredImmersiveStageID: String?
    public let preferredLyricPosterStyleID: String?

    public init(
        immersiveStageIDs: [String] = [],
        lyricPosterStyleIDs: [String] = [],
        preferredImmersiveStageID: String? = nil,
        preferredLyricPosterStyleID: String? = nil
    ) {
        self.immersiveStageIDs = immersiveStageIDs
        self.lyricPosterStyleIDs = lyricPosterStyleIDs
        self.preferredImmersiveStageID = preferredImmersiveStageID
        self.preferredLyricPosterStyleID = preferredLyricPosterStyleID
    }

    public static let none = SkinCompanions()

    public var isEmpty: Bool { immersiveStageIDs.isEmpty && lyricPosterStyleIDs.isEmpty }
}

// MARK: - 样式定义

/// 一套样式的完整描述。除插槽选择外全是数据 —— 新增一套样式不需要动视图。
public struct SkinDefinition: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    /// 样式名的本地化 key。
    public let nameKey: String
    /// 一句话描述的本地化 key。
    public let descriptionKey: String
    public let appearance: SkinAppearanceAffinity
    public let pageBackground: SkinPageBackground
    /// 可用性。解锁状态本身不存在这里 —— 样式定义是静态数据,权益是运行时状态,
    /// 两者混在一起会让权益变化的处理渗进 UI。
    public let access: SkinAccess

    public let colors: [SkinColorToken: SkinColorSpec]
    public let metrics: [SkinMetricToken: Double]
    public let typography: [SkinTypographyToken: SkinTypeSpec]
    public let motion: [SkinMotionToken: SkinMotionSpec]
    public let slots: [SkinSlot: SkinSlotVariantID]
    public let companions: SkinCompanions

    public init(
        id: String,
        nameKey: String,
        descriptionKey: String,
        appearance: SkinAppearanceAffinity = .adaptive,
        pageBackground: SkinPageBackground = .canvas,
        access: SkinAccess = .included,
        colors: [SkinColorToken: SkinColorSpec],
        metrics: [SkinMetricToken: Double],
        typography: [SkinTypographyToken: SkinTypeSpec],
        motion: [SkinMotionToken: SkinMotionSpec],
        slots: [SkinSlot: SkinSlotVariantID] = SkinSlotRegistry.allClassic,
        companions: SkinCompanions = .none
    ) {
        self.id = id
        self.nameKey = nameKey
        self.descriptionKey = descriptionKey
        self.appearance = appearance
        self.pageBackground = pageBackground
        self.access = access
        self.colors = colors
        self.metrics = metrics
        self.typography = typography
        self.motion = motion
        self.slots = slots
        self.companions = companions
    }

    public func color(_ token: SkinColorToken) -> SkinColorSpec? { colors[token] }
    public func metric(_ token: SkinMetricToken) -> Double? { metrics[token] }
    public func type(_ token: SkinTypographyToken) -> SkinTypeSpec? { typography[token] }
    public func motionSpec(_ token: SkinMotionToken) -> SkinMotionSpec? { motion[token] }

    public func variant(for slot: SkinSlot) -> SkinSlotVariantID {
        slots[slot] ?? SkinSlotRegistry.classicVariant
    }

    // 读不出来(来自更新版本的样式、手改的数据)一律落到经典实现。
    public var navigationHeader: SkinSlotVariant.NavigationHeader {
        SkinSlotVariant.NavigationHeader(rawValue: variant(for: .navigationHeader)) ?? .classic
    }
    public var bottomChrome: SkinSlotVariant.BottomChrome {
        SkinSlotVariant.BottomChrome(rawValue: variant(for: .bottomChrome)) ?? .classic
    }
    public var detailHeader: SkinSlotVariant.DetailHeader {
        SkinSlotVariant.DetailHeader(rawValue: variant(for: .detailHeader)) ?? .classic
    }
    public var settingsRoot: SkinSlotVariant.SettingsRoot {
        SkinSlotVariant.SettingsRoot(rawValue: variant(for: .settingsRoot)) ?? .classic
    }
    public var homeLayout: SkinSlotVariant.HomeLayout {
        SkinSlotVariant.HomeLayout(rawValue: variant(for: .homeLayout)) ?? .classic
    }
    public var listRow: SkinSlotVariant.ListRow {
        SkinSlotVariant.ListRow(rawValue: variant(for: .listRow)) ?? .classic
    }
    public var card: SkinSlotVariant.Card {
        SkinSlotVariant.Card(rawValue: variant(for: .card)) ?? .classic
    }
    public var playerStage: SkinSlotVariant.PlayerStage {
        SkinSlotVariant.PlayerStage(rawValue: variant(for: .playerStage)) ?? .classic
    }
}

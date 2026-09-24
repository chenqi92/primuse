import Foundation

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

// MARK: - 特征位

/// 样式在几处「画法取向」上的选择。原来一个「自己画页面底色」的布尔值同时决定了页面底色、
/// 封面染色和浮层材质,后续样式想要「自己的底色 + 封面染色的详情页」这类组合就表达不了,
/// 所以拆成互相独立的几位。中性页面(设置、搜索、音乐源)的底色仍由 `pageBackground` 决定。
public struct SkinTraits: Sendable, Equatable, Codable {
    /// 专辑 / 艺术家 / 歌单 / 风格详情页的整页底色从哪里来。
    public enum CollectionBackdrop: String, Sendable, Codable, CaseIterable {
        /// 取自这一页的封面(两套基座的默认)。
        case artworkTint
        /// 用样式自己的页面底色,不染封面色。
        case skinCanvas
    }

    /// 底栏、播放胶囊这类悬浮控件的材质。
    public enum ChromeMaterial: String, Sendable, Codable, CaseIterable {
        /// 模糊材质叠样式的半透明底。
        case glass
        /// 不透明的样式底色(与系统「降低透明度」时一样)。
        case solid
    }

    public let collectionBackdrop: CollectionBackdrop
    public let chromeMaterial: ChromeMaterial

    public init(collectionBackdrop: CollectionBackdrop = .artworkTint, chromeMaterial: ChromeMaterial = .glass) {
        self.collectionBackdrop = collectionBackdrop
        self.chromeMaterial = chromeMaterial
    }

    public static let standard = SkinTraits()
}

// MARK: - 样式定义

/// 一套样式的完整描述:外壳 + 每个表面的实现 + 四张 token 表 + 配套 + 可用性。
/// 除外壳与表面的选择外全是数据 —— 只换数据不构成一套新皮肤,它要有自己的排版结构与交互。
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
    /// 外壳:根导航结构与正在播放的那一条。每套皮肤都要显式声明。
    public let shell: SkinShell
    /// 每个表面选的实现。没写的表面是经典实现。
    public let surfaces: [SkinSurface: SkinSurfaceVariantID]
    /// 跨页面复用的组件(专辑卡、音乐源卡片)的画法。
    public let components: SkinComponentStyle
    public let companions: SkinCompanions
    public let traits: SkinTraits

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
        shell: SkinShell,
        surfaces: [SkinSurface: SkinSurfaceVariantID] = [:],
        components: SkinComponentStyle = .classic,
        companions: SkinCompanions = .none,
        traits: SkinTraits = .standard
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
        self.shell = shell
        self.surfaces = surfaces
        self.components = components
        self.companions = companions
        self.traits = traits
    }

    public func color(_ token: SkinColorToken) -> SkinColorSpec? { colors[token] }
    public func metric(_ token: SkinMetricToken) -> Double? { metrics[token] }
    public func type(_ token: SkinTypographyToken) -> SkinTypeSpec? { typography[token] }
    public func motionSpec(_ token: SkinMotionToken) -> SkinMotionSpec? { motion[token] }
}

import Foundation

// MARK: - 颜色

/// 皮肤色板的语义位。视图只认这些名字,不认具体色值 —— 换皮肤就是换一张
/// `SkinColorToken -> SkinColorSpec` 的表,视图一行都不用改。
///
/// 命名按「用途」而不是「外观」:`textSecondary` 而不是 `gray60`。一旦出现
/// 按外观命名的 token,某套皮肤想把它做成蓝色时就会自相矛盾。
public enum SkinColorToken: String, CaseIterable, Sendable, Codable {
    // 文字
    case textPrimary
    case textSecondary
    case textTertiary
    case textQuaternary
    /// 压在强调色上的文字(按钮标题等),必须与 `accent` 保证对比度。
    case textOnAccent
    /// 压在深色遮罩 / 封面之上的文字,不随浅深色翻转。
    case textOnScrim

    // 背景
    case canvas
    /// 页面底色顶部的那层微光。页面背景是 `canvasGlow -> canvas` 的纵向渐变;
    /// 不想要渐变的样式把它设成与 `canvas` 相同即可。
    case canvasGlow
    case canvasElevated
    case canvasSunken
    /// 盖在内容之上的遮罩(弹层背景、封面压暗)。
    case scrim

    // 容器
    case surface
    case surfaceElevated
    case surfacePressed
    case chip
    case chipSelected

    // 描边
    case separator
    case separatorStrong
    case surfaceBorder
    case focusRing

    // 强调
    case accent
    /// 强调色的低饱和变体,用于选中底、进度槽。
    case accentMuted
    /// 强调色的极淡变体,用于 chip 底、图标底。
    case accentSoft

    // 状态
    case success
    case warning
    case danger

    // 导航 chrome(顶栏 / 底栏 / 迷你播放器)
    case chromeBackground
    case chromeBorder
    case chromeItem
    case chromeItemSelected
}

/// 系统语义色。`classic` 皮肤全部映射到这些值,从而与今天的渲染逐像素一致,
/// 并保留系统的增强对比度、色彩滤镜等无障碍行为 —— 自定义皮肤用固定色值时
/// 会失去这层行为,这是设计上的取舍,不是疏漏。
public enum SkinSystemColor: String, Sendable, Codable, CaseIterable {
    case label
    case secondaryLabel
    case tertiaryLabel
    case quaternaryLabel
    case systemBackground
    case secondarySystemBackground
    case tertiarySystemBackground
    case systemGroupedBackground
    case separator
    case opaqueSeparator
    case systemFill
    case secondarySystemFill
    case tertiarySystemFill
    case quaternarySystemFill
    /// 当前强调色(跟随 ThemeService 的封面取色 / 固定色)。
    case tint
    case white
    case black
    case clear
    case green
    case orange
    case red
}

/// 文字层级。对应 SwiftUI 的 `.primary / .secondary / .tertiary / .quaternary`。
public enum SkinHierarchyLevel: String, Sendable, Codable, CaseIterable {
    case primary, secondary, tertiary, quaternary
}

/// 一个色位的取值方式。
public enum SkinColorSpec: Sendable, Equatable, Codable {
    /// 跟随系统语义色。
    case system(SkinSystemColor)
    /// 跟随所在上下文的前景层级。
    ///
    /// 今天视图里的 `.foregroundStyle(.secondary)` 不是一个固定的灰:它相对当前前景色
    /// 取层级,压在封面上的白字区域里它就是半透明的白。经典样式的文字色位用这一种,
    /// 迁移到 token 之后这类位置才不会变色。
    case hierarchical(SkinHierarchyLevel)
    /// 系统语义色再叠一层透明度。今天视图里大量的
    /// `Color.secondary.opacity(0.1)` 属于这一类,单独用 `fixed` 表达会丢掉
    /// 系统色本身的浅深色自适应。
    case systemOpacity(SkinSystemColor, opacity: Double)
    /// 固定色值,浅色与深色各一份。
    case fixed(light: SkinColorValue, dark: SkinColorValue)
    /// 在当前强调色基础上调整透明度 —— 让皮肤既能自定义,又不切断
    /// 「强调色跟随封面」这条已有链路。
    case tinted(opacity: Double)

    /// 固定色值是否处在合法范围。`system` / `tinted` 由运行时保证。
    public var isWellFormed: Bool {
        switch self {
        case .system, .hierarchical:
            return true
        case .systemOpacity(_, let opacity), .tinted(let opacity):
            return (0...1).contains(opacity)
        case .fixed(let light, let dark):
            return light.isWellFormed && dark.isWellFormed
        }
    }
}

/// 一个固定色值:`0xRRGGBB` 加不透明度。
public struct SkinColorValue: Sendable, Equatable, Codable {
    public let hex: UInt32
    public let opacity: Double

    public init(hex: UInt32, opacity: Double = 1) {
        self.hex = hex
        self.opacity = opacity
    }

    public var isWellFormed: Bool {
        hex <= 0xFFFFFF && (0...1).contains(opacity)
    }

    public var red: Double { Double((hex >> 16) & 0xFF) / 255 }
    public var green: Double { Double((hex >> 8) & 0xFF) / 255 }
    public var blue: Double { Double(hex & 0xFF) / 255 }
}

// MARK: - 几何

/// 几何位。圆角、间距、控件高度、描边宽度 —— 不同风格之间差别最大的恰恰是
/// 这些,而今天它们全是散在视图里的字面量。
///
/// 取值单位是「默认字号下的点」,渲染时再按 Dynamic Type 缩放
/// (见 App 层的 `ScaledSkinMetric`),所以皮肤不需要自己关心无障碍字号。
public enum SkinMetricToken: String, CaseIterable, Sendable, Codable {
    // 圆角
    case radiusSmall
    case radiusMedium
    case radiusLarge
    case radiusChip
    case radiusCard
    /// 封面缩略图(列表行、迷你播放条、小卡片)的圆角。
    case radiusArtwork
    /// 胶囊形:运行时按高度折算,皮肤给一个足够大的值即可。
    case radiusPill

    // 间距
    case spacingTight
    case spacingSmall
    case spacingMedium
    case spacingLarge
    case spacingSection

    // 控件
    case controlHeightSmall
    case controlHeightMedium
    case controlHeightLarge
    case iconSizeSmall
    case iconSizeMedium
    case iconSizeLarge

    // 描边与阴影
    case hairline
    case borderWidth
    case shadowRadius
    case shadowOpacity

    // 导航 chrome
    case chromeTopPadding
    case chromeBottomPadding
    case chromeItemSpacing
    case chromeChipHeight
    case chromeChipRowHeight
    case chromeChipSpacing
    /// 顶行与分类 chip 行之间的间距。
    case chromeChipRowSpacing
    case chromeCollapsedChipHeight
    case chromeSearchFieldHeight
    case chromeHorizontalInset
}

// MARK: - 字体

public enum SkinTypographyToken: String, CaseIterable, Sendable, Codable {
    case displayTitle
    case pageTitle
    case sectionTitle
    case bodyStrong
    case body
    case callout
    case caption
    case meta
    /// 导航 chip 的文字。
    case chrome
    /// 折叠态导航 chip 的文字。
    case chromeCompact
    /// 搜索框输入文字。
    case chromeField
    /// 数字 / 时长这类要求等宽的位置。
    case numeric
}

public enum SkinFontWeight: String, Sendable, Codable, CaseIterable {
    case regular, medium, semibold, bold, heavy
}

public enum SkinFontDesign: String, Sendable, Codable, CaseIterable {
    case `default`, rounded, serif, monospaced
}

/// Dynamic Type 的缩放锚点。字号按这个文本样式的比例缩放,和系统控件保持一致。
public enum SkinTextStyle: String, Sendable, Codable, CaseIterable {
    case largeTitle, title, title2, title3, headline, subheadline, body, callout, footnote, caption
}

public struct SkinTypeSpec: Sendable, Equatable, Codable {
    public let size: Double
    public let weight: SkinFontWeight
    public let design: SkinFontDesign
    public let relativeTo: SkinTextStyle

    public init(
        size: Double,
        weight: SkinFontWeight = .regular,
        design: SkinFontDesign = .default,
        relativeTo: SkinTextStyle = .body
    ) {
        self.size = size
        self.weight = weight
        self.design = design
        self.relativeTo = relativeTo
    }

    public var isWellFormed: Bool { size > 0 && size <= 200 }
}

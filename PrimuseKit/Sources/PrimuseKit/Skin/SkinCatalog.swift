import Foundation

/// 随 App 一起发布的界面样式。
///
/// 每套样式一个文件(`SkinCatalog+<名字>.swift`),这里只负责把它们列出来。
/// 新增一套样式 = 新增一个文件 + 在 `all` 里加一行,不需要改任何视图。
public enum SkinCatalog {
    public static let classicID = "classic"
    public static let minimalID = "minimal"

    /// 正式提供的样式,顺序就是设置页里的展示顺序。
    public static var all: [SkinDefinition] { [classic, minimal] }

    /// 还在打磨、只在开发构建里列出来的样式。用来在真机上核对「只换数据」
    /// 「待解锁」这些路径,不随正式版本出现。
    public static var lab: [SkinDefinition] { [midnight] }

    public static func skin(id: String, includingLab: Bool = false) -> SkinDefinition? {
        (includingLab ? all + lab : all).first { $0.id == id }
    }

    /// 找不到 / 不可用时的兜底,永远可用。
    public static var fallback: SkinDefinition { classic }

    // MARK: - 经典

    /// 经典样式:每一个色位都映射到系统语义色或上下文层级,几何与动效取自视图里
    /// 原有的字面量。装上这套结构之后外观不变,也保留系统的增强对比度等无障碍行为。
    /// **改这里的任何取值 = 改经典外观。**
    public static let classic = SkinDefinition(
        id: classicID,
        nameKey: "skin.classic.name",
        descriptionKey: "skin.classic.description",
        appearance: .adaptive,
        pageBackground: .system,
        access: .included,
        colors: [
            .textPrimary: .hierarchical(.primary),
            .textSecondary: .hierarchical(.secondary),
            .textTertiary: .hierarchical(.tertiary),
            .textQuaternary: .hierarchical(.quaternary),
            .textOnAccent: .system(.white),
            .textOnScrim: .system(.white),

            .canvas: .system(.systemBackground),
            .canvasGlow: .system(.systemBackground),
            .canvasElevated: .system(.secondarySystemBackground),
            .canvasSunken: .system(.systemGroupedBackground),
            // 遮罩今天就是 `.black.opacity(…)`,不走系统语义色。
            .scrim: .fixed(
                light: SkinColorValue(hex: 0x000000, opacity: 0.35),
                dark: SkinColorValue(hex: 0x000000, opacity: 0.55)
            ),

            .surface: .system(.secondarySystemBackground),
            .surfaceElevated: .system(.tertiarySystemBackground),
            .surfacePressed: .system(.quaternarySystemFill),
            // 今天极简顶栏未选中的 chip 就是 `Color.secondary.opacity(0.1)`。
            .chip: .systemOpacity(.secondaryLabel, opacity: 0.10),
            // 选中态今天是 accent 的低透明度底。
            .chipSelected: .tinted(opacity: 0.16),

            .separator: .system(.separator),
            .separatorStrong: .system(.opaqueSeparator),
            .surfaceBorder: .system(.separator),
            .focusRing: .system(.tint),

            .accent: .system(.tint),
            .accentMuted: .tinted(opacity: 0.30),
            .accentSoft: .tinted(opacity: 0.14),

            .success: .system(.green),
            .warning: .system(.orange),
            .danger: .system(.red),

            .chromeBackground: .system(.systemBackground),
            .chromeBorder: .system(.separator),
            .chromeItem: .system(.secondaryLabel),
            .chromeItemSelected: .system(.tint),
        ],
        metrics: [
            .radiusSmall: 8,
            .radiusMedium: 12,
            .radiusLarge: 16,
            .radiusChip: 17,
            .radiusCard: 14,
            .radiusArtwork: 6,
            .radiusPill: 999,

            .spacingTight: 4,
            .spacingSmall: 8,
            .spacingMedium: 12,
            .spacingLarge: 16,
            .spacingSection: 24,

            .controlHeightSmall: 28,
            .controlHeightMedium: 34,
            .controlHeightLarge: 44,
            .iconSizeSmall: 14,
            .iconSizeMedium: 17,
            .iconSizeLarge: 22,

            .hairline: 0.5,
            .borderWidth: 1,
            .shadowRadius: 8,
            .shadowOpacity: 0.12,

            // 以下数值取自自绘顶栏的现有字面量,保持不变。
            .chromeTopPadding: 6,
            .chromeBottomPadding: 8,
            .chromeItemSpacing: 8,
            .chromeChipHeight: 34,
            .chromeChipRowHeight: 37,
            .chromeChipSpacing: 7,
            .chromeChipRowSpacing: 9,
            .chromeCollapsedChipHeight: 44,
            .chromeSearchFieldHeight: 44,
            .chromeHorizontalInset: 12,
        ],
        typography: [
            .displayTitle: SkinTypeSpec(size: 34, weight: .bold, relativeTo: .largeTitle),
            .pageTitle: SkinTypeSpec(size: 22, weight: .semibold, relativeTo: .title2),
            .sectionTitle: SkinTypeSpec(size: 17, weight: .semibold, relativeTo: .headline),
            .bodyStrong: SkinTypeSpec(size: 15, weight: .semibold, relativeTo: .body),
            .body: SkinTypeSpec(size: 15, relativeTo: .body),
            .callout: SkinTypeSpec(size: 14, relativeTo: .callout),
            .caption: SkinTypeSpec(size: 12, relativeTo: .caption),
            .meta: SkinTypeSpec(size: 11, relativeTo: .caption),
            // 自绘顶栏的现有字号。未选中的分类 chip 是 regular,选中态由组件覆盖成 semibold。
            .chrome: SkinTypeSpec(size: 14.5, weight: .regular, relativeTo: .subheadline),
            // 折叠态 chip 恒为 semibold。
            .chromeCompact: SkinTypeSpec(size: 14, weight: .semibold, relativeTo: .subheadline),
            .chromeField: SkinTypeSpec(size: 15.5, relativeTo: .subheadline),
            .numeric: SkinTypeSpec(size: 13, design: .monospaced, relativeTo: .footnote),
            // 列表行今天写的就是 `.subheadline` / `.caption`。
            .rowTitle: .textStyle(.subheadline),
            .rowSubtitle: .textStyle(.caption),
        ],
        motion: [
            // 以下曲线取自视图里原有的字面量。
            .selection: .spring(response: 0.3, dampingFraction: 0.86),
            .chromeCollapse: .spring(response: 0.3, dampingFraction: 0.86),
            .chromeReveal: .smooth(duration: 0.26, extraBounce: 0),
            .pageSwitch: .easeOut(duration: 0.18),
            .press: .easeOut(duration: 0.12),
            .sheet: .spring(response: 0.45, dampingFraction: 0.92),
            .contentAppear: .easeOut(duration: 0.2),
            .heroReflow: .easeInOut(duration: 1.4),
            .heroFocus: .spring(response: 0.55, dampingFraction: 0.9),
        ]
    )
}

import PrimuseKit
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 视图侧取用界面样式的入口。
///
/// 视图只写 `skin.color(.textSecondary)` / `.foregroundStyle(.skin(.textSecondary))` /
/// `skin.metric(.radiusCard)`,不知道当前是哪套样式,也不知道色值从哪来 —— 换样式因此
/// 不需要改视图。
///
/// 两端都能编译:iOS 由根部按当前样式注入;macOS 没有样式切换,始终拿到经典样式,
/// 共用的视图代码因此可以放心迁到 token 上而不影响 Mac 的外观。
///
/// 只存纯数据(样式定义、字号档位、是否减弱动效),所以是 Sendable,可以安全地作为
/// 环境默认值;颜色、字体、动画都在取用时解析。
struct SkinStyle: Equatable, Sendable {
    let skin: SkinDefinition
    let dynamicTypeSize: DynamicTypeSize
    let reduceMotion: Bool

    init(
        skin: SkinDefinition = SkinCatalog.fallback,
        dynamicTypeSize: DynamicTypeSize = .large,
        reduceMotion: Bool = false
    ) {
        self.skin = skin
        self.dynamicTypeSize = dynamicTypeSize
        self.reduceMotion = reduceMotion
    }

    /// 内置样式按 id 就能区分,不必逐张表比较。
    static func == (lhs: SkinStyle, rhs: SkinStyle) -> Bool {
        lhs.skin.id == rhs.skin.id
            && lhs.dynamicTypeSize == rhs.dynamicTypeSize
            && lhs.reduceMotion == rhs.reduceMotion
    }

    // MARK: - 颜色

    private func spec(_ token: SkinColorToken) -> SkinColorSpec {
        // 缺位时退回兜底样式而不是画成透明:缺一个 token 应该看起来「像经典」,
        // 而不是控件凭空消失。完整性本身由 SkinValidationPolicy 的测试保证。
        skin.colors[token] ?? SkinCatalog.fallback.colors[token] ?? .hierarchical(.primary)
    }

    /// 需要一个 `Color` 的位置用这个(渐变、阴影、`opacity` 运算)。
    func color(_ token: SkinColorToken) -> Color {
        Self.resolveColor(spec(token))
    }

    /// 前景 / 填充优先用 `.skin(token)`(见下方 `SkinColor`):经典样式的文字层级
    /// 会按所在上下文解析,和今天的 `.foregroundStyle(.secondary)` 完全一致。
    func shapeStyle(_ token: SkinColorToken) -> AnyShapeStyle {
        switch spec(token) {
        case .hierarchical(let level):
            switch level {
            case .primary: return AnyShapeStyle(HierarchicalShapeStyle.primary)
            case .secondary: return AnyShapeStyle(HierarchicalShapeStyle.secondary)
            case .tertiary: return AnyShapeStyle(HierarchicalShapeStyle.tertiary)
            case .quaternary: return AnyShapeStyle(HierarchicalShapeStyle.quaternary)
            }
        case let other:
            return AnyShapeStyle(Self.resolveColor(other))
        }
    }

    private static func resolveColor(_ spec: SkinColorSpec) -> Color {
        switch spec {
        case .system(let systemColor):
            return systemColor.color
        case .systemOpacity(let systemColor, let opacity):
            return systemColor.color.opacity(opacity)
        case .hierarchical(let level):
            return level.color
        case .tinted(let opacity):
            // 走 SwiftUI 的 tint —— 根部已按 ThemeService 注入,
            // 所以强调色仍然跟着封面走,换样式不会切断这条链路。
            return Color.accentColor.opacity(opacity)
        case .fixed(let light, let dark):
            return Self.dynamicColor(light: light, dark: dark)
        }
    }

    private static func dynamicColor(light: SkinColorValue, dark: SkinColorValue) -> Color {
        #if os(iOS)
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark.platformColor : light.platformColor
        })
        #elseif os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? dark.platformColor
                : light.platformColor
        })
        #else
        return Color(red: light.red, green: light.green, blue: light.blue, opacity: light.opacity)
        #endif
    }

    // MARK: - 页面底色

    /// 这套样式是否自己画页面底色。经典样式不画 —— 分组列表的灰底、普通页面的白底
    /// 都保持系统默认。
    var paintsPageBackground: Bool { skin.pageBackground == .canvas }

    // MARK: - 几何

    /// 已按 Dynamic Type 缩放的点值。圆角、描边、阴影这类形状语言不参与缩放
    /// (见 `SkinMetricToken.scalesWithDynamicType`)。
    @MainActor func metric(_ token: SkinMetricToken) -> CGFloat {
        let base = rawMetric(token)
        guard token.scalesWithDynamicType else { return base }
        return scaled(base, anchor: token.scalingAnchor)
    }

    /// 未经缩放的原始点值。需要与未缩放几何对齐时使用。
    func rawMetric(_ token: SkinMetricToken) -> CGFloat {
        CGFloat(skin.metrics[token] ?? SkinCatalog.fallback.metrics[token] ?? 0)
    }

    // MARK: - 字体

    private func typeSpec(_ token: SkinTypographyToken) -> SkinTypeSpec {
        skin.typography[token]
            ?? SkinCatalog.fallback.typography[token]
            ?? SkinTypeSpec(size: 15)
    }

    @MainActor func font(_ token: SkinTypographyToken) -> Font {
        let spec = typeSpec(token)
        if spec.followsTextStyle {
            // 字号、行高、字距都交给系统文本样式:原来写 `.font(.subheadline)` 的位置迁过来之后行高不变。
            return .system(
                spec.relativeTo.fontTextStyle,
                design: spec.design.fontDesign,
                weight: spec.weight.fontWeight
            )
        }
        return .system(
            size: scaled(CGFloat(spec.size), anchor: spec.relativeTo),
            weight: spec.weight.fontWeight,
            design: spec.design.fontDesign
        )
    }

    /// 字重。选中态这类由组件自己决定的强调,仍由组件在此基础上覆盖。
    func fontWeight(_ token: SkinTypographyToken) -> Font.Weight {
        typeSpec(token).weight.fontWeight
    }

    /// 字体的缩放后字号。需要把图标对齐到文字时使用。
    @MainActor func fontSize(_ token: SkinTypographyToken) -> CGFloat {
        let spec = typeSpec(token)
        return scaled(CGFloat(spec.size), anchor: spec.relativeTo)
    }

    // MARK: - 动效

    /// 当前样式给这条动效定的曲线;开启「减弱动态效果」时为 nil(不做动画)。
    func animation(_ token: SkinMotionToken) -> Animation? {
        guard !reduceMotion else { return nil }
        let spec = skin.motion[token] ?? SkinCatalog.fallback.motion[token] ?? SkinMotionSpec.none
        switch spec {
        case .spring(let response, let dampingFraction):
            return .spring(response: response, dampingFraction: dampingFraction)
        case .smooth(let duration, let extraBounce):
            return .smooth(duration: duration, extraBounce: extraBounce)
        case .easeInOut(let duration):
            return .easeInOut(duration: duration)
        case .easeOut(let duration):
            return .easeOut(duration: duration)
        case .linear(let duration):
            return .linear(duration: duration)
        case .none:
            return nil
        }
    }

    // MARK: - Dynamic Type

    /// 缩放要经过 UIKit 的字体度量,所以这条路径(连同 `metric` / `font` / `fontSize`)限定在主线程;
    /// 取色那条路径不经过这里,仍可在任意上下文调用(`ShapeStyle.resolve(in:)` 就不在主 actor 上)。
    ///
    /// 与 `@ScaledMetric` 同源:都走 `UIFontMetrics`。区别在于这里每次求值都用
    /// 当前档位,所以换样式时能立刻反映新的基准值 —— `@ScaledMetric` 的存储值
    /// 只在视图首次建立时取一次,换样式不会更新。
    @MainActor private func scaled(_ value: CGFloat, anchor: SkinTextStyle) -> CGFloat {
        #if os(iOS)
        return UIFontMetrics(forTextStyle: anchor.uiTextStyle).scaledValue(
            for: value,
            compatibleWith: UITraitCollection(
                preferredContentSizeCategory: dynamicTypeSize.contentSizeCategory
            )
        )
        #else
        // macOS 没有系统级的动态字号。
        return value
        #endif
    }
}

// MARK: - 作为 ShapeStyle 使用

/// `.foregroundStyle(.skin(.textSecondary))` / `.fill(.skin(.surface))`。
///
/// 它在渲染时才从环境里取当前样式,所以视图不需要声明 `@Environment(\.skin)` ——
/// 把 `.foregroundStyle(.secondary)` 改成 `.foregroundStyle(.skin(.textSecondary))`
/// 是一处纯机械的替换。
struct SkinColor: ShapeStyle {
    let token: SkinColorToken

    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        environment.skin.shapeStyle(token)
    }
}

extension ShapeStyle where Self == SkinColor {
    static func skin(_ token: SkinColorToken) -> SkinColor { SkinColor(token: token) }
}

// MARK: - 环境注入

private struct SkinStyleEnvironmentKey: EnvironmentKey {
    static let defaultValue = SkinStyle()
}

extension EnvironmentValues {
    var skin: SkinStyle {
        get { self[SkinStyleEnvironmentKey.self] }
        set { self[SkinStyleEnvironmentKey.self] = newValue }
    }
}

#if os(iOS)
/// 把当前样式、Dynamic Type 档位与「减弱动态效果」合成 `SkinStyle` 注入子树。
///
/// runtime 用参数传入而不是从环境读:这个 modifier 本身可能挂在
/// `.environment(runtime)` 之上,从环境读会取不到值,而参数传入没有这层顺序依赖。
private struct SkinStyleHost: ViewModifier {
    let runtime: SkinRuntime
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .environment(
                \.skin,
                SkinStyle(
                    skin: runtime.activeSkin,
                    dynamicTypeSize: dynamicTypeSize,
                    reduceMotion: reduceMotion
                )
            )
    }
}

extension View {
    func skinStyle(_ runtime: SkinRuntime) -> some View {
        modifier(SkinStyleHost(runtime: runtime))
    }
}
#endif

// MARK: - 页面底色

/// 样式自己的页面底色:顶部一层微光向下融进底色。
struct SkinPageBackdrop: View {
    @Environment(\.skin) private var skin

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: skin.color(.canvasGlow), location: 0),
                .init(color: skin.color(.canvas), location: 0.42),
                .init(color: skin.color(.canvas), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct SkinPageBackgroundModifier: ViewModifier {
    @Environment(\.skin) private var skin

    @ViewBuilder
    func body(content: Content) -> some View {
        if skin.paintsPageBackground {
            content
                // List / Form 自带的系统底色让出来,露出下面的样式底色。
                .scrollContentBackground(.hidden)
                .background { SkinPageBackdrop().ignoresSafeArea() }
        } else {
            content
        }
    }
}

extension View {
    /// 让这一页用当前样式的页面底色。经典样式下原样返回,系统默认底色不变。
    func skinPageBackground() -> some View {
        modifier(SkinPageBackgroundModifier())
    }
}

// MARK: - Token 到平台类型的映射

extension SkinColorValue {
    #if os(iOS)
    var platformColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: opacity)
    }
    #elseif os(macOS)
    var platformColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: opacity)
    }
    #endif
}

extension SkinHierarchyLevel {
    /// 需要具体 `Color` 时的取值。前景样式请走 `SkinStyle.shapeStyle`,那条路径保留层级语义。
    var color: Color {
        switch self {
        case .primary: return Color.primary
        case .secondary: return Color.secondary
        #if os(iOS)
        case .tertiary: return Color(uiColor: .tertiaryLabel)
        case .quaternary: return Color(uiColor: .quaternaryLabel)
        #elseif os(macOS)
        case .tertiary: return Color(nsColor: .tertiaryLabelColor)
        case .quaternary: return Color(nsColor: .quaternaryLabelColor)
        #else
        case .tertiary: return Color.secondary.opacity(0.6)
        case .quaternary: return Color.secondary.opacity(0.35)
        #endif
        }
    }
}

extension SkinSystemColor {
    var color: Color {
        #if os(iOS)
        switch self {
        case .label: return Color(uiColor: .label)
        case .secondaryLabel: return Color(uiColor: .secondaryLabel)
        case .tertiaryLabel: return Color(uiColor: .tertiaryLabel)
        case .quaternaryLabel: return Color(uiColor: .quaternaryLabel)
        case .systemBackground: return Color(uiColor: .systemBackground)
        case .secondarySystemBackground: return Color(uiColor: .secondarySystemBackground)
        case .tertiarySystemBackground: return Color(uiColor: .tertiarySystemBackground)
        case .systemGroupedBackground: return Color(uiColor: .systemGroupedBackground)
        case .separator: return Color(uiColor: .separator)
        case .opaqueSeparator: return Color(uiColor: .opaqueSeparator)
        case .systemFill: return Color(uiColor: .systemFill)
        case .secondarySystemFill: return Color(uiColor: .secondarySystemFill)
        case .tertiarySystemFill: return Color(uiColor: .tertiarySystemFill)
        case .quaternarySystemFill: return Color(uiColor: .quaternarySystemFill)
        case .tint: return Color.accentColor
        case .white: return .white
        case .black: return .black
        case .clear: return .clear
        case .green: return Color(uiColor: .systemGreen)
        case .orange: return Color(uiColor: .systemOrange)
        case .red: return Color(uiColor: .systemRed)
        }
        #elseif os(macOS)
        switch self {
        case .label: return Color(nsColor: .labelColor)
        case .secondaryLabel: return Color(nsColor: .secondaryLabelColor)
        case .tertiaryLabel: return Color(nsColor: .tertiaryLabelColor)
        case .quaternaryLabel: return Color(nsColor: .quaternaryLabelColor)
        case .systemBackground: return Color(nsColor: .windowBackgroundColor)
        case .secondarySystemBackground: return Color(nsColor: .controlBackgroundColor)
        case .tertiarySystemBackground: return Color(nsColor: .underPageBackgroundColor)
        case .systemGroupedBackground: return Color(nsColor: .windowBackgroundColor)
        case .separator: return Color(nsColor: .separatorColor)
        case .opaqueSeparator: return Color(nsColor: .gridColor)
        case .systemFill: return Color(nsColor: .systemFill)
        case .secondarySystemFill: return Color(nsColor: .secondarySystemFill)
        case .tertiarySystemFill: return Color(nsColor: .tertiarySystemFill)
        case .quaternarySystemFill: return Color(nsColor: .quaternarySystemFill)
        case .tint: return Color.accentColor
        case .white: return .white
        case .black: return .black
        case .clear: return .clear
        case .green: return Color(nsColor: .systemGreen)
        case .orange: return Color(nsColor: .systemOrange)
        case .red: return Color(nsColor: .systemRed)
        }
        #else
        return Color.primary
        #endif
    }
}

extension SkinFontWeight {
    var fontWeight: Font.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        }
    }
}

extension SkinFontDesign {
    var fontDesign: Font.Design {
        switch self {
        case .default: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        case .monospaced: return .monospaced
        }
    }
}

extension SkinTextStyle {
    var fontTextStyle: Font.TextStyle {
        switch self {
        case .largeTitle: return .largeTitle
        case .title: return .title
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .body: return .body
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption
        }
    }
}

#if os(iOS)
extension SkinTextStyle {
    var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .body: return .body
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        }
    }
}

extension DynamicTypeSize {
    /// `UIFontMetrics` 需要 UIKit 的档位表示。
    var contentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
    }
}
#endif

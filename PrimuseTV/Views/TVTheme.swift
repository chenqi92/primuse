#if os(tvOS)
import SwiftUI
import UIKit

@MainActor
@Observable
final class TVThemeState {
    static let shared = TVThemeState()

    private(set) var mode: AppThemeColorMode
    private(set) var fixedHex: String
    private(set) var artworkPrimaryHex: String?
    private(set) var artworkSecondaryHex: String?

    private init() {
        let defaults = UserDefaults.standard
        mode = AppThemePreferences.colorMode(in: defaults)
        fixedHex = AppThemePreferences.normalizedHex(
            defaults.string(forKey: AppThemePreferences.accentHexKey)
                ?? AppThemePreferences.defaultAccentHex
        )
    }

    var accent: Color {
        TVColor.brand(hex: mode == .automatic ? artworkPrimaryHex ?? fixedHex : fixedHex)
    }

    var secondary: Color {
        TVColor.brandSecondary(hex: mode == .automatic ? artworkSecondaryHex ?? fixedHex : fixedHex)
    }

    var onAccent: Color {
        TVColor.onBrand(hex: mode == .automatic ? artworkPrimaryHex ?? fixedHex : fixedHex)
    }

    func setMode(_ mode: AppThemeColorMode) {
        self.mode = mode
    }

    func setFixedHex(_ hex: String) {
        fixedHex = AppThemePreferences.normalizedHex(hex)
    }

    func setArtworkPalette(primaryHex: String, secondaryHex: String) {
        artworkPrimaryHex = AppThemePreferences.normalizedHex(primaryHex)
        artworkSecondaryHex = AppThemePreferences.normalizedHex(secondaryHex)
    }

    func resetArtworkPalette() {
        artworkPrimaryHex = nil
        artworkSecondaryHex = nil
    }
}

// MARK: - 设计 token
//
// 保留原有 10ft 字号和焦点层级，颜色 token 同时适配 tvOS 浅色与深色外观。
// 封面色只负责氛围和强调，文字、卡片、分隔线始终由语义色保证对比度。

@MainActor
enum TVColor {
    static let bg = adaptive(light: rgb(0xF2EFEB), dark: rgb(0x000000))
    static let bgDeep = adaptive(light: rgb(0xE9E4DE), dark: rgb(0x0A0A0A))
    static let bgElev = adaptive(light: rgb(0xFFFCF8), dark: rgb(0x1A1715))
    static let text = adaptive(light: rgb(0x1B1816), dark: rgb(0xF3EEE7))
    static func textAlpha(_ a: Double) -> Color { text.opacity(a) }
    static let textMuted = adaptive(light: rgb(0x544F4A), dark: rgb(0xC7BFB7))
    static let textFaint = adaptive(light: rgb(0x69635E), dark: rgb(0xA8A098))
    static let textGhost = adaptive(light: rgb(0x726C66), dark: rgb(0x8F8881))
    static let card = adaptive(light: UIColor.white.withAlphaComponent(0.70),
                               dark: UIColor.white.withAlphaComponent(0.06))
    static let cardElev = adaptive(light: UIColor.white.withAlphaComponent(0.92),
                                   dark: UIColor.white.withAlphaComponent(0.10))
    static let cardBorder = adaptive(light: UIColor.black.withAlphaComponent(0.11),
                                     dark: UIColor.white.withAlphaComponent(0.12))
    static let divider = adaptive(light: UIColor.black.withAlphaComponent(0.10),
                                  dark: UIColor.white.withAlphaComponent(0.10))
    static let surfaceSubtle = adaptive(light: UIColor.black.withAlphaComponent(0.045),
                                        dark: UIColor.white.withAlphaComponent(0.06))
    static let surface = adaptive(light: UIColor.black.withAlphaComponent(0.075),
                                  dark: UIColor.white.withAlphaComponent(0.10))
    static let surfaceStrong = adaptive(light: UIColor.black.withAlphaComponent(0.13),
                                        dark: UIColor.white.withAlphaComponent(0.18))
    static let chrome = adaptive(light: UIColor.white.withAlphaComponent(0.82),
                                 dark: UIColor.black.withAlphaComponent(0.72))
    static let cardShadow = adaptive(light: UIColor.black.withAlphaComponent(0.10),
                                     dark: UIColor.black.withAlphaComponent(0.24))
    static let focusShadow = adaptive(light: UIColor.black.withAlphaComponent(0.26),
                                      dark: UIColor.black.withAlphaComponent(0.54))
    static var focusRing: Color { brand }
    /// 品牌底色在浅色外观中加深、深色外观中提亮，并提供对应前景色，
    /// 让 16pt 普通文本和焦点图标都达到稳定对比度。
    static var brand: Color {
        TVThemeState.shared.accent
    }
    static var brandSecondary: Color {
        TVThemeState.shared.secondary
    }
    static var onBrand: Color {
        TVThemeState.shared.onAccent
    }
    static let ok = adaptive(light: rgb(0x287A3B), dark: rgb(0x7ED187))
    static let warn = adaptive(light: rgb(0x9A551F), dark: rgb(0xF0B078))
    static let bad = adaptive(light: rgb(0xB8322B), dark: rgb(0xFF7565))

    static func brand(hex: String) -> Color {
        let source = color(hex: hex)
        return adaptive(
            light: adjusted(source, saturation: 0.32...0.88, brightness: 0.34...0.58),
            dark: adjusted(source, saturation: 0.28...0.76, brightness: 0.78...0.92)
        )
    }

    static func brandSecondary(hex: String) -> Color {
        let source = color(hex: hex)
        return adaptive(
            light: adjusted(source, saturation: 0.24...0.68, brightness: 0.30...0.44),
            dark: adjusted(source, saturation: 0.24...0.68, brightness: 0.24...0.38)
        )
    }

    static func onBrand(hex: String) -> Color {
        let source = color(hex: hex)
        let lightBrand = adjusted(source, saturation: 0.32...0.88, brightness: 0.34...0.58)
        let darkBrand = adjusted(source, saturation: 0.28...0.76, brightness: 0.78...0.92)
        return adaptive(
            light: contrastingForeground(for: lightBrand),
            dark: contrastingForeground(for: darkBrand)
        )
    }

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }

    private static func rgb(_ value: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func color(hex: String) -> UIColor {
        let normalized = AppThemePreferences.normalizedHex(hex)
        guard let value = UInt32(normalized, radix: 16) else {
            return rgb(0xC96442)
        }
        return rgb(value)
    }

    private static func adjusted(
        _ source: UIColor,
        saturation: ClosedRange<CGFloat>,
        brightness: ClosedRange<CGFloat>
    ) -> UIColor {
        var hue: CGFloat = 0
        var sourceSaturation: CGFloat = 0
        var sourceBrightness: CGFloat = 0
        var alpha: CGFloat = 0
        guard source.getHue(
            &hue,
            saturation: &sourceSaturation,
            brightness: &sourceBrightness,
            alpha: &alpha
        ) else { return source }
        return UIColor(
            hue: hue,
            saturation: min(max(sourceSaturation, saturation.lowerBound), saturation.upperBound),
            brightness: min(max(sourceBrightness, brightness.lowerBound), brightness.upperBound),
            alpha: alpha
        )
    }

    private static func contrastingForeground(for background: UIColor) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard background.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return .white
        }

        func linearized(_ component: CGFloat) -> CGFloat {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linearized(red)
            + 0.7152 * linearized(green)
            + 0.0722 * linearized(blue)
        return luminance > 0.179 ? .black : .white
    }
}

enum TVSpace {
    static let pageTop: CGFloat = 140    // 让出顶部 tab bar
    static let pageBottom: CGFloat = 48  // 保留焦点放大和电视过扫描安全区
    static let pageH: CGFloat = 80
    static let row: CGFloat = 28
    static let card: CGFloat = 22
}

enum TVRadius {
    static let card: CGFloat = 14
    static let cover: CGFloat = 12
    static let pill: CGFloat = 999
}

enum TVFont {
    static let pageTitle: Font = .system(size: 48, weight: .bold)
    static let sectionTitle: Font = .system(size: 28, weight: .bold)
    static let cardTitle: Font = .system(size: 22, weight: .semibold)
    static let body: Font = .system(size: 22, weight: .regular)
    static let caption: Font = .system(size: 16, weight: .regular)
    static let eyebrow: Font = .system(size: 16, weight: .semibold)
}

// MARK: - 轻量双语

/// tvOS 界面文案原本写死中文,这里按当前语言在中/英之间取串。
/// 语言判定:DEBUG 下可用 `SIMCTL_CHILD_TV_LANG=en` 强制(截图用);否则跟随系统首选语言。
enum TVLang {
    static let isEnglish: Bool = {
        #if DEBUG
        if let v = ProcessInfo.processInfo.environment["TV_LANG"], !v.isEmpty {
            return v.lowercased().hasPrefix("en")
        }
        #endif
        let lang = (UserDefaults.standard.array(forKey: "AppleLanguages")?.first as? String)
            ?? Locale.preferredLanguages.first
            ?? "zh"
        return lang.lowercased().hasPrefix("en")
    }()
}

/// 双语取串:`TVL("首页", "Home")` —— 英文环境返回第二个参数,否则中文。
/// Deprecated: 只支持中/英,其余语言退化成中文。界面文案改用 PrimuseKit 的
/// 7 语言 `PMString("key")`;本函数仅保留兼容,不应再新增调用点。
@available(*, deprecated, message: "Use PMString(\"key\") from PrimuseKit instead — TVL only covers zh/en.")
func TVL(_ zh: String, _ en: String) -> String { TVLang.isEnglish ? en : zh }

// MARK: - Hex 颜色

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v >> 16) & 0xff) / 255
        let g = Double((v >> 8) & 0xff) / 255
        let b = Double(v & 0xff) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - 格式化

enum TVFmt {
    static func time(_ s: Double) -> String {
        guard s.isFinite else { return "–:––" }
        let m = Int(s) / 60
        let r = Int(s) % 60
        return "\(m):\(String(format: "%02d", r))"
    }
    static func count(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

// MARK: - 焦点高亮

extension View {
    /// tvOS 焦点态: scale + 上抬 + 4pt 内描边(不被父级 overflow 裁切) + 辉光阴影。
    func tvFocusRing(_ focused: Bool,
                     radius: CGFloat = TVRadius.card,
                     accent: Color = TVColor.focusRing,
                     scale: CGFloat = 1.06,
                     lift: CGFloat = 12) -> some View {
        self
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(accent, lineWidth: focused ? 4 : 0)
            }
            .shadow(color: focused ? TVColor.focusShadow : TVColor.cardShadow,
                    radius: focused ? 26 : 11, x: 0, y: focused ? 18 : 8)
            .shadow(color: focused ? accent.opacity(0.45) : .clear,
                    radius: focused ? 30 : 0)
            .scaleEffect(focused ? scale : 1)
            .offset(y: focused ? -lift : 0)
            .zIndex(focused ? 1 : 0)
            .animation(.easeOut(duration: 0.22), value: focused)
    }

    /// 页面级分组面板。浅色下用细描边明确边界，深色下用低对比表面保持层级。
    func tvPanel(radius: CGFloat = 22) -> some View {
        self
            .background(TVColor.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(TVColor.cardBorder, lineWidth: 1)
            }
            .shadow(color: TVColor.cardShadow, radius: 18, y: 10)
    }
}

/// 纯渲染 label 的 ButtonStyle — 不加 tvOS 默认的聚焦平台层(大白卡)/缩放,
/// 焦点视觉完全由各 label 根据 @FocusState 自定义。tvOS 的 `.plain` 仍会画系统
/// 平台层,所以这里用空实现彻底去掉。
struct TVBareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// 可聚焦按钮 — 选中触发 action，label 闭包拿到当前焦点态自行换样式。
struct TVFocusButton<Label: View>: View {
    var radius: CGFloat
    var accent: Color
    var scale: CGFloat
    var lift: CGFloat
    var ring: Bool
    var action: () -> Void
    @ViewBuilder var label: (Bool) -> Label

    @FocusState private var focused: Bool

    init(radius: CGFloat = TVRadius.card,
         accent: Color = TVColor.focusRing,
         scale: CGFloat = 1.06,
         lift: CGFloat = 12,
         ring: Bool = true,
         action: @escaping () -> Void = {},
         @ViewBuilder label: @escaping (Bool) -> Label) {
        self.radius = radius
        self.accent = accent
        self.scale = scale
        self.lift = lift
        self.ring = ring
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            Group {
                if ring {
                    label(focused).tvFocusRing(focused, radius: radius, accent: accent, scale: scale, lift: lift)
                } else {
                    label(focused)
                }
            }
        }
        .buttonStyle(TVBareButtonStyle())
        .focused($focused)
        .focusEffectDisabled()   // 关掉 tvOS 默认白卡焦点效果,只保留自定义高亮
    }
}

// MARK: - Ambient 背景

/// 封面双色氛围背景。浅色外观使用柔和色场，深色外观保留沉浸式明暗层次。
struct TVAmbientBackdrop: View {
    var tint: Color = TVColor.brand
    var tint2: Color = Color(hex: "#1f3a5b")
    var strength: Double = 0.7

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppThemePreferences.accentHexKey)
    private var accentHex = AppThemePreferences.defaultAccentHex
    @AppStorage(AppThemePreferences.coverDrivenAmbientKey)
    private var coverDrivenAmbient = AppThemePreferences.defaultCoverDrivenAmbient
    @AppStorage(AppThemePreferences.ambientStrengthKey)
    private var ambientStrength = AppThemePreferences.defaultAmbientStrength

    var body: some View {
        let primary = coverDrivenAmbient ? tint : TVColor.brand(hex: accentHex)
        let secondary = coverDrivenAmbient ? tint2 : TVColor.brandSecondary(hex: accentHex)
        let s = AppThemePreferences.normalizedAmbientStrength(strength * ambientStrength)
        ZStack {
            TVColor.bgDeep
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack {
                    Circle()
                        .fill(primary)
                        .frame(width: w * 1.1, height: w * 1.1)
                        .blur(radius: 220)
                        .opacity((colorScheme == .dark ? 0.82 : 0.42) * s)
                        .offset(x: -w * 0.18, y: -h * 0.28)
                    Circle()
                        .fill(secondary)
                        .frame(width: w * 0.95, height: w * 0.95)
                        .blur(radius: 240)
                        .opacity((colorScheme == .dark ? 0.72 : 0.34) * s)
                        .offset(x: w * 0.28, y: h * 0.30)
                }
            }
            if colorScheme == .dark {
                LinearGradient(colors: [.black.opacity(0.20), .black.opacity(0.50)],
                               startPoint: .top, endPoint: .bottom)
            } else {
                LinearGradient(colors: [.white.opacity(0.08), TVColor.bg.opacity(0.62)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - 无封面占位

enum TVArtworkPlaceholderKind: Equatable {
    case music
    case playlist
}

/// 歌曲、专辑与歌单真正缺少封面时使用的语义占位。
///
/// 低饱和语义底色负责与相邻卡片区分，单一 SF Symbol 负责远距离识别；不再把
/// 标题首字母当作专辑封面，也不使用容易形成“靶心”观感的多重同心圆。
struct TVMusicPlaceholder: View {
    var tint: Color
    var tint2: Color
    var kind: TVArtworkPlaceholderKind = .music
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat = 0

    @Environment(\.colorScheme) private var colorScheme

    init(tint: Color, tint2: Color, kind: TVArtworkPlaceholderKind = .music,
         size: CGFloat, height: CGFloat? = nil, radius: CGFloat = 0) {
        self.tint = tint
        self.tint2 = tint2
        self.kind = kind
        self.width = size
        self.height = height ?? size
        self.radius = radius
    }

    var body: some View {
        let m = min(width, height)
        let isDark = colorScheme == .dark

        ZStack {
            LinearGradient(
                colors: [TVColor.bgElev, TVColor.bgDeep],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [tint.opacity(isDark ? 0.52 : 0.32), .clear],
                center: UnitPoint(x: 0.18, y: 0.12),
                startRadius: 0,
                endRadius: m * 0.82
            )
            RadialGradient(
                colors: [tint2.opacity(isDark ? 0.42 : 0.20), .clear],
                center: UnitPoint(x: 0.86, y: 0.92),
                startRadius: 0,
                endRadius: m * 0.72
            )

            Circle()
                .fill(TVColor.text.opacity(isDark ? 0.07 : 0.055))
                .overlay {
                    Circle().strokeBorder(
                        TVColor.text.opacity(isDark ? 0.14 : 0.10),
                        lineWidth: max(1, m * 0.004)
                    )
                }
                .frame(width: m * 0.48, height: m * 0.48)

            placeholderIcon(size: m, opacity: isDark ? 0.88 : 0.76)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func placeholderIcon(size: CGFloat, opacity: Double) -> some View {
        switch kind {
        case .music:
            Image("BrandGlyph")
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(TVColor.text.opacity(opacity))
                .frame(width: size * 0.24, height: size * 0.24)
        case .playlist:
            Image(systemName: "music.note.list")
                .font(.system(size: size * 0.19, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(TVColor.text.opacity(opacity))
        }
    }
}

// MARK: - 艺术家字母头像

/// 仅用于艺术家等人物身份的 monogram；歌曲和专辑缺图使用 `TVMusicPlaceholder`。
struct TVCoverArt: View {
    var tint: Color
    var tint2: Color
    var glyph: String
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat = 0

    init(tint: Color, tint2: Color, glyph: String, size: CGFloat, height: CGFloat? = nil, radius: CGFloat = 0) {
        self.tint = tint; self.tint2 = tint2; self.glyph = glyph
        self.width = size; self.height = height ?? size; self.radius = radius
    }
    init(album: TVAlbum, size: CGFloat, height: CGFloat? = nil, radius: CGFloat = 0) {
        self.init(tint: album.tint, tint2: album.tint2, glyph: album.glyph, size: size, height: height, radius: radius)
    }

    var body: some View {
        let m = min(width, height)
        ZStack {
            LinearGradient(colors: [tint, tint2], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [.white.opacity(0.35), .clear],
                           center: UnitPoint(x: 0.3, y: 0.25),
                           startRadius: 0, endRadius: m * 0.6)
            ForEach([0.42, 0.34, 0.26], id: \.self) { r in
                Circle()
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.6)
                    .frame(width: m * r * 2, height: m * r * 2)
            }
            Text(glyph)
                .font(.system(size: glyph.count > 1 ? m * 0.26 : m * 0.38, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
#endif

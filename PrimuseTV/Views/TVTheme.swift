#if os(tvOS)
import SwiftUI

// MARK: - 设计 token
//
// 对应 design/猿音/scenes/tvos.jsx + theme.jsx 的暗色主题。tvOS 全程暗色、
// 字号放大适配 10ft 观看距离、焦点用 scale + lift + 4pt 内描边高亮 + 辉光。

enum TVColor {
    static let bg          = Color(hex: "#000000")
    static let bgDeep      = Color(hex: "#0a0a0a")
    static let bgElev      = Color(hex: "#1a1715")
    static let text        = Color(hex: "#f3eee7")
    static func textAlpha(_ a: Double) -> Color { Color(hex: "#f3eee7").opacity(a) }
    static let textMuted   = textAlpha(0.72)
    static let textFaint   = textAlpha(0.55)
    static let textGhost   = textAlpha(0.40)
    static let card        = Color.white.opacity(0.06)
    static let cardElev    = Color.white.opacity(0.10)
    static let cardBorder  = Color.white.opacity(0.12)
    static let divider     = Color.white.opacity(0.10)
    static let brand       = Color(hex: "#c96442")
    static let ok          = Color(hex: "#7ed187")
    static let warn        = Color(hex: "#f0b078")
    static let bad         = Color(hex: "#ff7565")
}

enum TVSpace {
    static let pageTop: CGFloat = 140    // 让出顶部 tab bar
    static let pageBottom: CGFloat = 72  // 让出底部 now-playing 条(已收窄)
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
                     accent: Color = TVColor.brand,
                     scale: CGFloat = 1.06,
                     lift: CGFloat = 12) -> some View {
        self
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(accent, lineWidth: focused ? 4 : 0)
            }
            .shadow(color: .black.opacity(focused ? 0.52 : 0.30),
                    radius: focused ? 26 : 11, x: 0, y: focused ? 18 : 8)
            .shadow(color: focused ? accent.opacity(0.45) : .clear,
                    radius: focused ? 30 : 0)
            .scaleEffect(focused ? scale : 1)
            .offset(y: focused ? -lift : 0)
            .zIndex(focused ? 1 : 0)
            .animation(.easeOut(duration: 0.22), value: focused)
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
         accent: Color = TVColor.brand,
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

/// 对应 theme.jsx 的 AmbientBackdrop: 两个被高斯模糊的封面色斑 + 一层暗罩。
struct TVAmbientBackdrop: View {
    var tint: Color = TVColor.brand
    var tint2: Color = Color(hex: "#1f3a5b")
    var strength: Double = 0.7

    var body: some View {
        let s = max(0, min(1, strength))
        ZStack {
            TVColor.bgDeep
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack {
                    Circle()
                        .fill(tint)
                        .frame(width: w * 1.1, height: w * 1.1)
                        .blur(radius: 220)
                        .opacity(0.85 * s)
                        .offset(x: -w * 0.18, y: -h * 0.28)
                    Circle()
                        .fill(tint2)
                        .frame(width: w * 0.95, height: w * 0.95)
                        .blur(radius: 240)
                        .opacity(0.75 * s)
                        .offset(x: w * 0.28, y: h * 0.30)
                }
            }
            LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.62)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - 程序化封面

/// 对应 theme.jsx 的 CoverArt: tint→tint2 渐变 + 左上高光 + 同心环 + 字形。
/// 默认正方形；传 height 可画矩形(歌单磁贴)。
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

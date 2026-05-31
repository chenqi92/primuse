#if os(tvOS)
import SwiftUI

/// tvOS 设计 token — 跟 macOS 端 PrimuseTheme 同义但更克制 (无玻璃/经典模式切换,
/// 全暗色, 字号基础 +20% 适配 10ft 观看距离, 焦点用 1.06 缩放 + 4pt accent 边框)。
enum TVColor {
    static let bg          = Color(red: 0.06, green: 0.05, blue: 0.04)      // #100D0A
    static let bgElev      = Color(red: 0.10, green: 0.09, blue: 0.08)      // #1A1714
    static let bgDeep      = Color(red: 0.03, green: 0.03, blue: 0.02)
    static let text        = Color(red: 0.95, green: 0.93, blue: 0.91)      // #F3EEE7
    static let textMuted   = Color(red: 0.95, green: 0.93, blue: 0.91).opacity(0.72)
    static let textFaint   = Color(red: 0.95, green: 0.93, blue: 0.91).opacity(0.50)
    static let divider     = Color.white.opacity(0.10)
    static let card        = Color.white.opacity(0.06)
    static let cardBorder  = Color.white.opacity(0.12)
    static let brand       = Color(red: 0.79, green: 0.39, blue: 0.26)      // #C96442
}

enum TVSpace {
    static let pageH: CGFloat = 80      // safe area 加大
    static let pageV: CGFloat = 60
    static let row: CGFloat = 40
    static let card: CGFloat = 28
}

enum TVRadius {
    static let card: CGFloat = 18
    static let cover: CGFloat = 14
    static let pill: CGFloat = 999
}

enum TVFont {
    static let pageTitle: Font = .system(size: 64, weight: .bold)
    static let sectionTitle: Font = .system(size: 36, weight: .semibold)
    static let cardTitle: Font = .system(size: 24, weight: .semibold)
    static let body: Font = .system(size: 22, weight: .regular)
    static let caption: Font = .system(size: 18, weight: .regular)
}

/// 焦点容器 — 焦点态时 scale 1.06 + 提升 + 4pt accent 边框 + 微 shadow。
struct TVFocusable<Content: View>: View {
    var content: Content
    var radius: CGFloat = TVRadius.card
    var accent: Color = TVColor.brand

    @FocusState private var focused: Bool
    @Environment(\.isFocused) private var envFocused

    init(radius: CGFloat = TVRadius.card,
         accent: Color = TVColor.brand,
         @ViewBuilder content: () -> Content) {
        self.radius = radius
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(accent, lineWidth: 4)
                }
            }
            .scaleEffect(focused ? 1.06 : 1.0)
            .shadow(color: focused ? accent.opacity(0.45) : .clear,
                    radius: focused ? 30 : 0, x: 0, y: focused ? 12 : 0)
            .focusable()
            .focused($focused)
            .animation(.easeOut(duration: 0.22), value: focused)
    }
}

/// tvOS 主页大背景 — 跟 macOS AmbientBackdrop 同语义, 但布局适配 1920×1080。
struct TVAmbientBackdrop: View {
    var accent: Color = TVColor.brand
    var strength: Double = 0.7

    var body: some View {
        ZStack {
            TVColor.bgDeep
            Circle()
                .fill(accent.opacity(0.55))
                .frame(width: 1100, height: 1100)
                .blur(radius: 220)
                .offset(x: -260, y: -200)
            Circle()
                .fill(accent.opacity(0.30))
                .frame(width: 900, height: 900)
                .blur(radius: 200)
                .offset(x: 360, y: 280)
            LinearGradient(
                colors: [Color.black.opacity(0.35), Color.black.opacity(0.6)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .opacity(strength)
        .allowsHitTesting(false)
    }
}
#endif

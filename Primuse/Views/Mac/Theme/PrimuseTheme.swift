#if os(macOS)
import SwiftUI
import AppKit

// MARK: - Appearance Mode

/// 整体外观模式 — Liquid Glass (透明 + 模糊) 或 Classic Material (实色 + 细分割线)。
enum PMAppearanceMode: String, CaseIterable, Codable, Sendable {
    case glass
    case classic
}

private struct PMAppearanceModeKey: EnvironmentKey {
    static let defaultValue: PMAppearanceMode = .glass
}

extension EnvironmentValues {
    var pmAppearance: PMAppearanceMode {
        get { self[PMAppearanceModeKey.self] }
        set { self[PMAppearanceModeKey.self] = newValue }
    }
}

// MARK: - Color Tokens

/// 设计稿里的 CSS variable 直译成 SwiftUI Color。所有半透明值都跟暗色 / 浅色模式相关。
enum PMColor {
    // 文本
    static let text       = dyn(dark: hex(0xF3EEE7),               light: hex(0x1F1C19))
    static let textMuted  = dyn(dark: hex(0xF3EEE7).opacity(0.72), light: hex(0x1F1C19).opacity(0.66))
    static let textFaint  = dyn(dark: hex(0xF3EEE7).opacity(0.50), light: hex(0x1F1C19).opacity(0.46))

    // 背景
    static let bg     = dyn(dark: hex(0x1A1715), light: hex(0xF6F4EF))
    static let bgElev = dyn(dark: hex(0x2A2522), light: hex(0xFFFFFF))
    static let bgDeep = dyn(dark: hex(0x0D0C0A), light: hex(0xE9E3DA))
    /// 大播放器恒为暗底 (设计稿 AmbientBackdrop dark=true 用的 #0E0D0B), 不随系统浅色
    /// 变亮 —— 否则浅色模式下白色歌词 / 按钮在浅底上看不清。
    static let ambientDarkBase = hex(0x0E0D0B)

    // 侧栏 (玻璃半透 + 经典实色两套, 由 modifier 选择)
    static let sidebarGlass   = dyn(dark: hex(0x0A0907).opacity(0.85), light: hex(0xEEE8DC).opacity(0.65))
    static let sidebarClassic = dyn(dark: hex(0x0F0D0B),               light: hex(0xEBE5D9))

    /// 底部播放栏玻璃模式的半透色 (设计稿 --pm-glass-fill): 盖在 NSVisualEffectView
    /// 模糊层上, 让底栏是"半透材质"而不是实色卡片, 跟窗口融为一体。
    static let barGlassFill = dyn(dark: hex(0x3A342E).opacity(0.55), light: Color.white.opacity(0.55))

    // 分割线
    static let divider       = dyn(dark: Color.white.opacity(0.10), light: Color.black.opacity(0.10))
    static let dividerStrong = dyn(dark: Color.white.opacity(0.20), light: Color.black.opacity(0.18))

    // 卡片
    static let card       = dyn(dark: Color.white.opacity(0.06), light: hex(0xFFFFFF))
    static let cardBorder = dyn(dark: Color.white.opacity(0.10), light: Color.black.opacity(0.10))

    // 状态色 (跨模式一致)
    static let flac = hex(0x7ED187)
    static let dsd  = hex(0xB89EEE)
    static let ok   = hex(0x7ED187)
    static let warn = hex(0xF0B078)
    static let bad  = hex(0xFF7565)

    // 默认品牌色 (赤陶), 实际 accent 由 ThemeService 动态驱动
    static let brand = hex(0xC96442)

    // 行 hover (selected 由 modifier 用 accent 拼)
    static let rowHover = dyn(dark: Color.white.opacity(0.07), light: Color.black.opacity(0.05))

    // 玻璃按钮态
    static let glassBtn      = dyn(dark: Color.white.opacity(0.12), light: Color.black.opacity(0.06))
    static let glassBtnHover = dyn(dark: Color.white.opacity(0.20), light: Color.black.opacity(0.10))

    // Material 按钮态
    static let matBtn      = dyn(dark: Color.white.opacity(0.10), light: Color.black.opacity(0.05))
    static let matBtnHover = dyn(dark: Color.white.opacity(0.16), light: Color.black.opacity(0.09))

    // 桌面歌词调色板 (用户可选)
    static let desktopPalette: [Color] = [
        hex(0xFFCC66), hex(0xFF7676), hex(0xFF9ED1),
        hex(0xA995FF), hex(0x76C6FF), hex(0x7AF0C5),
        hex(0x9CE070), hex(0xF0F0F0), hex(0x1A1A1A),
    ]

    // 用户可选品牌色
    static let brandPalette: [Color] = [
        hex(0xC96442), hex(0x0A84FF), hex(0x1F8A5B), hex(0x5E6B87), hex(0xA0522D),
    ]
}

/// 把 #RRGGBB 直接当 Color 用。
@inline(__always)
private func hex(_ rgb: UInt32) -> Color {
    let r = Double((rgb >> 16) & 0xFF) / 255.0
    let g = Double((rgb >> 8)  & 0xFF) / 255.0
    let b = Double((rgb)       & 0xFF) / 255.0
    return Color(red: r, green: g, blue: b)
}

/// 用 NSColor.init(name:dynamicProvider:) 拼一个跟随系统外观切换的 SwiftUI Color。
private func dyn(dark: Color, light: Color) -> Color {
    let nsColor = NSColor(name: nil) { appearance in
        let darkNames: Set<NSAppearance.Name> = [
            .darkAqua, .vibrantDark,
            .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark,
        ]
        let isDark = darkNames.contains(appearance.name)
        return NSColor(isDark ? dark : light)
    }
    return Color(nsColor: nsColor)
}

// MARK: - Spacing / Radius

enum PMSpace {
    static let xxs: CGFloat = 2
    static let xs:  CGFloat = 4
    static let s:   CGFloat = 6
    static let s8:  CGFloat = 8
    static let s10: CGFloat = 10
    static let m:   CGFloat = 12
    static let m14: CGFloat = 14
    static let m16: CGFloat = 16
    static let l:   CGFloat = 18
    static let l24: CGFloat = 24
    static let xl:  CGFloat = 28
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 36
    static let pagePadH: CGFloat = 32
    static let pagePadV: CGFloat = 28
}

enum PMRadius {
    static let xs: CGFloat = 4
    static let s:  CGFloat = 6
    static let m:  CGFloat = 8
    static let m10: CGFloat = 10
    static let l:  CGFloat = 12
    static let l14: CGFloat = 14
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 18
    static let pill: CGFloat = 999
}

enum PMSize {
    /// 设计稿 TitleBar 标 44pt, 但跟 macOS Tahoe 实际 toolbar 高度 (48-52pt) 对比偏矮,
    /// 跟设计 PNG 视觉对比也偏矮一点。提到 48pt 跟 macOS 系统 toolbar 接近, 同时给搜索
    /// 框 / 按钮更多呼吸空间, 不至于看起来挤。
    static let titlebar: CGFloat = 48
    static let bottomBar: CGFloat = 74
    static let sidebarDefault: CGFloat = 220
    static let sidebarMin: CGFloat = 180
    static let sidebarMax: CGFloat = 300
    static let sidebarCollapsed: CGFloat = 56

    static let trafficLight: CGFloat = 12
    static let trafficLightMini: CGFloat = 11

    static let smallBtn: CGFloat = 24
    static let medBtn: CGFloat = 26
    static let bigBtn: CGFloat = 32
    static let playBtn: CGFloat = 36
}

// MARK: - Typography

enum PMFont {
    /// SF + PingFang 系统字体 (SwiftUI 默认就是这套, 我们只是统一字号 / 字重)。
    // 页面主标题
    static func pageTitle(_ size: CGFloat = 32) -> Font {
        .system(size: size, weight: .bold).leading(.tight)
    }
    static let pageTitleXL: Font = .system(size: 44, weight: .bold).leading(.tight)

    // 卡片 / 侧栏标题
    static let sectionTitle: Font = .system(size: 17, weight: .semibold)
    static let cardTitle:    Font = .system(size: 14, weight: .semibold)
    static let cardTitleS:   Font = .system(size: 13.5, weight: .semibold)

    // 正文
    static let body:    Font = .system(size: 13, weight: .regular)
    static let bodyM:   Font = .system(size: 12.5, weight: .medium)
    static let bodyS:   Font = .system(size: 12, weight: .regular)
    static let caption: Font = .system(size: 11, weight: .regular)
    static let captionS: Font = .system(size: 10.5, weight: .regular)

    // 大数字 (统计 / 计数)
    static let bigNumber: Font = .system(size: 28, weight: .semibold).monospacedDigit()

    // 等宽 (时间码 / spec 号)
    static let mono:    Font = .system(size: 11, design: .monospaced)
    static let monoXS:  Font = .system(size: 10.5, design: .monospaced)
    static let monoTime: Font = .system(size: 10.5, design: .monospaced).monospacedDigit()

    // 大歌词 (基础 30, 可乘 lyricsFontScale 0.7..1.8)
    static func lyricsCurrent(scale: CGFloat) -> Font {
        .system(size: 30 * scale, weight: .semibold)
    }
    static func lyricsAround(scale: CGFloat) -> Font {
        .system(size: 22 * scale, weight: .regular)
    }
    static func lyricsTranslation(scale: CGFloat) -> Font {
        .system(size: 13 * scale, weight: .regular).italic()
    }
    static func lyricsFullscreenCurrent(scale: CGFloat) -> Font {
        .system(size: 44 * scale, weight: .semibold)
    }
    static func lyricsFullscreenAround(scale: CGFloat) -> Font {
        .system(size: 28 * scale, weight: .regular)
    }
}

// MARK: - Glass / Material modifiers

/// 玻璃面板: 玻璃模式下 ultraThinMaterial + 内描边, 经典模式下退化成 bg-elev 实色。
struct PMGlass: ViewModifier {
    @Environment(\.pmAppearance) private var mode
    var cornerRadius: CGFloat = PMRadius.l
    var stroke: Bool = true

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    if mode == .glass {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.ultraThinMaterial)
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                    } else {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(PMColor.bgElev)
                    }
                }
            }
            .overlay {
                if stroke {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                }
            }
    }
}

/// 卡片背景 (跟 PMGlass 类似, 但默认更"扁平", 不带玻璃模糊 — 用于 Home 数据卡)。
struct PMCard: ViewModifier {
    @Environment(\.pmAppearance) private var mode
    var cornerRadius: CGFloat = PMRadius.l
    var padding: CGFloat? = nil

    func body(content: Content) -> some View {
        Group {
            if let padding {
                content.padding(padding)
            } else {
                content
            }
        }
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(mode == .glass
                          ? AnyShapeStyle(Material.ultraThinMaterial)
                          : AnyShapeStyle(PMColor.bgElev))
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(PMColor.card)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }
}

extension View {
    /// 玻璃 / 材料容器 (跟随 pmAppearance 自动切换两套外观)。
    func pmGlass(cornerRadius: CGFloat = PMRadius.l, stroke: Bool = true) -> some View {
        modifier(PMGlass(cornerRadius: cornerRadius, stroke: stroke))
    }

    /// 卡片背景。
    func pmCard(cornerRadius: CGFloat = PMRadius.l, padding: CGFloat? = nil) -> some View {
        modifier(PMCard(cornerRadius: cornerRadius, padding: padding))
    }

    /// 把整个视图渲染到 NSVisualEffectView 之上 — 用在主窗口背景, 让玻璃模式真有底层模糊可吸。
    func pmWindowBackground() -> some View {
        background(NSVisualEffectBackdrop().ignoresSafeArea())
    }
}

// MARK: - NSVisualEffectView bridge

struct NSVisualEffectBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .followsWindowActiveState
        v.isEmphasized = false
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
    }
}

// MARK: - Ambient Backdrop

/// 跟设计稿里的 `AmbientBackdrop` 等价: 多个 radial-gradient 叠加 + 强模糊, 由 accent / dark accent
/// 拼出当前歌曲的氛围。strength 控制整体不透明度 (0..1)。
struct AmbientBackdrop: View {
    var accent: Color
    var darkAccent: Color
    var strength: Double = 0.7
    /// 恒暗模式: 底色用固定深色 (而非随系统切换的 bgDeep)。大播放器需要它,
    /// 这样浅色系统外观下背景也保持暗, 白色歌词 / 浮动按钮才有对比。
    var forceDark: Bool = false

    var body: some View {
        ZStack {
            // 底色
            (forceDark ? PMColor.ambientDarkBase : PMColor.bgDeep)

            // 三个色斑
            Circle()
                .fill(accent.opacity(0.55))
                .frame(width: 720, height: 720)
                .blur(radius: 140)
                .offset(x: -180, y: -160)

            Circle()
                .fill(darkAccent.opacity(0.65))
                .frame(width: 640, height: 640)
                .blur(radius: 160)
                .offset(x: 220, y: 200)

            Circle()
                .fill(accent.opacity(0.35))
                .frame(width: 480, height: 480)
                .blur(radius: 120)
                .offset(x: 60, y: -60)

            // 暗化层 + 一层 noise 般的细 grain, 防止纯色过曝
            LinearGradient(
                colors: [Color.black.opacity(0.35), Color.black.opacity(0.55)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .opacity(strength)
        .compositingGroup()
        .drawingGroup()
        .allowsHitTesting(false)
    }
}

// MARK: - Format pills (FLAC / DSD / MP3 …)

/// 跟设计稿里 `pm-pill` 风格匹配的小标签。
struct PMFormatPill: View {
    let text: String
    var color: Color = PMColor.textMuted

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .tracking(0.4)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: .rect(cornerRadius: 3))
            .foregroundStyle(color)
    }

    static func forFormat(_ format: String?) -> PMFormatPill {
        let upper = (format ?? "").uppercased()
        switch upper {
        case "FLAC", "ALAC", "APE", "WAV", "AIFF":
            return PMFormatPill(text: upper, color: PMColor.flac)
        case "DSD", "DSF", "DFF":
            return PMFormatPill(text: upper, color: PMColor.dsd)
        case "":
            return PMFormatPill(text: "—", color: PMColor.textFaint)
        default:
            return PMFormatPill(text: upper, color: PMColor.textMuted)
        }
    }
}

// MARK: - Round icon button

/// 圆形 icon 按钮 — 跟设计稿的 `pm-glass-btn` / `pm-mat-btn` 视觉一致。
struct PMRoundBtn: View {
    enum Style { case glass, material, accent, plain }

    var icon: String
    var size: CGFloat = PMSize.medBtn
    var iconSize: CGFloat = 13
    var style: Style = .glass
    var isActive: Bool = false
    var help: LocalizedStringKey? = nil
    var action: () -> Void

    @Environment(\.pmAppearance) private var mode
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background(background, in: .circle)
                .overlay {
                    Circle().strokeBorder(borderColor, lineWidth: 0.5)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(helpText)
        .animation(.easeOut(duration: 0.12), value: hover)
        .animation(.easeOut(duration: 0.12), value: isActive)
    }

    private var helpText: Text {
        if let help { return Text(help) }
        return Text(verbatim: "")
    }

    private var foreground: Color {
        switch style {
        case .accent:   return .white
        case .plain:    return isActive ? PMColor.brand : PMColor.text
        case .glass, .material:
            return isActive ? PMColor.brand : PMColor.text
        }
    }

    private var background: AnyShapeStyle {
        let baseColor: Color
        switch style {
        case .accent:
            baseColor = PMColor.brand
        case .plain:
            baseColor = hover ? PMColor.glassBtn : .clear
        case .glass:
            baseColor = mode == .glass
                ? (hover ? PMColor.glassBtnHover : PMColor.glassBtn)
                : (hover ? PMColor.matBtnHover : PMColor.matBtn)
        case .material:
            baseColor = hover ? PMColor.matBtnHover : PMColor.matBtn
        }
        return AnyShapeStyle(baseColor)
    }

    private var borderColor: Color {
        switch style {
        case .accent, .plain: return .clear
        case .glass:    return PMColor.cardBorder
        case .material: return PMColor.cardBorder
        }
    }
}

// MARK: - Hover-aware row background

struct PMRowHoverBackground: ViewModifier {
    var selected: Bool = false
    var cornerRadius: CGFloat = PMRadius.s
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(selected ? PMColor.brand.opacity(0.22)
                          : (hover ? PMColor.rowHover : .clear))
            }
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: hover)
            .animation(.easeOut(duration: 0.12), value: selected)
            .contentShape(Rectangle())
    }
}

extension View {
    func pmRowBackground(selected: Bool = false, cornerRadius: CGFloat = PMRadius.s) -> some View {
        modifier(PMRowHoverBackground(selected: selected, cornerRadius: cornerRadius))
    }
}

// MARK: - Window chrome

/// Small AppKit bridge for windows where SwiftUI's hidden title bar still
/// leaves a top safe-area gutter. SwiftUI owns the layout; this only adjusts
/// the NSWindow chrome to let our custom title bars occupy the real top edge.
struct PMWindowChromeConfigurator: NSViewRepresentable {
    var hidesStandardButtons: Bool = true

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configure(window: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(window: nsView.window) }
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.toolbar = nil
        window.backgroundColor = .clear

        guard hidesStandardButtons else { return }
        [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton,
        ].forEach { type in
            window.standardWindowButton(type)?.isHidden = true
        }
    }
}

private struct PMWindowResolver: NSViewRepresentable {
    var onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}

// MARK: - Force-hide NSScrollView scrollers

/// SwiftUI 的 `.scrollIndicators(.hidden)` 在用户系统设置「总是显示滚动条」时
/// 会被忽略 — Apple 的 SDK 文档明确说明 indicator visibility 仅在 "Auto" /
/// "When scrolling" 模式下才生效。
///
/// 这个 NSViewRepresentable 通过反向遍历 view hierarchy 找到包裹 SwiftUI
/// ScrollView 的 NSScrollView, 然后强制隐藏它的两个 NSScroller (无视系统
/// 偏好), 用在那种空间紧凑、滚动条会很碍眼的 popover 场景。
private struct PMNSScrollerHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { hide(from: view) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { hide(from: nsView) }
    }
    private func hide(from view: NSView) {
        // 沿 superview 向上找 NSScrollView (SwiftUI ScrollView 在 macOS 上
        // 实际就是 NSScrollView)。
        var node: NSView? = view.superview
        while let n = node {
            if let sv = n as? NSScrollView {
                sv.hasVerticalScroller = false
                sv.hasHorizontalScroller = false
                sv.verticalScroller?.isHidden = true
                sv.horizontalScroller?.isHidden = true
                sv.scrollerStyle = .overlay
                sv.autohidesScrollers = true
                return
            }
            node = n.superview
        }
    }
}

extension View {
    /// 强制隐藏被这个 View 所在的 NSScrollView 上的所有滚动条 — 即便用户系统
    /// 设置是「总是显示滚动条」也无视。仅 macOS 有效。
    func pmForceHideScrollers() -> some View {
        background(PMNSScrollerHider().allowsHitTesting(false).frame(width: 0, height: 0))
    }

    /// 给 SwiftUI 横向 ScrollView 加上"鼠标点击拖动平移"能力 —— 默认 SwiftUI
    /// ScrollView 只响应触控板/滚轮, 不支持鼠标按住拖动。这个 modifier 用
    /// NSPanGestureRecognizer 在外层 NSScrollView 上挂上 pan handler, 把鼠标
    /// 拖动距离换算成 scroll offset。
    func pmEnableHorizontalDragScroll() -> some View {
        background(PMHorizontalDragScroll().allowsHitTesting(false).frame(width: 0, height: 0))
    }
}

/// 在所在 NSScrollView 上挂一个 NSPanGestureRecognizer, 鼠标按住拖动 → 改
/// scroll origin。.minimumNumberOfTouches = 1 + 鼠标按钮事件让它响应鼠标。
private struct PMHorizontalDragScroll: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async { attach(to: v, context: context) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { attach(to: nsView, context: context) }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    private func attach(to view: NSView, context: Context) {
        var node: NSView? = view.superview
        while let n = node {
            if let sv = n as? NSScrollView {
                // 避免重复挂 — 用 associated object 标记一次
                let key = "pmHorizontalDragInstalled"
                if objc_getAssociatedObject(sv, key) != nil { return }
                objc_setAssociatedObject(sv, key, true, .OBJC_ASSOCIATION_RETAIN)

                let pan = NSPanGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.handlePan(_:)))
                pan.buttonMask = 0x1   // 左键
                sv.addGestureRecognizer(pan)
                context.coordinator.scrollView = sv
                return
            }
            node = n.superview
        }
    }

    final class Coordinator: NSObject {
        weak var scrollView: NSScrollView?

        @objc func handlePan(_ gesture: NSPanGestureRecognizer) {
            guard let sv = scrollView, let doc = sv.documentView else { return }
            let translation = gesture.translation(in: sv)
            let clip = sv.contentView
            var origin = clip.bounds.origin
            origin.x -= translation.x
            // clamp 在 0..documentWidth-clipWidth
            let maxX = max(0, doc.frame.width - clip.bounds.width)
            origin.x = min(max(0, origin.x), maxX)
            clip.scroll(to: origin)
            sv.reflectScrolledClipView(clip)
            gesture.setTranslation(.zero, in: sv)
        }
    }
}

struct PMWindowTrafficLights: View {
    private enum WindowAction {
        case close
        case minimize
        case zoom
    }

    @State private var hostWindow: NSWindow?

    var body: some View {
        HStack(spacing: 8) {
            trafficButton(color: Color(red: 1.0, green: 0.372, blue: 0.341), action: .close)
                .accessibilityLabel(Text("Close"))
            trafficButton(color: Color(red: 1.0, green: 0.741, blue: 0.180), action: .minimize)
                .accessibilityLabel(Text("Minimize"))
            trafficButton(color: Color(red: 0.157, green: 0.788, blue: 0.255), action: .zoom)
                .accessibilityLabel(Text("Zoom"))
        }
        .frame(width: 52, height: 26, alignment: .center)
        .background {
            PMWindowResolver { window in
                hostWindow = window
            }
        }
    }

    private func trafficButton(color: Color, action: WindowAction) -> some View {
        Button {
            perform(action)
        } label: {
            Circle()
                .fill(color)
                .overlay {
                    Circle()
                        .strokeBorder(Color.black.opacity(0.16), lineWidth: 0.5)
                }
                .frame(width: PMSize.trafficLight, height: PMSize.trafficLight)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func perform(_ action: WindowAction) {
        guard let window = hostWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        switch action {
        case .close:
            window.performClose(nil)
        case .minimize:
            window.miniaturize(nil)
        case .zoom:
            window.zoom(nil)
        }
    }
}

// MARK: - Karaoke line

/// 卡拉 OK 风歌词行: 按 progress (0..1) 横向遮罩, 给当前字符额外光晕。
/// 适用于"逐字进度未知"的 LRC 简化情形 (按整行时间均分)。需要逐字 syllable
/// 时序时另外再做一个版本。
struct KaraokeLine: View {
    let text: String
    /// 0..1 进度, 表示当前行已经唱过多少。
    let progress: Double
    let font: Font
    let tint: Color
    /// false 时显示成"非当前行" — 没有遮罩, 整行用低饱和度文本色。
    var isCurrent: Bool = true
    var inactiveColor: Color = PMColor.text.opacity(0.42)

    var body: some View {
        ZStack(alignment: .leading) {
            // 底层: 未唱的字 (低饱和)
            Text(text)
                .font(font)
                .foregroundStyle(isCurrent ? PMColor.text.opacity(0.55) : inactiveColor)
                .multilineTextAlignment(.leading)

            // 顶层: 已唱的字, 用遮罩按比例显示
            if isCurrent {
                Text(text)
                    .font(font)
                    .foregroundStyle(tint)
                    .shadow(color: tint.opacity(0.45), radius: 14, x: 0, y: 0)
                    .multilineTextAlignment(.leading)
                    .mask {
                        GeometryReader { geo in
                            Rectangle()
                                .fill(.black)
                                .frame(width: max(0, geo.size.width * progress))
                        }
                    }
            }
        }
        .animation(.linear(duration: 0.1), value: progress)
    }
}

// MARK: - Vertical mask (lyrics column fade)

struct VerticalEdgeMask: ViewModifier {
    var startStop: Double = 0.18
    var endStop: Double = 0.82

    func body(content: Content) -> some View {
        content.mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: startStop),
                    .init(color: .black, location: endStop),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
    }
}

extension View {
    func pmVerticalFadeMask(startStop: Double = 0.18, endStop: Double = 0.82) -> some View {
        modifier(VerticalEdgeMask(startStop: startStop, endStop: endStop))
    }
}

// MARK: - User preferences key (appearance + lyrics font scale)

/// 把 macOS UI 偏好 (玻璃 / 经典模式, 歌词字号缩放, 侧栏宽度) 集中存到 UserDefaults。
@MainActor
@Observable
final class MacUIPreferences {
    static let shared = MacUIPreferences()

    var appearance: PMAppearanceMode {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Self.keyAppearance) }
    }
    var lyricsFontScale: CGFloat {
        didSet { UserDefaults.standard.set(Double(lyricsFontScale), forKey: Self.keyLyricsScale) }
    }
    var sidebarWidth: CGFloat {
        didSet { UserDefaults.standard.set(Double(sidebarWidth), forKey: Self.keySidebarWidth) }
    }
    var ambientStrength: Double {
        didSet { UserDefaults.standard.set(ambientStrength, forKey: Self.keyAmbient) }
    }

    private static let keyAppearance   = "pm.mac.appearance"
    private static let keyLyricsScale  = "pm.mac.lyricsScale"
    private static let keySidebarWidth = "pm.mac.sidebarWidth"
    private static let keyAmbient      = "pm.mac.ambientStrength"

    private init() {
        let d = UserDefaults.standard
        appearance = PMAppearanceMode(rawValue: d.string(forKey: Self.keyAppearance) ?? "") ?? .glass
        let scale = d.object(forKey: Self.keyLyricsScale) as? Double ?? 1.0
        lyricsFontScale = CGFloat(max(0.7, min(1.8, scale)))
        let width = d.object(forKey: Self.keySidebarWidth) as? Double ?? Double(PMSize.sidebarDefault)
        sidebarWidth = CGFloat(max(Double(PMSize.sidebarMin), min(Double(PMSize.sidebarMax), width)))
        ambientStrength = d.object(forKey: Self.keyAmbient) as? Double ?? 0.7
    }
}

#endif

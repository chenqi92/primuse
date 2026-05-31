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

    // 默认品牌色 (赤陶) — 用户没选时的回退, 也用在色板里"默认"项的固定展示。
    static let brandDefault = hex(0xC96442)

    /// 当前品牌色 — 用户在「外观」里选, 持久化在 MacUIPreferences。整个 Mac UI
    /// 90+ 处自定义控件 (按钮 / 进度条 / active 高亮 / ambient fallback) 的 accent
    /// 都读它, 所以改这一处即全局换色。读取发生在 view body 内, Observation 会
    /// 注册依赖, 切换后相关视图自动重渲染。@MainActor 因为读的是主线程隔离的
    /// MacUIPreferences — SwiftUI view body 本就在主线程, 90+ 调用点都满足。
    @MainActor
    static var brand: Color { MacUIPreferences.shared.brandColor }

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
        window.isMovableByWindowBackground = false
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

// MARK: - Window-safe controls

struct PMWindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        PMWindowDragRegionView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class PMWindowDragRegionView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// Native macOS slider that opts out of `isMovableByWindowBackground`.
///
/// SwiftUI's `Slider` can still be treated as draggable window background in
/// borderless/hidden-titlebar windows, which makes volume drags move the whole
/// window. Keeping this as an AppKit control lets the slider own mouse tracking.
struct PMVolumeSlider: NSViewRepresentable {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var controlSize: NSControl.ControlSize = .mini
    var accessibilityLabel: String = "Volume"

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = PMWindowSafeSlider(
            value: clampedValue,
            minValue: range.lowerBound,
            maxValue: range.upperBound,
            target: context.coordinator,
            action: #selector(Coordinator.valueChanged(_:))
        )
        slider.isContinuous = true
        slider.sliderType = .linear
        slider.sendAction(on: [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
        slider.controlSize = controlSize
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setAccessibilityLabel(accessibilityLabel)
        applyConfiguration(to: slider, context: context)
        return slider
    }

    func updateNSView(_ nsView: NSSlider, context: Context) {
        applyConfiguration(to: nsView, context: context)
    }

    private var clampedValue: Double {
        min(range.upperBound, max(range.lowerBound, value))
    }

    private func applyConfiguration(to slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.controlSize = controlSize
        slider.setAccessibilityLabel(accessibilityLabel)
        if abs(slider.doubleValue - clampedValue) > 0.0005 {
            slider.doubleValue = clampedValue
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var value: Binding<Double>

        init(value: Binding<Double>) {
            self.value = value
        }

        @objc func valueChanged(_ sender: NSSlider) {
            value.wrappedValue = sender.doubleValue
        }
    }
}

private final class PMWindowSafeSlider: NSSlider {
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        let wasMovableByBackground = window?.isMovableByWindowBackground
        window?.isMovableByWindowBackground = false
        defer {
            if let wasMovableByBackground {
                window?.isMovableByWindowBackground = wasMovableByBackground
            }
        }
        super.mouseDown(with: event)
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
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var configured: NSScrollView?
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { hide(from: view, coordinator: context.coordinator) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        // 已经找到并配置过就不再搜 —— 否则每次 updateNSView (滚动时可能很频繁) 都
        // 递归遍历一遍视图树找 NSScrollView, 自己反而成了卡顿源。
        guard context.coordinator.configured == nil else { return }
        DispatchQueue.main.async { hide(from: nsView, coordinator: context.coordinator) }
    }
    private func hide(from view: NSView, coordinator: Coordinator) {
        if coordinator.configured != nil { return }
        // 1. 这个 0×0 view 若正好在 scroll 内容里, enclosingScrollView 直接命中。
        if let sv = view.enclosingScrollView {
            configure(sv)
            coordinator.configured = sv
            return
        }
        // 2. 但我们是用 `.background(...)` 挂上去的 —— SwiftUI 把它放成 NSScrollView
        //    的"兄弟"节点, 单纯沿 superview 往上找不到它 (这正是之前隐藏不掉的根因)。
        //    改成逐层往上, 在每一层的子树里找最近的 NSScrollView。
        var ancestor: NSView? = view.superview
        var hops = 0
        while let a = ancestor, hops < 8 {
            if let sv = Self.firstScrollView(in: a) {
                configure(sv)
                coordinator.configured = sv
                return
            }
            ancestor = a.superview
            hops += 1
        }
    }

    private func configure(_ sv: NSScrollView) {
        sv.hasVerticalScroller = false
        sv.hasHorizontalScroller = false
        sv.verticalScroller?.isHidden = true
        sv.horizontalScroller?.isHidden = true
        sv.scrollerStyle = .overlay
        sv.autohidesScrollers = true
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let sv = view as? NSScrollView { return sv }
        for sub in view.subviews {
            if let found = firstScrollView(in: sub) { return found }
        }
        return nil
    }
}

extension View {
    func pmWindowDragRegion() -> some View {
        background(PMWindowDragRegion())
    }

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

    /// 只保留关闭按钮 —— 弹框 / 设置这类窗口里最小化、缩放没意义, 留一个红色
    /// 关闭灯即可。主窗口标题栏仍用默认的三色灯。
    var closeOnly: Bool = false

    @State private var hostWindow: NSWindow?

    var body: some View {
        HStack(spacing: 8) {
            trafficButton(color: Color(red: 1.0, green: 0.372, blue: 0.341), action: .close)
                .accessibilityLabel(Text("Close"))
            if !closeOnly {
                trafficButton(color: Color(red: 1.0, green: 0.741, blue: 0.180), action: .minimize)
                    .accessibilityLabel(Text("Minimize"))
                trafficButton(color: Color(red: 0.157, green: 0.788, blue: 0.255), action: .zoom)
                    .accessibilityLabel(Text("Zoom"))
            }
        }
        .frame(width: closeOnly ? PMSize.trafficLight : 52, height: 26,
               alignment: closeOnly ? .leading : .center)
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

// MARK: - Localization helper

/// Mac UI 本地化简写。用英文原文当 key, 中文译文放在 zh-Hans.lproj;
/// 其它语言 (含英文本身) 没有对应词条时回退到英文 key 本身。整套 Mac 界面
/// 的硬编码文案都走它, 这样 `Views/Mac` 不再夹带中文字面量。
@inline(__always)
func Lz(_ english: String.LocalizationValue) -> String {
    String(localized: english)
}

func PMUsesChineseBranding() -> Bool {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true
}

func PMAppDisplayName() -> String {
    PMUsesChineseBranding() ? "猿音 Primuse" : "Primuse"
}

func PMAppPrimaryDisplayName() -> String {
    PMUsesChineseBranding() ? "猿音" : "Primuse"
}

func PMAppSecondaryDisplayName() -> String? {
    PMUsesChineseBranding() ? "Primuse" : nil
}

func PMTextWithoutDesignCodes(_ text: String) -> String {
    let codePattern = #"\b(?:STATS|THEME|SCROB|CAST|META|SRC|LIB|SYS|PL|FX|ST|P|S|C|L)-(?:\d{1,3}(?:/\d{1,3})?|\*)\b"#
    var cleaned = text.replacingOccurrences(of: codePattern,
                                             with: "",
                                             options: .regularExpression)
    let cleanupPatterns = [
        #"\s*[（(]\s*[)）]\s*"#,
        #"\s*[·•|/—–-]+\s*(?:Matches design\s+sizes|与设计稿\s*尺寸一致)\s*$"#,
        #"\s*->\s*"#,
        #"^\s*[·•|/—–-]+\s*"#,
        #"\s*[·•|/—–-]+\s*$"#,
        #"\s{2,}"#
    ]
    for pattern in cleanupPatterns {
        cleaned = cleaned.replacingOccurrences(of: pattern,
                                               with: pattern == #"\s{2,}"# ? " " : "",
                                               options: .regularExpression)
    }
    return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Color scheme override (light / dark / system)

/// 用户在「外观」里选的明暗模式 — 应用到 `NSApp.appearance`, 同时驱动所有
/// `dyn()` 动态色。`.system` 时交还给系统跟随。
enum PMColorSchemeOverride: String, CaseIterable, Sendable {
    case system, light, dark
}

// MARK: - Brand monogram (应用内品牌字标)

/// 应用内统一的品牌字标 —— 品牌色渐变 squircle 叠中文 "猿" 字。Dock / 访达里是
/// 完整 app 图标 (蓝调黑胶写实风), 但那套冷色图标塞进暖橙的界面里会打架; 应用内
/// (侧栏头部 / 关于页) 改用这个跟 `PMColor.brand` 同色系的简化字标, 视觉更统一。
/// 要改字、圆角、渐变或阴影只动这一处, 两个调用点同步更新。
struct BrandMonogram: View {
    /// 出现位置 —— 决定尺寸 / 圆角 / 字号 / 阴影这组配套数值。
    enum Slot {
        case sidebar   // 侧栏头部 28pt, 品牌色自身收尾的实色渐变
        case feature   // 关于页等 96pt, 向背景深色过渡
    }

    var slot: Slot

    var body: some View {
        let isSidebar = slot == .sidebar
        let size: CGFloat   = isSidebar ? 28 : 96
        let corner: CGFloat = isSidebar ? 7  : 22
        let glyph: CGFloat  = isSidebar ? 15 : 50
        let shadowOpacity: Double = isSidebar ? 0.35 : 0.32
        let shadowRadius: CGFloat = isSidebar ? 4 : 24
        let shadowY: CGFloat      = isSidebar ? 2 : 8
        // 侧栏用品牌色自身做渐变收尾; 关于页向背景深色过渡, 跟大图卡片融合。
        let gradientEnd = isSidebar ? PMColor.brand.opacity(0.7) : PMColor.bgDeep

        return RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [PMColor.brand, gradientEnd],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay {
                // 设计稿用中文字符 monogram ("猿") 而非 SF Symbol, 更切合品牌名
                // "猿音 Primuse"。
                Text(verbatim: "猿")
                    .font(.system(size: glyph, weight: .bold))
                    .foregroundStyle(.white)
            }
            .shadow(color: PMColor.brand.opacity(shadowOpacity), radius: shadowRadius, y: shadowY)
    }
}

// MARK: - Alternate app icons (macOS dock 图标)

/// 一套可切换的 App 图标。macOS 不支持 iOS 的 `setAlternateIconName`, 只能在
/// 运行时换 dock 图标 (`NSApp.applicationIconImage`) 并持久化选择、下次启动重放;
/// Finder 里 .app 包的图标不变 (沙盒应用改不了自身包)。
struct MacAppIcon: Identifiable, Equatable, Sendable {
    /// 稳定标识。"" = 默认 (用 bundle 自带的 AppIcon-Mac)。
    let id: String
    /// 资源目录里的预览 imageset 名 (universal, 含明暗变体)。
    let previewAsset: String
    /// 本地化显示名的 key (复用 iOS 已有的 icon_* 词条)。
    let nameKey: String
    /// 这套图标的品牌色 — 仅用于色环展示, 不强行改全局 accent。
    let tint: Color

    /// 默认项 + 7 套备选, 跟资源目录里的 AppIcon{n}Preview 一一对应。
    static let all: [MacAppIcon] = [
        MacAppIcon(id: "",         previewAsset: "AppIconPreview",  nameKey: "icon_default", tint: PMColor.brandDefault),
        MacAppIcon(id: "AppIcon1", previewAsset: "AppIcon1Preview", nameKey: "icon_theme_1", tint: Color(red: 0.39, green: 0.32, blue: 0.98)),
        MacAppIcon(id: "AppIcon2", previewAsset: "AppIcon2Preview", nameKey: "icon_theme_2", tint: Color(red: 0.55, green: 0.32, blue: 0.85)),
        MacAppIcon(id: "AppIcon3", previewAsset: "AppIcon3Preview", nameKey: "icon_theme_3", tint: Color(red: 0.20, green: 0.78, blue: 0.78)),
        MacAppIcon(id: "AppIcon4", previewAsset: "AppIcon4Preview", nameKey: "icon_theme_4", tint: Color(red: 0.92, green: 0.72, blue: 0.20)),
        MacAppIcon(id: "AppIcon5", previewAsset: "AppIcon5Preview", nameKey: "icon_theme_5", tint: Color(red: 0.95, green: 0.45, blue: 0.78)),
        MacAppIcon(id: "AppIcon6", previewAsset: "AppIcon6Preview", nameKey: "icon_theme_6", tint: Color(red: 0.45, green: 0.55, blue: 0.95)),
        MacAppIcon(id: "AppIcon7", previewAsset: "AppIcon7Preview", nameKey: "icon_theme_7", tint: Color(red: 0.55, green: 0.50, blue: 0.92)),
    ]

    static func option(for id: String) -> MacAppIcon {
        all.first { $0.id == id } ?? all[0]
    }

    /// 把满幅方形预览图渲染成标准 macOS 图标外形 (连续圆角 squircle + 四周留白),
    /// 再交给 `applicationIconImage`。预览 PNG 是不带 alpha 的满幅方图, 直接当 dock
    /// 图标会又大又方, 跟系统其它图标 (含本 app 默认图标) 的圆角 + 留白对不上。
    @MainActor
    static func dockIconImage(previewAsset asset: String) -> NSImage? {
        guard let src = NSImage(named: asset) else { return nil }
        let side: CGFloat = 512
        let inset = side * 0.0977          // ≈ macOS 图标网格留白 (100 / 1024)
        let body = side - inset * 2
        let radius = body * 0.2247         // ≈ macOS 图标圆角比例
        let content = Image(nsImage: src)
            .resizable()
            .interpolation(.high)
            .frame(width: body, height: body)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .frame(width: side, height: side)   // 居中 + 四周透明留白
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return renderer.nsImage
    }
}

extension Notification.Name {
    /// App 图标切换后广播 —— 让菜单栏状态项重画图标 (它默认只设一次)。
    static let primuseAppIconChanged = Notification.Name("primuse.appIcon.changed")
}

// MARK: - User preferences key (appearance + lyrics font scale)

/// 把 macOS UI 偏好 (玻璃 / 经典模式, 歌词字号缩放, 侧栏宽度, 品牌色, 明暗模式,
/// App 图标) 集中存到 UserDefaults。
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
    var coverDrivenAmbient: Bool {
        didSet { UserDefaults.standard.set(coverDrivenAmbient, forKey: Self.keyCoverDrivenAmbient) }
    }

    /// 品牌色十六进制 (无 #)。驱动 `PMColor.brand`。
    var brandColorHex: String {
        didSet { UserDefaults.standard.set(brandColorHex, forKey: Self.keyBrand) }
    }
    /// 明暗模式覆盖。didSet 立即应用到 NSApp.appearance。
    var colorScheme: PMColorSchemeOverride {
        didSet {
            UserDefaults.standard.set(colorScheme.rawValue, forKey: Self.keyColorScheme)
            applyColorScheme()
        }
    }
    /// 当前 App 图标 id ("" = 默认)。didSet 立即换 dock 图标。
    var appIconID: String {
        didSet {
            UserDefaults.standard.set(appIconID, forKey: Self.keyAppIcon)
            applyAppIcon()
        }
    }

    /// 当前品牌色 (SwiftUI Color)。
    var brandColor: Color { Color(hex: brandColorHex) }

    private static let keyAppearance   = "pm.mac.appearance"
    private static let keyLyricsScale  = "pm.mac.lyricsScale"
    private static let keySidebarWidth = "pm.mac.sidebarWidth"
    private static let keyAmbient      = "pm.mac.ambientStrength"
    private static let keyCoverDrivenAmbient = "pm.mac.coverDrivenAmbient"
    private static let keyBrand        = "pm.mac.brandColor"
    private static let keyColorScheme  = "pm.mac.colorScheme"
    private static let keyAppIcon      = "pm.mac.appIcon"

    static let defaultBrandHex = "C96442"

    private init() {
        let d = UserDefaults.standard
        appearance = PMAppearanceMode(rawValue: d.string(forKey: Self.keyAppearance) ?? "") ?? .glass
        let scale = d.object(forKey: Self.keyLyricsScale) as? Double ?? 1.0
        lyricsFontScale = CGFloat(max(0.7, min(1.8, scale)))
        let width = d.object(forKey: Self.keySidebarWidth) as? Double ?? Double(PMSize.sidebarDefault)
        sidebarWidth = CGFloat(max(Double(PMSize.sidebarMin), min(Double(PMSize.sidebarMax), width)))
        ambientStrength = d.object(forKey: Self.keyAmbient) as? Double ?? 0.7
        coverDrivenAmbient = d.object(forKey: Self.keyCoverDrivenAmbient) as? Bool ?? true
        brandColorHex = d.string(forKey: Self.keyBrand) ?? Self.defaultBrandHex
        colorScheme = PMColorSchemeOverride(rawValue: d.string(forKey: Self.keyColorScheme) ?? "") ?? .system
        appIconID = d.string(forKey: Self.keyAppIcon) ?? ""
    }

    /// 启动时把持久化的明暗模式 + App 图标重放一遍 (didSet 在 init 期不触发,
    /// 所以必须显式调一次)。在 AppDelegate.applicationDidFinishLaunching 里调。
    func applyOnLaunch() {
        applyColorScheme()
        applyAppIcon()
    }

    /// 把 colorScheme 应用到整个 app (含 AppKit 的 mini player / 菜单栏窗口)。
    func applyColorScheme() {
        switch colorScheme {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// 换运行时 dock 图标。"" 时清空, 回退到 bundle 自带图标; 否则把预览图渲染成
    /// 标准 macOS 图标外形再设上去。完事广播一条通知, 让菜单栏图标也跟着换。
    func applyAppIcon() {
        if appIconID.isEmpty {
            NSApp.applicationIconImage = nil
        } else {
            let asset = MacAppIcon.option(for: appIconID).previewAsset
            if let shaped = MacAppIcon.dockIconImage(previewAsset: asset) {
                NSApp.applicationIconImage = shaped
            }
        }
        NotificationCenter.default.post(name: .primuseAppIconChanged, object: nil)
    }
}

#endif

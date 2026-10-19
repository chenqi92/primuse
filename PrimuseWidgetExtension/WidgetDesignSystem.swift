import SwiftUI
import WidgetKit
import PrimuseKit
#if canImport(UIKit)
import UIKit
typealias WidgetImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias WidgetImage = NSImage
#endif

extension Image {
    /// Cross-platform image init — `Image(uiImage:)` on iOS, `Image(nsImage:)`
    /// on native macOS. Lets the widget views stay platform-agnostic.
    init(widgetImage: WidgetImage) {
        #if canImport(UIKit)
        self.init(uiImage: widgetImage)
        #elseif canImport(AppKit)
        self.init(nsImage: widgetImage)
        #endif
    }
}

enum WidgetDesign {
    static let sea = Color(red: 0.078, green: 0.490, blue: 0.541)
    static let amber = Color(red: 0.941, green: 0.706, blue: 0.353)
    static let rose = Color(red: 0.86, green: 0.35, blue: 0.42)
    static let fern = Color(red: 0.24, green: 0.55, blue: 0.32)

    /// 「屏幕小组件颜色」选了单色(#320): 主题色、各类的颜色画的点缀都换成 `neutralTint`, 只有封面带颜色。
    static var prefersMonochrome: Bool {
        WidgetColorStyleStore.load() == .monochrome
    }

    /// 单色时的点缀色: 跟字一样, 浅色外观近黑、深色外观近白。
    static let neutralTint = Color.primary

    /// Brand accent driven by the user's current app icon — the main app
    /// publishes this into the App Group, the widget reads it on every
    /// render. Falls back to the default-icon vinyl blue if nothing has
    /// been published yet (fresh install before the main app first launches).
    static var brandTint: Color {
        prefersMonochrome ? neutralTint : legibleTint(BrandTintStore.load())
    }

    /// 唱片中间那块标签。单色时不能跟着字变黑: 压在深色的唱片上要看得见, 用一块浅灰。
    static var recordLabelTint: Color {
        prefersMonochrome ? Color(white: 0.78) : brandTint
    }

    private static func legibleTint(_ rgb: BrandTintStore.RGB?) -> Color {
        let source = ThemeAccentContrastPolicy.RGB(
            red: rgb?.red ?? 0.078,
            green: rgb?.green ?? 0.490,
            blue: rgb?.blue ?? 0.541
        )
        // 浅色画布照主 App 的规则压到 4.5:1;深色画布照旧往白里提 32%,再保个 4.5:1 的底。
        let lift = 0.32
        let light = ThemeAccentContrastPolicy.legible(source, for: .light)
        let dark = ThemeAccentContrastPolicy.legible(
            ThemeAccentContrastPolicy.RGB(
                red: source.red + (1 - source.red) * lift,
                green: source.green + (1 - source.green) * lift,
                blue: source.blue + (1 - source.blue) * lift
            ),
            for: .dark
        )
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            let tint = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: tint.red, green: tint.green, blue: tint.blue, alpha: 1)
        })
        #else
        return Color(nsColor: NSColor(name: nil) { appearance in
            let tint = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: tint.red, green: tint.green, blue: tint.blue, alpha: 1)
        })
        #endif
    }

    /// 电台、有声书、播客的颜色,与 App 首页顶部切换、资料库同一份色值(`ListeningSpace.fixedTint`,
    /// 或用户在 App 里给这一类挑的颜色);音乐跟主题色走 `brandTint`。「跟随封面」和 App 一样
    /// 用这一类自己最后在播时的封面色(`ListeningSpaceArtworkTintStore`),没记过时是自带色。
    static func tint(for space: ListeningSpace) -> Color {
        // 单色时几个台、几本书并排, 不再拿其中一张封面的颜色去染整块(#320)。
        if prefersMonochrome { return neutralTint }
        guard let standard = space.fixedTint else { return brandTint }
        var fixed = standard
        if let shared = ListeningSpaceTintPreferences.sharedDefaults {
            let choice = ListeningSpaceTintPreferences.choice(for: space, in: shared)
                .resolvingArtwork(ListeningSpaceArtworkTintStore.hex(for: space, in: shared))
            switch choice {
            case .standard, .artwork:
                break
            case .theme:
                return brandTint
            case .fixed(let hex):
                fixed = ListeningSpaceTint.legible(hex: hex) ?? standard
            }
        }
        let light = ListeningSpaceTint.components(fixed.light)
        let dark = ListeningSpaceTint.components(fixed.dark)
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
        #else
        return Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
        #endif
    }

    static let canvasBase = Color(red: 0.075, green: 0.085, blue: 0.10)
    static let lightCanvasBase = Color(red: 0.97, green: 0.975, blue: 0.98)
    static let strongText = Color.primary
    static let secondaryText = Color.secondary
    static let tertiaryText = Color.secondary
    static let hairline = Color.primary.opacity(0.10)


}

struct WidgetCanvas<Content: View>: View {
    let content: Content
    var padding: CGFloat
    var showsContours: Bool
    var coverImageName: String?
    var tint: Color?

    init(padding: CGFloat = 16, showsContours: Bool = true, coverImageName: String? = nil,
         tint: Color? = nil, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.showsContours = showsContours
        self.coverImageName = coverImageName
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(for: .widget) {
                WidgetCanvasBackground(showsContours: showsContours, coverImageName: coverImageName, tint: tint)
            }
    }
}

struct WidgetCanvasBackground: View {
    var showsContours = true
    var coverImageName: String?
    var tint: Color?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        ZStack(alignment: .topTrailing) {
            colorScheme == .dark ? WidgetDesign.canvasBase : WidgetDesign.lightCanvasBase
            // 单色时底色不染色, 也不铺第一张封面的模糊图: 旁边还有别的封面, 会跟它们撞色(#320)。
            if renderingMode == .fullColor, let tint, !WidgetDesign.prefersMonochrome {
                GeometryReader { geometry in
                    ZStack {
                        RadialGradient(colors: [tint.opacity(colorScheme == .dark ? 0.24 : 0.16), .clear],
                                       center: .topTrailing, startRadius: 0, endRadius: geometry.size.width)
                        if let coverImageName {
                            WidgetCoverImageView(coverImageName: coverImageName, cornerRadius: 0)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .clipped().blur(radius: 24)
                                .opacity(colorScheme == .dark ? 0.16 : 0.10)
                        }
                    }
                }
                .clipped()
            }
            if showsContours {
                GeometryReader { geometry in
                    let side = geometry.size.width * 0.85
                    ZStack {
                        ForEach(0..<5) { ring in
                            Circle().strokeBorder(WidgetDesign.brandTint.opacity(colorScheme == .dark ? 0.055 : 0.035), lineWidth: 1)
                                .padding(CGFloat(ring) * 13)
                        }
                    }
                    .frame(width: side, height: side)
                    .offset(x: geometry.size.width - side * 0.62, y: -side * 0.45)
                }
                .clipped()
            }
        }
    }
}

struct WidgetRecordSleeve: View {
    @Environment(\.colorScheme) private var colorScheme
    let coverImageName: String?
    var isPlaying = false
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let sleeve = side * 0.79
            ZStack(alignment: .leading) {
                if renderingMode == .fullColor {
                    ZStack {
                        Circle().fill(Color(white: 0.12).gradient)
                        ForEach(0..<5) { ring in
                            Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.6)
                                .padding(CGFloat(ring) * 4 + 6)
                        }
                        Circle().fill(WidgetDesign.recordLabelTint).frame(width: sleeve * 0.30, height: sleeve * 0.30)
                        Circle().fill(Color(white: 0.12)).frame(width: 4, height: 4)
                        Circle().fill(AngularGradient(colors: [.clear, .white.opacity(0.20), .clear, .clear, .white.opacity(0.10), .clear], center: .center))
                    }
                    .frame(width: sleeve * 0.94, height: sleeve * 0.94)
                    .rotationEffect(.degrees(isPlaying ? 24 : -18))
                    .offset(x: side - sleeve * 0.94)
                }
                WidgetCoverImageView(coverImageName: coverImageName, cornerRadius: 7)
                    .frame(width: sleeve, height: sleeve)
                    .background {
                        if renderingMode == .fullColor {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(colorScheme == .dark ? WidgetDesign.canvasBase : WidgetDesign.lightCanvasBase)
                        }
                    }
                    .rotationEffect(.degrees(renderingMode == .fullColor ? (isPlaying ? -5 : -2) : 0))
                    .shadow(color: .black.opacity(renderingMode == .fullColor ? 0.15 : 0), radius: 4, x: 0, y: 4)
            }
            .frame(width: side, height: side)
            .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: isPlaying)
        }
        .accessibilityHidden(true)
    }
}

struct WidgetPlaybackArtwork: View {
    let state: PlaybackState

    var body: some View {
        if state.isSpokenWord || state.isLiveStream {
            WidgetCoverImageView(coverImageName: state.coverImageName, cornerRadius: 10)
        } else {
            WidgetRecordSleeve(coverImageName: state.coverImageName, isPlaying: state.isPlaying)
        }
    }
}

struct WidgetPlaybackButton: View {
    let state: PlaybackState
    var size: CGFloat = 34

    var body: some View {
        Button(intent: PrimuseSetPlayingIntent(value: !state.isPlaying)) {
            WidgetGlassKeyLabel(
                symbol: state.isPlaying ? (state.isLiveStream ? "stop.fill" : "pause.fill") : "play.fill",
                diameter: size
            )
        }
        .buttonStyle(.plain)
        .invalidatableContent()
        .accessibilityLabel(PMString(state.isPlaying ? "ext.control.pause" : "ext.control.play"))
    }
}

/// 播放 / 暂停这类键的底(#320): 不管「屏幕小组件颜色」选的什么, 都是半透明的中性圆片加一圈细边,
/// 像毛玻璃, 不跟封面或主题色撞色, 电台的停止键也不再是红的。
///
/// 不用 `Material`: 小组件里它未必真的模糊底下的封面, 半透明的白 / 黑片在哪种外观下样子都确定。
/// 圆片和上沿的高光只在全彩外观画, 色调、透明外观下它们会被渲染成一块实心的片(#190), 那时只留细边。
/// `overArtwork` 是压在封面上的键: 深色外观压一层暗、浅色压一层亮, 什么颜色的封面上都看得清符号。
struct WidgetGlassKeyBackground: View {
    var overArtwork = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let dark = colorScheme == .dark
        ZStack {
            if renderingMode == .fullColor {
                Circle().fill(fill(dark: dark))
                Circle().fill(LinearGradient(
                    colors: [Color.white.opacity(dark ? 0.16 : 0.42), .clear],
                    startPoint: .top,
                    endPoint: .center
                ))
                Circle().strokeBorder(stroke(dark: dark), lineWidth: 0.75)
            } else {
                Circle().strokeBorder(Color.primary.opacity(0.30), lineWidth: 0.75)
            }
        }
        .accessibilityHidden(true)
    }

    private func fill(dark: Bool) -> Color {
        if overArtwork { return dark ? Color.black.opacity(0.48) : Color.white.opacity(0.68) }
        return dark ? Color.white.opacity(0.14) : Color.black.opacity(0.055)
    }

    private func stroke(dark: Bool) -> Color {
        if overArtwork { return Color.white.opacity(dark ? 0.28 : 0.75) }
        return dark ? Color.white.opacity(0.20) : Color.black.opacity(0.09)
    }
}

/// 一个毛玻璃键的样子: 中性色的符号居中压在 `WidgetGlassKeyBackground` 上。
struct WidgetGlassKeyLabel: View {
    let symbol: String
    var diameter: CGFloat = 34
    var overArtwork = false
    /// 符号占直径的比例; 按钮小的时候符号要相对大一点才认得出。
    var symbolScale: CGFloat = 0.38
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: diameter * symbolScale, weight: .semibold))
            .foregroundStyle(WidgetDesign.strongText)
            .widgetAccentable()
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            .frame(width: diameter, height: diameter)
            .background { WidgetGlassKeyBackground(overArtwork: overArtwork) }
            .contentShape(.circle)
    }
}

extension View {
    /// Pins widget content to the exact container bounds. Children that report
    /// a larger size (aspect-fill artwork, long single-line text) can no longer
    /// grow the layout past the widget and shift everything else off-screen.
    func widgetBounds(_ size: CGSize, alignment: Alignment = .topLeading) -> some View {
        frame(width: size.width, height: size.height, alignment: alignment)
            .clipped()
    }
}

struct WidgetEmptyStateIcon: View {
    let systemName: String
    var size: CGFloat = 48
    var tint: Color = WidgetDesign.brandTint

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.50, weight: .medium))
            .foregroundStyle(tint)
            .widgetAccentable()
            .frame(width: size, height: size)
            .background(tint.opacity(0.10), in: .circle)
    }
}

struct WidgetEmptyState: View {
    let symbol: String
    let title: String
    let subtitle: String
    var tint: Color = WidgetDesign.brandTint
    @Environment(\.widgetFamily) private var family

    var body: some View {
        WidgetCanvas {
            if family == .systemMedium {
                HStack(spacing: 16) {
                    WidgetEmptyStateIcon(systemName: symbol, size: 56, tint: tint)
                    textBlock()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else if family == .systemLarge {
                VStack(alignment: .leading, spacing: 20) {
                    WidgetEmptyStateIcon(systemName: symbol, size: 64, tint: tint)
                    textBlock()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                GeometryReader { geometry in
                    // 图标 36、两段间距 16、名字两行约 36、说明两行约 29, 共约 122pt; iPad mini 与 4.7 寸
                    // iPhone 的小号内容只有 109 / 116pt 高, 名字收成一行。
                    VStack(alignment: .leading, spacing: 8) {
                        WidgetEmptyStateIcon(systemName: symbol, size: 36, tint: tint)
                        Spacer(minLength: 0)
                        textBlock(titleLines: geometry.size.height >= 122 ? 2 : 1)
                    }
                    .widgetBounds(geometry.size)
                }
            }
        }
    }

    private func textBlock(titleLines: Int = 2) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: family == .systemSmall ? 15 : (family == .systemLarge ? 22 : 18), weight: .semibold))
                .foregroundStyle(WidgetDesign.strongText)
                .lineLimit(titleLines)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(WidgetDesign.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct WidgetSectionEyebrow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(WidgetDesign.tertiaryText)
    }
}

struct WidgetMiniStat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(WidgetDesign.tertiaryText)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(WidgetDesign.strongText)
        }
    }
}

struct WidgetCoverImageView: View {
    let coverImageName: String?
    var cornerRadius: CGFloat = 10
    var placeholderIndex: Int = 0
    /// 一圈细白边; 贴着小组件边铺满的封面不要, 不然边上会多出一道框。
    var outlined = true

    var body: some View {
        if let image = loadImage() {
            Image(widgetImage: image)
                .resizable()
                .widgetAccentedRenderingMode(.fullColor)
                .aspectRatio(contentMode: .fill)
                .overlay {
                    if outlined {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            WidgetPlaceholderArtwork(
                systemName: "waveform",
                cornerRadius: cornerRadius,
                placeholderIndex: placeholderIndex
            )
        }
    }

    private func loadImage() -> WidgetImage? {
        guard let coverImageName, !coverImageName.isEmpty else { return nil }
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier
        ) else { return nil }

        let fileURL = containerURL.appendingPathComponent(coverImageName)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let image = WidgetImage(data: data) else {
            return nil
        }
        return image
    }
}

struct RecentAlbumCoverView: View {
    let entry: RecentAlbumEntry
    var cornerRadius: CGFloat = 8
    var placeholderIndex: Int = 0

    var body: some View {
        if let image = loadImage() {
            Image(widgetImage: image)
                .resizable()
                .widgetAccentedRenderingMode(.fullColor)
                .aspectRatio(contentMode: .fill)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            WidgetPlaceholderArtwork(
                systemName: "music.note",
                cornerRadius: cornerRadius,
                placeholderIndex: placeholderIndex
            )
        }
    }

    private func loadImage() -> WidgetImage? {
        guard let coverName = entry.coverImageName, !coverName.isEmpty else { return nil }
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier
        ) else { return nil }

        let fileURL = containerURL.appendingPathComponent(coverName)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let image = WidgetImage(data: data) else {
            return nil
        }
        return image
    }
}

struct WidgetPlaceholderArtwork: View {
    let systemName: String
    var cornerRadius: CGFloat = 10
    var placeholderIndex: Int = 0

    var body: some View {
        GeometryReader { geometry in
            let side = max(1, min(geometry.size.width, geometry.size.height))
            ZStack {
                WidgetDesign.brandTint.opacity(0.10)
                Image(systemName: systemName)
                    .font(.system(size: max(16, side * 0.30), weight: .regular))
                    .foregroundStyle(WidgetDesign.brandTint)
                    .widgetAccentable()
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

struct WidgetProgressBar: View {
    var value: Double
    var total: Double
    var tintColor: Color = WidgetDesign.brandTint
    var height: CGFloat = 6
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.10))
                    .frame(height: height)

                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tintColor.opacity(0.55), tintColor],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, geometry.size.width * progress), height: height)

            }
        }
        .frame(height: height)
    }

    private var progress: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, value / total))
    }
}

func formatTime(_ seconds: TimeInterval) -> String {
    let mins = Int(seconds) / 60
    let secs = Int(seconds) % 60
    return String(format: "%d:%02d", mins, secs)
}

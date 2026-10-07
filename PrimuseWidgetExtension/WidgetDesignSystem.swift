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

    /// Brand accent driven by the user's current app icon — the main app
    /// publishes this into the App Group, the widget reads it on every
    /// render. Falls back to the default-icon vinyl blue if nothing has
    /// been published yet (fresh install before the main app first launches).
    static var brandTint: Color {
        let rgb = BrandTintStore.load()
        let red = rgb?.red ?? 0.078
        let green = rgb?.green ?? 0.490
        let blue = rgb?.blue ?? 0.541
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            let lift = traits.userInterfaceStyle == .dark ? 0.32 : 0.0
            return UIColor(red: red + (1 - red) * lift, green: green + (1 - green) * lift,
                           blue: blue + (1 - blue) * lift, alpha: 1)
        })
        #else
        return Color(nsColor: NSColor(name: nil) { appearance in
            let lift = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.32 : 0.0
            return NSColor(srgbRed: red + (1 - red) * lift, green: green + (1 - green) * lift,
                           blue: blue + (1 - blue) * lift, alpha: 1)
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
            if renderingMode == .fullColor, let tint {
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
                        Circle().fill(WidgetDesign.brandTint).frame(width: sleeve * 0.30, height: sleeve * 0.30)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(intent: PrimuseSetPlayingIntent(value: !state.isPlaying)) {
            Image(systemName: state.isPlaying ? (state.isLiveStream ? "stop.fill" : "pause.fill") : "play.fill")
                .font(.system(size: size * 0.38, weight: .semibold))
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .foregroundStyle(WidgetDesign.brandTint)
                .widgetAccentable()
                .frame(width: size, height: size)
                .background(WidgetDesign.brandTint.opacity(0.13), in: .circle)
        }
        .buttonStyle(.plain)
        .invalidatableContent()
        .accessibilityLabel(PMString(state.isPlaying ? "ext.control.pause" : "ext.control.play"))
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
                    text
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else if family == .systemLarge {
                VStack(alignment: .leading, spacing: 20) {
                    WidgetEmptyStateIcon(systemName: symbol, size: 64, tint: tint)
                    text
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    WidgetEmptyStateIcon(systemName: symbol, size: 36, tint: tint)
                    Spacer(minLength: 0)
                    text
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: family == .systemSmall ? 15 : (family == .systemLarge ? 22 : 18), weight: .semibold))
                .foregroundStyle(WidgetDesign.strongText)
                .lineLimit(2)
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

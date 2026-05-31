import SwiftUI
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
    static let ink = Color(red: 0.043, green: 0.067, blue: 0.071)
    static let charcoal = Color(red: 0.075, green: 0.078, blue: 0.073)
    static let graphite = Color(red: 0.135, green: 0.145, blue: 0.135)
    static let sea = Color(red: 0.078, green: 0.490, blue: 0.541)
    static let mint = Color(red: 0.33, green: 0.78, blue: 0.62)
    static let amber = Color(red: 0.941, green: 0.706, blue: 0.353)
    static let clay = Color(red: 0.82, green: 0.38, blue: 0.24)
    static let rose = Color(red: 0.86, green: 0.35, blue: 0.42)
    static let fern = Color(red: 0.24, green: 0.55, blue: 0.32)
    static let sky = Color(red: 0.23, green: 0.58, blue: 0.86)

    /// Brand accent driven by the user's current app icon — the main app
    /// publishes this into the App Group, the widget reads it on every
    /// render. Falls back to the default-icon vinyl blue if nothing has
    /// been published yet (fresh install before the main app first launches).
    static var brandTint: Color {
        if let rgb = BrandTintStore.load() {
            return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
        }
        return sea
    }

    /// Neutral base for widget chrome. The selected app-icon tint is still used
    /// as an accent, but it no longer paints the whole surface purple.
    static let canvasBase = ink
    static let lightCanvasBase = Color(red: 0.955, green: 0.958, blue: 0.945)

    static let panelGradient = LinearGradient(
        colors: [
            Color.white.opacity(0.10),
            Color.white.opacity(0.03)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let strongText = Color.primary.opacity(0.94)
    static let secondaryText = Color.secondary.opacity(0.86)
    static let tertiaryText = Color.secondary.opacity(0.64)
    static let hairline = Color.primary.opacity(0.10)
    static let glowHighlight = Color.white.opacity(0.12)

    static let placeholderGradients: [(Color, Color, Color)] = [
        (sea, mint, amber),
        (sky, sea, Color(red: 0.12, green: 0.30, blue: 0.36)),
        (amber, clay, rose),
        (fern, mint, Color(red: 0.16, green: 0.36, blue: 0.30)),
        (rose, clay, Color(red: 0.32, green: 0.18, blue: 0.16)),
        (Color(red: 0.36, green: 0.46, blue: 0.52), sky, mint),
    ]

    static func placeholderGradient(for index: Int) -> LinearGradient {
        let pair = placeholderGradients[index % placeholderGradients.count]
        return LinearGradient(
            colors: [pair.0, pair.1, pair.2],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func chromeGradient(tint: Color = brandTint) -> LinearGradient {
        LinearGradient(
            colors: [
                graphite.opacity(0.94),
                sea.opacity(0.20),
                tint.opacity(0.05),
                amber.opacity(0.14),
                Color.black.opacity(0.30)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct WidgetCanvas<Content: View>: View {
    let content: Content
    var padding: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        let tint = WidgetDesign.brandTint
        let isDark = colorScheme == .dark
        ZStack {
            isDark ? WidgetDesign.canvasBase : WidgetDesign.lightCanvasBase
            if isDark {
                WidgetDesign.chromeGradient(tint: tint)
            } else {
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.78),
                        tint.opacity(0.10),
                        WidgetDesign.amber.opacity(0.12),
                        Color.black.opacity(0.035)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            LinearGradient(
                colors: [
                    tint.opacity(isDark ? 0.06 : 0.12),
                    .clear,
                    WidgetDesign.clay.opacity(isDark ? 0.12 : 0.08)
                ],
                startPoint: .topTrailing,
                endPoint: .bottomLeading
            )
            LinearGradient(
                colors: [
                    Color.white.opacity(isDark ? 0.12 : 0.34),
                    .clear,
                    Color.black.opacity(isDark ? 0.18 : 0.04)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            content
                .padding(padding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isDark ? 0.18 : 0.72),
                            Color.black.opacity(isDark ? 0.00 : 0.10)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
    }
}

struct WidgetPanel<Content: View>: View {
    let content: Content
    var padding: CGFloat
    var cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    init(padding: CGFloat = 12, cornerRadius: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        let isDark = colorScheme == .dark
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(isDark ? Color.black.opacity(0.20) : Color.white.opacity(0.62))
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(isDark ? WidgetDesign.panelGradient : LinearGradient(
                    colors: [Color.white.opacity(0.74), Color.white.opacity(0.34)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.08), lineWidth: 1)

            content
                .padding(padding)
        }
    }
}

struct WidgetArtworkBackdrop: View {
    let coverImageName: String?
    var blurRadius: CGFloat = 0
    var shadeOpacity: Double = 0.42

    var body: some View {
        ZStack {
            WidgetCanvas(padding: 0) {
                Color.clear
            }

            WidgetCoverImageView(
                coverImageName: coverImageName,
                cornerRadius: 0,
                placeholderIndex: 0
            )
            .scaleEffect(1.18)
            .blur(radius: blurRadius)
            .overlay(
                LinearGradient(
                    colors: [Color.black.opacity(0.08), Color.black.opacity(0.58)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(Color.black.opacity(shadeOpacity))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WidgetStatusPill: View {
    let text: String
    let systemImage: String
    var tint: Color = WidgetDesign.brandTint
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 10, weight: .bold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(colorScheme == .dark ? Color.black.opacity(0.30) : Color.white.opacity(0.68))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(tint.opacity(0.30), lineWidth: 1)
                )
        )
    }
}

struct WidgetEmptyStateIcon: View {
    let systemName: String
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            Circle()
                .fill(WidgetDesign.placeholderGradient(for: 3))
                .overlay(Color.black.opacity(0.10))
            Circle()
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        }
        .frame(width: size, height: size)
        .shadow(color: Color.black.opacity(0.22), radius: 12, x: 0, y: 4)
    }
}

struct WidgetSectionEyebrow: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(1.1)
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

private struct WidgetPlaceholderArtwork: View {
    let systemName: String
    var cornerRadius: CGFloat
    var placeholderIndex: Int

    var body: some View {
        GeometryReader { geometry in
            let side = max(1, min(geometry.size.width, geometry.size.height))
            let ringSize = side * 0.58

            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(WidgetDesign.placeholderGradient(for: placeholderIndex))
                LinearGradient(
                    colors: [Color.white.opacity(0.16), .clear, Color.black.opacity(0.28)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: max(1, side * 0.018))
                    .frame(width: ringSize, height: ringSize)
                Circle()
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: max(1, side * 0.010))
                    .frame(width: ringSize * 0.62, height: ringSize * 0.62)
                Circle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: side * 0.10, height: side * 0.10)
                Image(systemName: systemName)
                    .font(.system(size: max(12, side * 0.16), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.70))
                    .offset(x: side * 0.20, y: side * 0.20)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            )
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
                    .shadow(color: tintColor.opacity(0.35), radius: 6, x: 0, y: 0)
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

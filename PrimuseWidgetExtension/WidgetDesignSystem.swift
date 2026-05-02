import SwiftUI
import UIKit
import PrimuseKit

enum WidgetDesign {
    static let ink = Color(red: 0.05, green: 0.07, blue: 0.12)
    static let night = Color(red: 0.10, green: 0.09, blue: 0.18)
    static let indigo = Color(red: 0.32, green: 0.41, blue: 0.95)
    static let cyan = Color(red: 0.34, green: 0.86, blue: 0.84)
    static let coral = Color(red: 0.98, green: 0.56, blue: 0.43)
    static let lilac = Color(red: 0.58, green: 0.43, blue: 0.98)

    /// Brand accent driven by the user's current app icon — the main app
    /// publishes this into the App Group, the widget reads it on every
    /// render. Falls back to the default-icon vinyl blue if nothing has
    /// been published yet (fresh install before the main app first launches).
    static var brandTint: Color {
        if let rgb = BrandTintStore.load() {
            return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
        }
        return Color(red: 0.20, green: 0.50, blue: 0.95)
    }

    /// Deep base color that the brand-tinted overlay sits on top of. Keeps the
    /// canvas dark enough to read white text against, no matter what tint the
    /// user picked.
    static let canvasBase = Color(red: 0.05, green: 0.06, blue: 0.10)

    static let panelGradient = LinearGradient(
        colors: [
            Color.white.opacity(0.10),
            Color.white.opacity(0.03)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let strongText = Color.white.opacity(0.96)
    static let secondaryText = Color.white.opacity(0.76)
    static let tertiaryText = Color.white.opacity(0.52)
    static let hairline = Color.white.opacity(0.10)
    static let glowHighlight = Color.white.opacity(0.14)

    static let placeholderGradients: [(Color, Color)] = [
        (indigo, lilac),
        (Color(red: 0.18, green: 0.55, blue: 0.92), Color(red: 0.20, green: 0.78, blue: 0.87)),
        (Color(red: 0.58, green: 0.33, blue: 0.92), Color(red: 0.89, green: 0.40, blue: 0.67)),
        (Color(red: 0.92, green: 0.50, blue: 0.34), Color(red: 0.73, green: 0.31, blue: 0.45)),
        (Color(red: 0.27, green: 0.78, blue: 0.72), Color(red: 0.18, green: 0.52, blue: 0.72)),
    ]

    static func placeholderGradient(for index: Int) -> LinearGradient {
        let pair = placeholderGradients[index % placeholderGradients.count]
        return LinearGradient(
            colors: [pair.0, pair.1],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct WidgetCanvas<Content: View>: View {
    let content: Content
    var padding: CGFloat

    init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        let tint = WidgetDesign.brandTint
        ZStack {
            // Deep tinted dark base — the brand color shifts in subtly from
            // top-left to bottom-right so the whole canvas reads as the
            // user's chosen accent, not a fixed purple.
            WidgetDesign.canvasBase
            LinearGradient(
                colors: [
                    tint.opacity(0.10),
                    tint.opacity(0.20),
                    tint.opacity(0.32)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Single brand glow in the upper-right corner — anchors the eye
            // and gives the surface depth without competing color noise.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [tint.opacity(0.50), .clear],
                        center: .center,
                        startRadius: 12,
                        endRadius: 220
                    )
                )
                .frame(width: 280, height: 280)
                .offset(x: 80, y: -130)
                .blendMode(.plusLighter)

            // Frosted-glass highlight that sweeps across the surface.
            LinearGradient(
                colors: [WidgetDesign.glowHighlight, .clear, Color.black.opacity(0.18)],
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
                        colors: [Color.white.opacity(0.18), Color.white.opacity(0.04)],
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

    init(padding: CGFloat = 12, cornerRadius: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.20))
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(WidgetDesign.panelGradient)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)

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
                .fill(Color.black.opacity(0.30))
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
        let tint = WidgetDesign.brandTint
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [tint.opacity(0.55), tint.opacity(0.15)],
                        center: .center,
                        startRadius: 4,
                        endRadius: size / 2
                    )
                )
            Circle()
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        }
        .frame(width: size, height: size)
        .shadow(color: tint.opacity(0.30), radius: 12, x: 0, y: 4)
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
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(WidgetDesign.placeholderGradient(for: placeholderIndex))
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.black.opacity(0.12))
                Image(systemName: "waveform")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
        }
    }

    private func loadImage() -> UIImage? {
        guard let coverImageName, !coverImageName.isEmpty else { return nil }
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier
        ) else { return nil }

        let fileURL = containerURL.appendingPathComponent(coverImageName)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let image = UIImage(data: data) else {
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
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(WidgetDesign.placeholderGradient(for: placeholderIndex))
                Image(systemName: "music.note")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
        }
    }

    private func loadImage() -> UIImage? {
        guard let coverName = entry.coverImageName, !coverName.isEmpty else { return nil }
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier
        ) else { return nil }

        let fileURL = containerURL.appendingPathComponent(coverName)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let image = UIImage(data: data) else {
            return nil
        }
        return image
    }
}

struct WidgetProgressBar: View {
    var value: Double
    var total: Double
    var tintColor: Color = WidgetDesign.brandTint
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.12))
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

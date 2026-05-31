import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Global dynamic theme color manager.
/// Extracts dominant color from album artwork and provides it as the app-wide accent.
@MainActor
@Observable
final class ThemeService {
    /// Current accent color derived from the playing song's cover art
    private(set) var accentColor: Color = ThemeService.defaultAccent

    /// Darker variant for background gradients (NowPlaying etc.)
    private(set) var darkAccent: Color = ThemeService.defaultDarkAccent

    /// Identity token for SwiftUI animation tracking
    private(set) var colorID: String = "default"

    /// User-chosen base accent (driven by selected app icon). When set, this
    /// replaces the static brand color as the fallback whenever a song's
    /// cover art isn't actively driving the theme.
    private(set) var baseAccent: Color = ThemeService.defaultAccent
    private(set) var baseDarkAccent: Color = ThemeService.defaultDarkAccent

    // MARK: - Defaults

    /// Fallback accent when nothing is playing (deep sea teal)
    nonisolated static let defaultAccent = Color(red: 0.078, green: 0.490, blue: 0.541)       // #147D8A
    nonisolated static let defaultDarkAccent = Color(red: 0.043, green: 0.267, blue: 0.294)   // #0B444B

    // MARK: - Cover directory (via MetadataAssetStore)


    // MARK: - Public API

    func updateFromCoverArt(fileName: String?, songID: String? = nil) {
        #if os(macOS)
        guard MacUIPreferences.shared.coverDrivenAmbient else {
            resetToDefault()
            return
        }
        #endif

        guard (fileName != nil && !fileName!.isEmpty) || songID != nil else {
            resetToDefault()
            return
        }

        // Try songID-based cache first, then legacy filename。读取必须走
        // readCoverData(named:),它会透明处理 content-addressed redirect。
        let image: PlatformImage?
        if let songID {
            let hashedName = MetadataAssetStore.shared.expectedCoverFileName(for: songID)
            image = MetadataAssetStore.shared.readCoverData(named: hashedName).flatMap { PlatformImage(data: $0) }
        } else {
            image = nil
        }
        let resolvedImage: PlatformImage
        if let image {
            resolvedImage = image
        } else if let fileName, !fileName.isEmpty,
                  !fileName.contains("/"), !fileName.contains("://") {
            // Legacy: direct filename in artworkDir (走 redirect-aware reader)
            guard let data = MetadataAssetStore.shared.readCoverData(named: fileName),
                  let loaded = PlatformImage(data: data) else {
                resetToDefault()
                return
            }
            resolvedImage = loaded
        } else {
            resetToDefault()
            return
        }

        // Extract on background, apply on main
        let capturedSongID = songID
        let capturedFileName = fileName
        Task.detached(priority: .userInitiated) {
            let result = Self.extractDominantColor(from: resolvedImage)
            await MainActor.run { [weak self] in
                guard let self else { return }
                withAnimation(.easeInOut(duration: 0.6)) {
                    self.accentColor = result.accent
                    self.darkAccent = result.dark
                    self.colorID = capturedSongID ?? capturedFileName ?? "default"
                }
            }
        }
    }

    func resetToDefault() {
        withAnimation(.easeInOut(duration: 0.6)) {
            accentColor = baseAccent
            darkAccent = baseDarkAccent
            colorID = "default"
        }
    }

    /// Set the user-chosen base accent (typically from the selected app icon).
    /// If the theme is currently sitting on the default (no cover art driving
    /// it), the live accent updates immediately too. Otherwise the new base
    /// kicks in next time `resetToDefault` runs.
    func setBaseAccent(_ tint: Color) {
        let dark = Self.darken(tint, factor: 0.55)
        baseAccent = tint
        baseDarkAccent = dark
        if colorID == "default" {
            withAnimation(.easeInOut(duration: 0.6)) {
                accentColor = tint
                darkAccent = dark
            }
        }
    }

    private static func darken(_ color: Color, factor: CGFloat) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if os(iOS)
        UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        #else
        // NSColor 的 getHue 跟 UIColor 同语义,但要先转到 RGB colorspace
        // 才能保证 HSB 通道有效。
        let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        #endif
        return Color(hue: h, saturation: s, brightness: max(0, b * factor))
    }

    // MARK: - Color Extraction Algorithm

    /// Exposed for `CoverTintProvider`, which needs per-song tints
    /// without mutating the global accent. Stays nonisolated so it's
    /// safe to call from background tasks.
    struct ColorResult {
        let accent: Color
        let dark: Color
    }

    /// Extracts the most dominant vibrant color from an image using HSB bucketing.
    nonisolated static func extractDominantColor(from image: PlatformImage) -> ColorResult {
        // Down-sample to 40×40 for performance。两个平台共用一段下采样:
        // 直接从原图拿到 CGImage,然后用 CGContext 把它画到 40x40 上,再从
        // context 拿出 cgImage。这样不依赖 UIGraphics(iOS) 或 NSGraphics
        // (macOS) 任一平台的图像 context API。
        let sampleSize = CGSize(width: 40, height: 40)
        guard let originalCG = image.platformCGImage else {
            return ColorResult(accent: defaultAccent, dark: defaultDarkAccent)
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: Int(sampleSize.width),
            height: Int(sampleSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return ColorResult(accent: defaultAccent, dark: defaultDarkAccent)
        }
        ctx.draw(originalCG, in: CGRect(origin: .zero, size: sampleSize))
        guard let cgImage = ctx.makeImage(),
              let dataProvider = cgImage.dataProvider,
              let pixelData = dataProvider.data else {
            return ColorResult(accent: defaultAccent, dark: defaultDarkAccent)
        }

        let ptr: UnsafePointer<UInt8> = CFDataGetBytePtr(pixelData)
        let pixelCount = Int(sampleSize.width) * Int(sampleSize.height)
        let bytesPerPixel = cgImage.bitsPerPixel / 8

        // HSB bucketing: 12 hue buckets of 30° each
        struct HSBPixel {
            let hue: CGFloat
            let saturation: CGFloat
            let brightness: CGFloat
        }

        var buckets = [[HSBPixel]](repeating: [], count: 12)

        for i in 0..<pixelCount {
            let offset = i * bytesPerPixel
            let r = CGFloat(ptr[offset]) / 255.0
            let g = CGFloat(ptr[offset + 1]) / 255.0
            let b = CGFloat(ptr[offset + 2]) / 255.0

            var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
            #if os(iOS)
            UIColor(red: r, green: g, blue: b, alpha: 1).getHue(&h, saturation: &s, brightness: &br, alpha: &a)
            #else
            NSColor(red: r, green: g, blue: b, alpha: 1).getHue(&h, saturation: &s, brightness: &br, alpha: &a)
            #endif

            // Filter out near-black, near-white, and desaturated pixels
            guard s > 0.15, br > 0.10, br < 0.95 else { continue }

            let bucketIndex = min(11, Int(h * 12))
            buckets[bucketIndex].append(HSBPixel(hue: h, saturation: s, brightness: br))
        }

        // Find the bucket with the most pixels
        guard let dominantBucket = buckets.max(by: { $0.count < $1.count }),
              !dominantBucket.isEmpty else {
            return ColorResult(accent: defaultAccent, dark: defaultDarkAccent)
        }

        // Average the pixels in the dominant bucket
        var avgH: CGFloat = 0, avgS: CGFloat = 0, avgB: CGFloat = 0
        for pixel in dominantBucket {
            avgH += pixel.hue
            avgS += pixel.saturation
            avgB += pixel.brightness
        }
        let count = CGFloat(dominantBucket.count)
        avgH /= count
        avgS /= count
        avgB /= count

        // Ensure accent color is vibrant enough for UI use
        // Clamp saturation ≥ 0.3 and brightness between 0.4–0.8 for good contrast
        let accentS = max(avgS, 0.35)
        let accentB = min(max(avgB, 0.50), 0.85)

        let accent = Color(hue: avgH, saturation: accentS, brightness: accentB)

        // Dark variant: visible but subdued for background gradients
        let darkB = accentB * 0.65
        let dark = Color(hue: avgH, saturation: accentS, brightness: darkB)

        return ColorResult(accent: accent, dark: dark)
    }
}

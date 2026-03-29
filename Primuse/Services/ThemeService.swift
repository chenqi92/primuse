import SwiftUI
import UIKit

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

    // MARK: - Defaults

    /// Fallback accent when nothing is playing (current brand blue-purple)
    nonisolated(unsafe) static let defaultAccent = Color(red: 0.392, green: 0.318, blue: 0.976)       // #6451F9
    nonisolated(unsafe) static let defaultDarkAccent = Color(red: 0.22, green: 0.15, blue: 0.56)

    // MARK: - Cover directory (via MetadataAssetStore)

    private static let artworkDir: URL = MetadataAssetStore.shared.artworkDirectoryURL

    // MARK: - Public API

    func updateFromCoverArt(fileName: String?) {
        guard let fileName, !fileName.isEmpty else {
            resetToDefault()
            return
        }

        let fileURL = Self.artworkDir.appendingPathComponent(fileName)

        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let image = UIImage(data: data) else {
            resetToDefault()
            return
        }

        // Extract on background, apply on main
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.extractDominantColor(from: image)
            await MainActor.run {
                guard let self else { return }
                withAnimation(.easeInOut(duration: 0.6)) {
                    self.accentColor = result.accent
                    self.darkAccent = result.dark
                    self.colorID = fileName
                }
            }
        }
    }

    func resetToDefault() {
        withAnimation(.easeInOut(duration: 0.6)) {
            accentColor = Self.defaultAccent
            darkAccent = Self.defaultDarkAccent
            colorID = "default"
        }
    }

    // MARK: - Color Extraction Algorithm

    private struct ColorResult {
        let accent: Color
        let dark: Color
    }

    /// Extracts the most dominant vibrant color from an image using HSB bucketing.
    nonisolated private static func extractDominantColor(from image: UIImage) -> ColorResult {
        // Down-sample to 40×40 for performance
        let sampleSize = CGSize(width: 40, height: 40)
        UIGraphicsBeginImageContextWithOptions(sampleSize, true, 1)
        image.draw(in: CGRect(origin: .zero, size: sampleSize))
        let sampled = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        guard let cgImage = sampled?.cgImage,
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

            let uiColor = UIColor(red: r, green: g, blue: b, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
            uiColor.getHue(&h, saturation: &s, brightness: &br, alpha: &a)

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

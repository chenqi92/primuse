import Foundation
import MusicKit
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

    /// Foreground color that keeps solid accent controls readable. Updated
    /// together with both artwork-driven and user-selected fallback accents.
    private(set) var onAccent: Color = .white

    /// Identity token for SwiftUI animation tracking
    private(set) var colorID: String = "default"

    /// Invalidates detached extraction work when the playing song changes while
    /// an older cover is still being sampled.
    private var updateGeneration: UInt = 0

    /// Cancels remote artwork IO and color extraction when playback advances.
    /// The generation check below remains the final guard because cancellation
    /// can arrive after a download or decode has already completed.
    private var artworkUpdateTask: Task<Void, Never>?

    /// User-chosen base accent (driven by selected app icon). When set, this
    /// replaces the static brand color as the fallback whenever a song's
    /// cover art isn't actively driving the theme.
    private(set) var baseAccent: Color = ThemeService.defaultAccent
    private(set) var baseDarkAccent: Color = ThemeService.defaultDarkAccent

    // MARK: - Defaults

    /// Fallback accent when nothing is playing (deep sea teal)
    nonisolated static let defaultAccent = Color(red: 0.078, green: 0.490, blue: 0.541)       // #147D8A
    nonisolated static let defaultDarkAccent = Color(red: 0.043, green: 0.267, blue: 0.294)   // #0B444B

    /// Remote artwork uses a credential-free ephemeral session. Apple Music
    /// artwork is public CDN content, so it must never inherit source cookies,
    /// URL credentials, or authentication state from NAS connections.
    private nonisolated static let remoteArtworkSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private nonisolated static let maximumRemoteArtworkBytes = 12 * 1024 * 1024


    // MARK: - Public API

    func updateFromCoverArt(
        fileName: String?,
        songID: String? = nil,
        appleMusicID: String? = nil
    ) {
        let generation = beginArtworkUpdate()

        #if os(macOS)
        guard MacUIPreferences.shared.coverDrivenAmbient else {
            applyFallbackTheme()
            return
        }
        #else
        guard !ThemeColorSettings.shared.usesFixedColor else {
            applyFallbackTheme()
            return
        }
        #endif

        let normalizedFileName = fileName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAppleMusicID = appleMusicID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedFileName?.isEmpty == false
                || songID?.isEmpty == false
                || normalizedAppleMusicID?.isEmpty == false else {
            applyFallbackTheme()
            return
        }

        // Try the song-ID cache first, then a legacy filename. All reads go
        // through the redirect-aware MetadataAssetStore entry point.
        let cachedData = Self.cachedCoverData(
            fileName: normalizedFileName,
            songID: songID
        )
        let remoteURL = Self.safeRemoteArtworkURL(from: normalizedFileName)
        guard cachedData != nil
                || remoteURL != nil
                || normalizedAppleMusicID?.isEmpty == false else {
            applyFallbackTheme()
            return
        }

        // Do not leave the previous song's color on screen while a remote
        // Apple Music cover is downloading. A disk-cache hit stays seamless.
        if cachedData == nil {
            applyFallbackTheme()
        }

        let capturedSongID = songID
        let capturedFileName = normalizedFileName
        artworkUpdateTask = Task.detached(priority: .userInitiated) {
            var data = cachedData
            var fetchedRemoteData = false
            // A concrete HTTP(S) cover has a bounded request timeout and gives
            // the most faithful palette, so process it before any MusicKit
            // lookup. A cold MusicKit request can wait on authorization or the
            // network indefinitely and must never block an already usable CDN
            // URL from coloring the player.
            if data == nil, let remoteURL {
                data = await Self.downloadRemoteArtwork(from: remoteURL)
                fetchedRemoteData = data != nil
            }
            guard !Task.isCancelled else { return }

            var pixelResult: ColorResult?
            if let data, let image = PlatformImage(data: data) {
                // A valid image is useful to artwork views even when it is
                // intentionally grayscale and therefore has no theme color.
                if fetchedRemoteData, let capturedSongID, !capturedSongID.isEmpty {
                    await MetadataAssetStore.shared.cacheCover(data, forSongID: capturedSongID)
                }
                guard !Task.isCancelled else { return }
                pixelResult = Self.extractDominantColor(from: image)
            }
            guard !Task.isCancelled else { return }
            var musicKitResult: ColorResult?
            if pixelResult == nil,
               let normalizedAppleMusicID,
               !normalizedAppleMusicID.isEmpty {
                musicKitResult = await Self.appleMusicArtworkColor(for: normalizedAppleMusicID)
            }
            guard !Task.isCancelled else { return }
            let result = pixelResult ?? musicKitResult
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.updateGeneration == generation else { return }
                guard let result else {
                    self.applyFallbackTheme()
                    return
                }
                self.applyArtworkTheme(
                    result,
                    identity: capturedSongID ?? capturedFileName ?? "default"
                )
            }
        }
    }

    /// `MusicKit.Artwork.url` may use the non-network `musicKit://` scheme for
    /// user-library songs. Resolve that song through MusicKit and derive a
    /// palette from Artwork's semantic colors when no downloadable CDN image
    /// produced a pixel palette.
    private nonisolated static func appleMusicArtworkColor(for amID: String) async -> ColorResult? {
        let cachedArtwork = await MainActor.run {
            AppServices.shared.appleMusicLibrary.cachedMusicKitSong(amID: amID)?.artwork
        }
        if let cachedArtwork,
           let result = colorResult(from: cachedArtwork) {
            return result
        }
        guard !Task.isCancelled else { return nil }
        let resolvedSong = await AppServices.shared.appleMusicLibrary.musicKitSong(amID: amID)
        guard !Task.isCancelled, let artwork = resolvedSong?.artwork else { return nil }
        return colorResult(from: artwork)
    }

    private nonisolated static func colorResult(from artwork: MusicKit.Artwork) -> ColorResult? {
        let colors = [
            artwork.backgroundColor,
            artwork.primaryTextColor,
            artwork.secondaryTextColor,
            artwork.tertiaryTextColor,
            artwork.quaternaryTextColor
        ].compactMap { $0 }

        var best: (hue: CGFloat, saturation: CGFloat, brightness: CGFloat, score: CGFloat)?
        for cgColor in colors {
            guard let hsb = hsbComponents(from: cgColor),
                  hsb.saturation >= 0.24,
                  hsb.brightness > 0.10,
                  hsb.brightness < 0.95 else { continue }
            let score = hsb.saturation * hsb.saturation * (0.55 + 0.45 * hsb.brightness)
            if best == nil || score > best!.score {
                best = (hsb.hue, hsb.saturation, hsb.brightness, score)
            }
        }
        guard let best else { return nil }
        return makeColorResult(
            hue: best.hue,
            saturation: best.saturation,
            brightness: best.brightness
        )
    }

    private nonisolated static func hsbComponents(
        from cgColor: CGColor
    ) -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat)? {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        #if os(iOS)
        guard UIColor(cgColor: cgColor).getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: &alpha
        ) else { return nil }
        #else
        guard let color = NSColor(cgColor: cgColor)?.usingColorSpace(.deviceRGB) else {
            return nil
        }
        color.getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: &alpha
        )
        #endif
        guard alpha > 0.05 else { return nil }
        return (hue, saturation, brightness)
    }

    /// Pass `animated: false` for continuous updates such as dragging a color
    /// slider, where the 0.6s crossfade would queue up and lag behind the touch.
    func resetToDefault(animated: Bool = true) {
        _ = beginArtworkUpdate()
        applyFallbackTheme(animated: animated)
    }

    @discardableResult
    private func beginArtworkUpdate() -> UInt {
        artworkUpdateTask?.cancel()
        artworkUpdateTask = nil
        updateGeneration &+= 1
        return updateGeneration
    }

    private func applyThemeChange(animated: Bool, _ body: () -> Void) {
        if animated {
            withAnimation(.easeInOut(duration: 0.6), body)
        } else {
            body()
        }
    }

    private func applyFallbackTheme(animated: Bool = true) {
        applyThemeChange(animated: animated) {
            accentColor = baseAccent
            darkAccent = baseDarkAccent
            onAccent = Self.contrastingForeground(for: baseAccent)
            colorID = "default"
        }
    }

    private func applyArtworkTheme(_ result: ColorResult, identity: String) {
        withAnimation(.easeInOut(duration: 0.6)) {
            accentColor = result.accent
            darkAccent = result.dark
            onAccent = Self.contrastingForeground(for: result.accent)
            colorID = identity
        }
    }

    private nonisolated static func cachedCoverData(
        fileName: String?,
        songID: String?
    ) -> Data? {
        if let songID, !songID.isEmpty {
            let hashedName = MetadataAssetStore.shared.expectedCoverFileName(for: songID)
            if let data = MetadataAssetStore.shared.readCoverData(named: hashedName) {
                return data
            }
        }
        guard let fileName,
              !fileName.isEmpty,
              !fileName.contains("/"),
              !fileName.contains("://") else { return nil }
        return MetadataAssetStore.shared.readCoverData(named: fileName)
    }

    /// Only public HTTP(S) artwork URLs are eligible. In particular, reject
    /// user/password URL components so credentials cannot be persisted under
    /// the song cache key or forwarded across redirects.
    private nonisolated static func safeRemoteArtworkURL(from fileName: String?) -> URL? {
        guard let fileName,
              let url = URL(string: fileName),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil else { return nil }
        return url
    }

    private nonisolated static func downloadRemoteArtwork(from url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.httpShouldHandleCookies = false
        request.setValue("image/*", forHTTPHeaderField: "Accept")

        do {
            let (temporaryURL, response) = try await remoteArtworkSession.download(for: request)
            guard !Task.isCancelled,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }

            let advertisedLength = response.expectedContentLength
            guard advertisedLength <= 0 || advertisedLength <= Int64(maximumRemoteArtworkBytes) else {
                return nil
            }
            let values = try temporaryURL.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = values.fileSize,
                  fileSize > 0,
                  fileSize <= maximumRemoteArtworkBytes else { return nil }
            return try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
        } catch {
            return nil
        }
    }

    /// Set the user-chosen base accent (typically from the selected app icon).
    /// If the theme is currently sitting on the default (no cover art driving
    /// it), the live accent updates immediately too. Otherwise the new base
    /// kicks in next time `resetToDefault` runs.
    func setBaseAccent(_ tint: Color, animated: Bool = true) {
        let dark = Self.darken(tint, factor: 0.55)
        baseAccent = tint
        baseDarkAccent = dark
        if colorID == "default" {
            applyThemeChange(animated: animated) {
                accentColor = tint
                darkAccent = dark
                onAccent = Self.contrastingForeground(for: tint)
            }
        }
    }

    /// Selects whichever of black/white has the higher WCAG contrast ratio
    /// against the accent. The crossover luminance is approximately 0.179.
    private static func contrastingForeground(for color: Color) -> Color {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        #if os(iOS)
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return .white
        }
        #else
        let converted = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
        converted.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #endif

        func linearize(_ component: CGFloat) -> CGFloat {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linearize(red)
            + 0.7152 * linearize(green)
            + 0.0722 * linearize(blue)
        return luminance > 0.179 ? .black : .white
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
    /// Returns nil when the artwork has no representative chromatic region;
    /// callers must retain their fallback styling instead of treating the
    /// brand teal as if it came from a grayscale cover.
    nonisolated static func extractDominantColor(from image: PlatformImage) -> ColorResult? {
        // Down-sample to 40×40 for performance。两个平台共用一段下采样:
        // 直接从原图拿到 CGImage,然后用 CGContext 把它画到 40x40 上,再从
        // context 拿出 cgImage。这样不依赖 UIGraphics(iOS) 或 NSGraphics
        // (macOS) 任一平台的图像 context API。
        let sampleSize = CGSize(width: 40, height: 40)
        guard let originalCG = image.platformCGImage else {
            return nil
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
            return nil
        }
        ctx.draw(originalCG, in: CGRect(origin: .zero, size: sampleSize))
        guard let cgImage = ctx.makeImage(),
              let dataProvider = cgImage.dataProvider,
              let pixelData = dataProvider.data else {
            return nil
        }

        let ptr: UnsafePointer<UInt8> = CFDataGetBytePtr(pixelData)
        let pixelCount = Int(sampleSize.width) * Int(sampleSize.height)
        let bytesPerPixel = cgImage.bitsPerPixel / 8

        // Finer hue buckets keep nearby warm tones from swallowing smaller
        // but more characteristic cool/vivid regions in the artwork.
        let bucketCount = 24
        struct HSBPixel {
            let hue: CGFloat
            let saturation: CGFloat
            let brightness: CGFloat
            let weight: CGFloat
        }

        var buckets = [[HSBPixel]](repeating: [], count: bucketCount)

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
            guard s >= 0.24, br > 0.10, br < 0.95 else { continue }

            // Saturation-weighted scoring prevents large beige/skin/paper
            // regions from making unrelated covers all resolve to brown.
            let weight = s * s * (0.55 + 0.45 * br)
            // Shift by half a bucket so reds near hue 0/1 stay together.
            let bucketIndex = Int(h * CGFloat(bucketCount) + 0.5) % bucketCount
            buckets[bucketIndex].append(
                HSBPixel(hue: h, saturation: s, brightness: br, weight: weight)
            )
        }

        let minimumBucketPixels = max(8, pixelCount / 200)
        var dominantBucketIndex: Int?
        var dominantBucketScore: CGFloat = 0
        for index in buckets.indices where buckets[index].count >= minimumBucketPixels {
            let score = buckets[index].reduce(CGFloat.zero) { $0 + $1.weight }
            if score > dominantBucketScore {
                dominantBucketScore = score
                dominantBucketIndex = index
            }
        }

        guard let dominantBucketIndex else {
            return nil
        }
        let dominantBucket = buckets[dominantBucketIndex]

        // Weighted circular hue averaging handles the red 0/1 boundary while
        // keeping saturation and brightness tied to representative pixels.
        var hueX: CGFloat = 0, hueY: CGFloat = 0
        var avgS: CGFloat = 0, avgB: CGFloat = 0, totalWeight: CGFloat = 0
        for pixel in dominantBucket {
            let angle = pixel.hue * 2 * .pi
            hueX += cos(angle) * pixel.weight
            hueY += sin(angle) * pixel.weight
            avgS += pixel.saturation * pixel.weight
            avgB += pixel.brightness * pixel.weight
            totalWeight += pixel.weight
        }
        guard totalWeight > 0 else {
            return nil
        }
        var avgH = atan2(hueY, hueX) / (2 * .pi)
        if avgH < 0 { avgH += 1 }
        avgS /= totalWeight
        avgB /= totalWeight

        return makeColorResult(hue: avgH, saturation: avgS, brightness: avgB)
    }

    private nonisolated static func makeColorResult(
        hue: CGFloat,
        saturation: CGFloat,
        brightness: CGFloat
    ) -> ColorResult {
        // Keep the accent vivid enough for ambient use while bounding its
        // brightness so downstream surfaces can maintain reliable contrast.
        let accentS = min(max(saturation * 1.08, 0.35), 0.92)
        let accentB = min(max(brightness, 0.50), 0.85)
        let accent = Color(hue: hue, saturation: accentS, brightness: accentB)

        // Dark variant: visible but subdued for background gradients.
        let dark = Color(hue: hue, saturation: accentS, brightness: accentB * 0.65)
        return ColorResult(accent: accent, dark: dark)
    }
}

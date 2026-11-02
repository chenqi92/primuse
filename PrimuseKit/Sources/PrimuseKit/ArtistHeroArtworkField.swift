import Foundation

/// The image keeps its existing layout height; only its backdrop continues below it.
/// Coordinates are measured from the top of the photograph in layout points.
public struct ArtistHeroArtworkGeometry: Equatable, Sendable {
    public let width: Double
    public let photoHeight: Double
    public let extensionHeight: Double

    public init?(width: Double, photoHeight: Double) {
        guard width.isFinite, photoHeight.isFinite,
              width >= 1, photoHeight >= 1, width <= 16_384, photoHeight <= 16_384,
              photoHeight / width <= 16 else { return nil }
        self.width = width
        self.photoHeight = photoHeight
        extensionHeight = min(144, photoHeight * 0.30)
    }

    public var totalHeight: Double { photoHeight + extensionHeight }

    /// All transition coordinates share the photograph's layout-point space.
    /// Keep facial detail clear; soften the lower clothing into the continued field.
    public var blurStartY: Double { min(photoHeight * 0.75, width * 0.62) }
    public var blurEndY: Double { max(blurStartY + 1, min(totalHeight, width * 1.35)) }
    public var maximumBlurRadius: Double { min(22, width / 30) }
    public var fadeStartY: Double { photoHeight * 0.50 }

    public func sharpOpacity(at y: Double) -> Double {
        // The full-resolution overlay hands off before the field's blur grows
        // large; do not leave a sharp ghost over an increasingly blurred image.
        1 - Self.smoothstep(from: blurStartY,
                            to: min(photoHeight, blurStartY + width * 0.20), value: y)
    }

    /// This is applied once to the combined sharp photo and derived field.
    public func finalOpacity(at y: Double) -> Double {
        let envelope = 1 - Self.smoothstep(from: fadeStartY, to: totalHeight, value: y)
        // Let the page color take over before the small summary text. The
        // continuation retains a smooth, nonzero tail, without a local dark
        // title stripe. Both ends still have a zero first derivative.
        return envelope * envelope * envelope
    }

    /// Dark photographs keep a linear continuation, while unusually bright
    /// clothing can use just enough of the legacy fade to protect captions.
    public func finalOpacity(at y: Double, captionWeight: Double) -> Double {
        let progress = Self.progress(from: fadeStartY, to: totalHeight, value: y)
        let linear = 1 - progress
        let weight = captionWeight.isFinite ? min(1, max(0, captionWeight)) : 1
        return linear + weight * (finalOpacity(at: y) - linear)
    }

    private static func progress(from start: Double, to end: Double, value: Double) -> Double {
        guard value.isFinite else { return value == .infinity ? 1 : 0 }
        return min(1, max(0, (value - start) / (end - start)))
    }

    private static func smoothstep(from start: Double, to end: Double, value: Double) -> Double {
        let progress = progress(from: start, to: end, value: value)
        return progress * progress * (3 - 2 * progress)
    }
}

#if canImport(CoreGraphics) && canImport(CoreImage)
import CoreGraphics
import CoreImage

/// An actual sRGB sample, independent of SwiftUI/UIKit and display appearance.
public struct ArtistHeroArtworkColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// Calculates one fade weight when the picture or its scene color changes.
/// This is not a per-frame image analysis or an artist-specific color rule.
public enum ArtistHeroCaptionFade {
    public static func weight(photo: ArtistHeroArtworkColor, background: ArtistHeroArtworkColor) -> Double {
        let components = [photo.red, photo.green, photo.blue, background.red, background.green, background.blue]
        guard components.allSatisfy(\.isFinite) else { return 1 }
        let tint = LibraryDetailTintPolicy.backgroundTint(red: background.red, green: background.green,
                                                         blue: background.blue)
        let body = LibraryDetailTintPolicy.rgbComponents(of: tint.top)
        let scene = [body.red, body.green, body.blue]
        let image = [photo.red, photo.green, photo.blue].map { min(1, max(0, $0)) }
        func luminance(_ rgb: [Double]) -> Double {
            func linear(_ value: Double) -> Double {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(rgb[0]) + 0.7152 * linear(rgb[1]) + 0.0722 * linear(rgb[2])
        }
        func isReadable(_ weight: Double) -> Bool {
            for (position, ink, minimum): (Double, [Double], Double) in [
                (0.80, [1, 1, 1], 3.1),
                (1.00, [245.0 / 255, 247.0 / 255, 246.0 / 255], 4.65),
            ] {
                let progress = (position - 0.50) / 0.80
                let linear = 1 - progress
                let smooth = progress * progress * (3 - 2 * progress)
                let cubic = pow(1 - smooth, 3)
                let alpha = linear + weight * (cubic - linear)
                let composite = zip(scene, image).map { $0 + alpha * ($1 - $0) }
                let contrast = (luminance(ink) + 0.05) / (luminance(composite) + 0.05)
                if contrast < minimum { return false }
            }
            return true
        }
        if isReadable(0) { return 0 }
        // Keep the strongest available protection even when no fade blend can
        // meet the margin; the UI still validates the actual rendered text.
        guard isReadable(1) else { return 1 }
        var unreadable = 0.0, readable = 1.0
        for _ in 0..<32 {
            let candidate = (unreadable + readable) / 2
            if isReadable(candidate) { readable = candidate } else { unreadable = candidate }
        }
        return readable
    }
}

/// Prepares a static variable-radius field and transition colors from one
/// oriented aspect-fill crop, plus a separate scene sample from the original
/// upright photograph. Nothing here fetches artwork or applies a page-wide tint.
public enum ArtistHeroArtworkField {
    // CIContext is documented as safe to reuse across rendering threads.
    private static let context = CIContext(options: [.cacheIntermediates: false])

    public struct Prepared: Sendable {
        public let image: CGImage
        /// Mean of the visible crop's lower band, never the uncropped source.
        /// A transparent lower band has no color to offer the transition.
        public let edgeColor: ArtistHeroArtworkColor?
        /// Left/center/right means from that same band, for an optional mesh.
        public let edgePalette: [ArtistHeroArtworkColor]
        /// Scene color from the upright, uncropped photograph's upper corners.
        /// Unlike the transition colors, this deliberately excludes clothing
        /// near the lower edge and does not change with the displayed crop.
        public let sourceBackground: ArtistHeroArtworkColor?
        /// Bright-side representative of the caption-bearing lower photo,
        /// independent of the scene seed used for the page background.
        public let captionColor: ArtistHeroArtworkColor?
    }

    /// Compatibility entry point for clients which only need the image.
    public static func render(
        image: CGImage,
        geometry: ArtistHeroArtworkGeometry,
        exifOrientation: Int32 = 1,
        maximumPixelWidth: Int = 384
    ) -> CGImage? {
        prepare(image: image, geometry: geometry, exifOrientation: exifOrientation,
                maximumPixelWidth: maximumPixelWidth)?.image
    }

    public static func prepare(
        image: CGImage,
        geometry: ArtistHeroArtworkGeometry,
        exifOrientation: Int32 = 1,
        maximumPixelWidth: Int = 384
    ) -> Prepared? {
        guard maximumPixelWidth > 0, !Task.isCancelled else { return nil }
        let width = max(1, min(maximumPixelWidth, 512, Int(ceil(geometry.width))))
        let scale = Double(width) / geometry.width
        let photoHeight = max(1, Int(ceil(geometry.photoHeight * scale)))
        let extensionHeight = max(1, Int(ceil(geometry.extensionHeight * scale)))
        let height = photoHeight + extensionHeight
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let photoExtent = CGRect(x: 0, y: extensionHeight, width: width, height: photoHeight)

        let orientation = (1...8).contains(exifOrientation) ? exifOrientation : 1
        let source = CIImage(cgImage: image).oriented(forExifOrientation: orientation)
        guard source.extent.width > 0, source.extent.height > 0 else { return nil }
        let factor = max(CGFloat(width) / source.extent.width, CGFloat(photoHeight) / source.extent.height)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        let photograph = scaled.transformed(by: CGAffineTransform(
            translationX: (CGFloat(width) - scaled.extent.width) / 2 - scaled.extent.minX,
            y: CGFloat(extensionHeight) + (CGFloat(photoHeight) - scaled.extent.height) / 2 - scaled.extent.minY
        )).cropped(to: photoExtent)

        // Reflect a real lower image band, rather than stretching one edge row into stripes.
        // The seam has matching pixels and is subsequently softened in both axes.
        let bandHeight = min(CGFloat(photoHeight), max(CGFloat(extensionHeight) * 1.5, CGFloat(photoHeight) * 0.22))
        let band = photograph.cropped(to: CGRect(x: 0, y: CGFloat(extensionHeight), width: CGFloat(width), height: bandHeight))
        let ratio = CGFloat(extensionHeight) / bandHeight
        let continuation = band.transformed(by: CGAffineTransform(
            a: 1, b: 0, c: 0, d: -ratio, tx: 0,
            ty: CGFloat(extensionHeight) * (1 + ratio)
        )).cropped(to: CGRect(x: 0, y: 0, width: width, height: extensionHeight))
        let extended = photograph.composited(over: continuation).cropped(to: extent)

        let radius = max(1, geometry.maximumBlurRadius * scale)
        let mask = CIFilter(name: "CISmoothLinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: CGFloat(height) - geometry.blurStartY * scale),
            "inputPoint1": CIVector(x: 0, y: CGFloat(height) - geometry.blurEndY * scale),
            "inputColor0": CIColor(red: 0, green: 0, blue: 0),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1),
        ])?.outputImage?.cropped(to: extent)
        guard let mask, !Task.isCancelled else { return nil }
        // Public Core Image filter: the mask controls the actual sampling
        // radius per pixel, rather than fading one fixed blurred image in.
        guard let result = CIFilter(name: "CIMaskedVariableBlur", parameters: [
            kCIInputImageKey: extended.clampedToExtent(),
            "inputMask": mask.clampedToExtent(),
            kCIInputRadiusKey: radius,
        ])?.outputImage?.cropped(to: extent),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let rendered = context.createCGImage(result, from: extent,
                  format: .RGBA8, colorSpace: colorSpace), !Task.isCancelled else { return nil }

        let edge = edgeColors(photograph: photograph, photoExtent: photoExtent, colorSpace: colorSpace)
        let background = sourceBackground(source: source, colorSpace: colorSpace)
        let caption = captionColor(photograph: photograph, photoExtent: photoExtent, colorSpace: colorSpace)
        guard !Task.isCancelled else { return nil }
        return Prepared(image: rendered, edgeColor: edge.mean, edgePalette: edge.palette,
                        sourceBackground: background, captionColor: caption)
    }

    private static func captionColor(
        photograph: CIImage, photoExtent: CGRect, colorSpace: CGColorSpace
    ) -> ArtistHeroArtworkColor? {
        // The rendered caption occupies the lower 28% of the visible crop.
        // Exclude the outer 12% on each side, where background is unrelated to
        // a centered name. CI's lower-Y rectangle is the photograph's bottom.
        let bounds = CGRect(x: photoExtent.minX + photoExtent.width * 0.12, y: photoExtent.minY,
                            width: photoExtent.width * 0.76, height: photoExtent.height * 0.28)
        let width = 64, height = 32
        let sample = photograph.cropped(to: bounds)
            .transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / bounds.width,
                                              y: CGFloat(height) / bounds.height))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let address = buffer.baseAddress else { return }
            context.render(sample, toBitmap: address, rowBytes: width * 4,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBA8, colorSpace: colorSpace)
        }
        var channels = [[Double]](repeating: [], count: 3)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Double(bytes[index + 3]) / 255
            guard alpha >= 0.5 else { continue }
            for channel in 0..<3 {
                channels[channel].append(min(1, Double(bytes[index + channel]) / 255 / alpha))
            }
        }
        guard !channels[0].isEmpty else { return nil }
        func percentile(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
        }
        return ArtistHeroArtworkColor(red: percentile(channels[0]), green: percentile(channels[1]),
                                      blue: percentile(channels[2]))
    }

    private static func sourceBackground(source: CIImage, colorSpace: CGColorSpace) -> ArtistHeroArtworkColor? {
        let extent = source.extent
        let sampleWidth = extent.width * 0.12
        let sampleHeight = extent.height * 0.20
        let size = 32
        var channels = [[Double]](repeating: [], count: 3)
        // CI coordinates increase upwards. Both rectangles start at the top of
        // the already-oriented source, before the hero's aspect-fill crop.
        for x in [extent.minX, extent.maxX - sampleWidth] {
            let corner = CGRect(x: x, y: extent.maxY - sampleHeight,
                                width: sampleWidth, height: sampleHeight)
            let sample = source.cropped(to: corner)
                .transformed(by: CGAffineTransform(translationX: -corner.minX, y: -corner.minY))
                .transformed(by: CGAffineTransform(scaleX: CGFloat(size) / corner.width,
                                                  y: CGFloat(size) / corner.height))
            var bytes = [UInt8](repeating: 0, count: size * size * 4)
            bytes.withUnsafeMutableBytes { buffer in
                guard let address = buffer.baseAddress else { return }
                context.render(sample, toBitmap: address, rowBytes: size * 4,
                               bounds: CGRect(x: 0, y: 0, width: size, height: size),
                               format: .RGBA8, colorSpace: colorSpace)
            }
            for index in stride(from: 0, to: bytes.count, by: 4) {
                let alpha = Double(bytes[index + 3]) / 255
                guard alpha > 0.01 else { continue }
                for channel in 0..<3 {
                    channels[channel].append(min(1, Double(bytes[index + channel]) / 255 / alpha))
                }
            }
        }
        guard !channels[0].isEmpty else { return nil }
        // A median resists small foreground objects/highlights in either
        // corner; averaging would let them tint the entire artist page.
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            let middle = sorted.count / 2
            return sorted.count.isMultiple(of: 2)
                ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        }
        return ArtistHeroArtworkColor(red: median(channels[0]), green: median(channels[1]),
                                      blue: median(channels[2]))
    }

    private static func edgeColors(
        photograph: CIImage,
        photoExtent: CGRect,
        colorSpace: CGColorSpace
    ) -> (mean: ArtistHeroArtworkColor?, palette: [ArtistHeroArtworkColor]) {
        // Lower fifth of the *displayed*, upright photo. Render the same crop
        // pipeline into a small strip so source padding and EXIF rotation cannot
        // supply unrelated colors. Alpha is used as weight, not read as black.
        let band = CGRect(x: photoExtent.minX, y: photoExtent.minY,
                          width: photoExtent.width, height: max(1, photoExtent.height * 0.20))
        let width = 48, height = 12
        let strip = photograph.cropped(to: band)
            .transformed(by: CGAffineTransform(translationX: -band.minX, y: -band.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / band.width,
                                              y: CGFloat(height) / band.height))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let address = buffer.baseAddress else { return }
            context.render(strip, toBitmap: address, rowBytes: width * 4,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBA8, colorSpace: colorSpace)
        }
        func mean(in range: Range<Int>) -> ArtistHeroArtworkColor? {
            var red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0
            for y in 0..<height {
                for x in range {
                    let offset = (y * width + x) * 4
                    let a = Double(bytes[offset + 3]) / 255
                    guard a > 0.01 else { continue }
                    // CI's RGBA8 render is premultiplied. Summing RGB divided
                    // by summed alpha recovers the weighted visible color.
                    red += Double(bytes[offset]) / 255
                    green += Double(bytes[offset + 1]) / 255
                    blue += Double(bytes[offset + 2]) / 255
                    alpha += a
                }
            }
            guard alpha > 0 else { return nil }
            return ArtistHeroArtworkColor(red: min(1, red / alpha),
                                          green: min(1, green / alpha),
                                          blue: min(1, blue / alpha))
        }
        return (mean(in: 0..<width), (0..<3).compactMap { mean(in: ($0 * 16)..<(($0 + 1) * 16)) })
    }
}
#endif

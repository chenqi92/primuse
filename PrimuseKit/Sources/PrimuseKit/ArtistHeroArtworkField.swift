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
        extensionHeight = min(96, photoHeight * 0.24)
    }

    public var totalHeight: Double { photoHeight + extensionHeight }

    public func sharpOpacity(at y: Double) -> Double {
        1 - Self.smoothstep(from: photoHeight * 0.68, to: photoHeight * 0.94, value: y)
    }

    /// This is applied once to the combined sharp photo and derived field.
    public func finalOpacity(at y: Double) -> Double {
        1 - Self.smoothstep(from: photoHeight * 0.72, to: totalHeight, value: y)
    }

    private static func smoothstep(from start: Double, to end: Double, value: Double) -> Double {
        guard value.isFinite else { return value == .infinity ? 1 : 0 }
        let progress = min(1, max(0, (value - start) / (end - start)))
        return progress * progress * (3 - 2 * progress)
    }
}

#if canImport(CoreGraphics) && canImport(CoreImage)
import CoreGraphics
import CoreImage

/// Prepares one small, static field from the *same* centered aspect-fill crop as the photo.
/// It does not fetch artwork, choose colors, or apply the final transparency envelope.
public enum ArtistHeroArtworkField {
    // CIContext is documented as safe to reuse across rendering threads.
    private static let context = CIContext(options: [.cacheIntermediates: false])

    public static func render(
        image: CGImage,
        geometry: ArtistHeroArtworkGeometry,
        exifOrientation: Int32 = 1,
        maximumPixelWidth: Int = 384
    ) -> CGImage? {
        guard maximumPixelWidth > 0, !Task.isCancelled else { return nil }
        let width = max(1, min(maximumPixelWidth, 512, Int(ceil(geometry.width))))
        let scale = Double(width) / geometry.width
        let photoHeight = max(1, Int(ceil(geometry.photoHeight * scale)))
        let extensionHeight = max(1, Int(ceil(geometry.extensionHeight * scale)))
        let height = photoHeight + extensionHeight
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let photoExtent = CGRect(x: 0, y: extensionHeight, width: width, height: photoHeight)

        let source = CIImage(cgImage: image).oriented(forExifOrientation: exifOrientation)
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

        let radius = max(1, min(28, geometry.photoHeight * 0.055) * scale)
        let blurred = extended.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)
        let mask = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: CGFloat(height) - CGFloat(photoHeight) * 0.58),
            "inputPoint1": CIVector(x: 0, y: CGFloat(extensionHeight)),
            "inputColor0": CIColor(red: 0, green: 0, blue: 0),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1),
        ])?.outputImage?.cropped(to: extent)
        guard let mask, !Task.isCancelled else { return nil }
        let result = blurred.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: extended,
            kCIInputMaskImageKey: mask,
        ])
        return context.createCGImage(result, from: extent, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}
#endif

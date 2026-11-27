import Foundation

public enum ArtistHeroMetadataPolicy {
    public static func nameKey(_ name: String) -> String {
        ArtistIdentityPolicy.groupingKey(
            name.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? name
        )
    }

    /// 仅加载 MusicKit 返回的静态图片，不访问 Apple 网页或跟随跨站跳转。
    public static func isArtworkURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.fragment == nil,
              let host = url.host?.lowercased(), host == "mzstatic.com" || host.hasSuffix(".mzstatic.com"),
              url.path.hasPrefix("/image/"), !url.absoluteString.contains("{") && !url.absoluteString.contains("}") else { return false }
        return true
    }
}

#if canImport(CoreImage) && canImport(CoreGraphics)
import CoreImage
import CoreGraphics
import CryptoKit

public struct ArtistHeroPhotoSignature: Sendable, Equatable {
    public let samples: [UInt8]
    public let aspectRatio: Double

    public init?(samples: [UInt8], aspectRatio: Double) {
        guard samples.count == 16 * 16 * 3, aspectRatio.isFinite, aspectRatio > 0 else { return nil }
        self.samples = samples
        self.aspectRatio = aspectRatio
    }

    public var cacheToken: String {
        var bytes = Data(samples)
        bytes.append(contentsOf: String((aspectRatio * 1_000).rounded()).utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ArtistHeroPhotoVerification {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Normalize the complete oriented photograph, not its hero crop or blur.
    public static func signature(image: CGImage, exifOrientation: Int32 = 1) -> ArtistHeroPhotoSignature? {
        guard !Task.isCancelled else { return nil }
        let source = CIImage(cgImage: image).oriented(forExifOrientation: (1...8).contains(exifOrientation) ? exifOrientation : 1)
        let extent = source.extent
        guard extent.width > 0, extent.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let normalized = source.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        // Work at a bounded 256-square canvas, then average 16-square regions.
        // Region means avoid treating a single high-contrast edge's resize
        // ringing as a different photo, while keeping composition information.
        let side = 256
        let small = normalized.clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: Double(side) / extent.height,
            kCIInputAspectRatioKey: extent.height / extent.width,
        ]).cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        rgba.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            context.render(small, toBitmap: base, rowBytes: side * 4,
                           bounds: CGRect(x: 0, y: 0, width: side, height: side), format: .RGBA8, colorSpace: space)
        }
        var rgb: [UInt8] = []
        rgb.reserveCapacity(768)
        for row in 0..<16 {
            for column in 0..<16 {
                var channels = [Int](repeating: 0, count: 4)
                for y in (row * 16)..<((row + 1) * 16) {
                    for x in (column * 16)..<((column + 1) * 16) {
                        let offset = (y * side + x) * 4
                        for channel in 0..<4 { channels[channel] += Int(rgba[offset + channel]) }
                    }
                }
                // A transparent/partial placeholder cannot verify an opaque portrait.
                guard channels[3] >= 245 * 256 else { return nil }
                for channel in 0..<3 {
                    rgb.append(UInt8(min(255, (Double(channels[channel]) * 255 / Double(channels[3])).rounded())))
                }
            }
        }
        return ArtistHeroPhotoSignature(samples: rgb, aspectRatio: extent.width / extent.height)
    }

    public static func matches(_ first: ArtistHeroPhotoSignature, _ second: ArtistHeroPhotoSignature) -> Bool {
        guard abs(log(first.aspectRatio / second.aspectRatio)) <= 0.025 else { return false }
        var absolute = 0.0, squares = 0.0
        var worst = 0, cellErrors: [Int] = []
        var sumA = 0.0, sumB = 0.0, sumAA = 0.0, sumBB = 0.0, sumAB = 0.0
        let weights = [0.2126, 0.7152, 0.0722]
        for cell in 0..<256 {
            var a = 0.0, b = 0.0, cellError = 0
            for channel in 0..<3 {
                let index = cell * 3 + channel
                let x = Double(first.samples[index]), y = Double(second.samples[index])
                let delta = abs(x - y)
                absolute += delta
                squares += delta * delta
                cellError = max(cellError, Int(delta))
                a += x * weights[channel]
                b += y * weights[channel]
            }
            worst = max(worst, cellError)
            cellErrors.append(cellError)
            sumA += a; sumB += b; sumAA += a * a; sumBB += b * b; sumAB += a * b
        }
        let varianceA = max(0, sumAA / 256 - pow(sumA / 256, 2))
        let varianceB = max(0, sumBB / 256 - pow(sumB / 256, 2))
        guard varianceA >= 64, varianceB >= 64 else { return false }
        let correlation = (sumAB / 256 - sumA * sumB / (256 * 256)) / sqrt(varianceA * varianceB)
        cellErrors.sort()
        return absolute / 768 <= 3.5 && sqrt(squares / 768) <= 5.5
            && cellErrors[242] <= 9 && worst <= 22 && correlation >= 0.995
    }
}
#endif

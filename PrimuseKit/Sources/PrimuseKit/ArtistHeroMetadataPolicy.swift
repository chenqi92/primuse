import Foundation
import CoreFoundation

/// Public catalog metadata is only a candidate until its photograph has been
/// compared with the displayed image. An artist's name never verifies a color.
public enum ArtistHeroMetadataPolicy {
    public struct Candidate: Sendable, Equatable {
        public let backgroundHex: String
        public let imageURL: URL
        public let assetID: String
        public let nameArtwork: NameArtworkCandidate?
    }

    public struct NameArtworkCandidate: Sendable, Equatable {
        public let imageURL: URL
        public let width: Int
        public let height: Int
    }

    public static let maximumDocumentBytes = 1_200_000

    public static func nameKey(_ name: String) -> String {
        ArtistIdentityPolicy.groupingKey(
            name.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? name
        )
    }

    /// A strict name match is intentionally allowed to fail for catalog aliases.
    /// Unrelated search results must not become a source of page colors.
    public static func uniqueArtistID(in data: Data, named name: String) -> String? {
        guard data.count <= maximumDocumentBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { return nil }
        let expected = nameKey(name)
        guard !expected.isEmpty else { return nil }
        var ids = Set<String>()
        for item in results.prefix(12) {
            guard item["wrapperType"] as? String == "artist",
                  item["artistType"] as? String == "Artist",
                  let candidateName = item["artistName"] as? String,
                  nameKey(candidateName) == expected,
                  let id = decimalID(item["artistId"]) else { continue }
            ids.insert(id)
        }
        return ids.count == 1 ? ids.first : nil
    }

    /// Read only the matching artist header, never album/related-artist artwork.
    public static func candidates(in html: Data, artistID: String) -> [Candidate] {
        guard html.count <= maximumDocumentBytes, decimalID(artistID) == artistID,
              let text = String(data: html, encoding: .utf8),
              let expression = try? NSRegularExpression(
                pattern: #"<script\b[^>]*\bid\s*=\s*["']serialized-server-data["'][^>]*>([\s\S]*?)</script\s*>"#,
                options: [.caseInsensitive]
              ),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text),
              let body = text[range].data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let packages = root["data"] as? [[String: Any]] else { return [] }
        var result: [Candidate] = []
        for package in packages.prefix(4) {
            guard let data = package["data"] as? [String: Any],
                  let sections = data["sections"] as? [[String: Any]] else { continue }
            for section in sections.prefix(64) {
                guard (section["id"] as? String)?.contains("ArtistDetailHeader") == true,
                      let items = section["items"] as? [[String: Any]] else { continue }
                for item in items.prefix(8) {
                    guard decimalID(item["id"]) == artistID,
                          let descriptor = item["contentDescriptor"] as? [String: Any],
                          descriptor["kind"] as? String == "artist",
                          let identifiers = descriptor["identifiers"] as? [String: Any],
                          decimalID(identifiers["storeAdamID"]) == artistID else { continue }
                    let logo = parseNameArtwork(item["artistLogo"])
                    for key in ["colorBackdropArtwork", "artwork"] {
                        guard let wrapper = item[key] as? [String: Any],
                              let art = wrapper["dictionary"] as? [String: Any],
                              let hex = art["bgColor"] as? String, validHex(hex),
                              let template = art["url"] as? String, template.count <= 4_096,
                              let width = dimension(art["width"]), let height = dimension(art["height"]) else { continue }
                        let scale = min(1, 384 / Double(max(width, height)))
                        let urlText = template
                            .replacingOccurrences(of: "{w}", with: String(max(1, Int((Double(width) * scale).rounded()))))
                            .replacingOccurrences(of: "{h}", with: String(max(1, Int((Double(height) * scale).rounded()))))
                            .replacingOccurrences(of: "{c}", with: "bb")
                            .replacingOccurrences(of: "{f}", with: "jpg")
                        guard let url = URL(string: urlText), let asset = artworkAssetID(url),
                              !result.contains(where: { $0.assetID == asset }) else { continue }
                        result.append(Candidate(backgroundHex: hex.lowercased(), imageURL: url, assetID: asset, nameArtwork: logo))
                        if result.count == 2 { return result }
                    }
                }
            }
        }
        return result
    }

    /// Logo URLs are independent assets but belong only to the matching header.
    /// They are not exposed by a verified result until that header's photo passes.
    private static func parseNameArtwork(_ value: Any?) -> NameArtworkCandidate? {
        guard let wrapper = value as? [String: Any],
              let art = wrapper["dictionary"] as? [String: Any],
              let template = art["url"] as? String, template.count <= 4_096,
              let width = dimension(art["width"]), let height = dimension(art["height"]) else { return nil }
        let scale = min(1, 1200 / Double(width), 400 / Double(height))
        let requestedWidth = max(1, Int((Double(width) * scale).rounded()))
        let requestedHeight = max(1, Int((Double(height) * scale).rounded()))
        let text = template.replacingOccurrences(of: "{w}", with: String(requestedWidth))
            .replacingOccurrences(of: "{h}", with: String(requestedHeight))
            .replacingOccurrences(of: "{c}", with: "bb").replacingOccurrences(of: "{f}", with: "png")
        guard let url = URL(string: text), isNameArtworkURL(url) else { return nil }
        return NameArtworkCandidate(imageURL: url, width: requestedWidth, height: requestedHeight)
    }

    public static func isNameArtworkURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil, url.fragment == nil,
              let host = url.host?.lowercased(), host == "mzstatic.com" || host.hasSuffix(".mzstatic.com"),
              url.path.hasPrefix("/image/"), url.path.lowercased().hasSuffix(".png"),
              !url.absoluteString.contains("{") && !url.absoluteString.contains("}") else { return false }
        return true
    }

    public static func artworkAssetID(_ url: URL) -> String? {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil, url.fragment == nil,
              let host = url.host?.lowercased(), host == "mzstatic.com" || host.hasSuffix(".mzstatic.com"),
              url.path.hasPrefix("/image/"), !url.absoluteString.contains("{") && !url.absoluteString.contains("}"),
              let expression = try? NSRegularExpression(
                pattern: #"(?:^|/)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?:/|$)"#,
                options: [.caseInsensitive]
              ),
              let match = expression.firstMatch(in: url.path, range: NSRange(url.path.startIndex..., in: url.path)),
              let range = Range(match.range(at: 1), in: url.path) else { return nil }
        return String(url.path[range]).lowercased()
    }

    private static func decimalID(_ value: Any?) -> String? {
        let text: String
        if let string = value as? String { text = string }
        else if let number = value as? NSNumber,
                CFGetTypeID(number) != CFBooleanGetTypeID(),
                number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue {
            text = number.stringValue
        } else { return nil }
        guard !text.isEmpty, text.count <= 20, text.first != "0", text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return text
    }

    private static func dimension(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.rounded() == number.doubleValue,
              (1...30_000).contains(number.doubleValue) else { return nil }
        return number.intValue
    }

    private static func validHex(_ text: String) -> Bool {
        text.utf8.count == 6 && text.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
}

#if canImport(ImageIO)
import ImageIO

/// An already validated, bounded official PNG. No UIImage crosses an actor.
public struct ArtistHeroNameArtwork: Sendable, Equatable {
    public static let maximumBytes = 768_000
    public let data: Data
    public let width: Int
    public let height: Int

    public init?(pngData: Data) {
        guard pngData.count <= Self.maximumBytes, pngData.count >= 24,
              pngData.prefix(8).elementsEqual([137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source), type as String == "public.png",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              (1...1200).contains(width.intValue), (1...400).contains(height.intValue) else { return nil }
        self.data = pngData
        self.width = width.intValue
        self.height = height.intValue
    }
}
#endif

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

import AppKit
import ImageIO
import UniformTypeIdentifiers

typealias PlatformImage = NSImage
extension NSImage { static func fromCGImage(_ image: CGImage) -> NSImage { NSImage(cgImage: image, size: .zero) } }
// Compatibility/SVG validation is outside this ImageIO sizing test. The input
// is a complete, generated PNG and the real production decode runs below.
enum SVGImageSupport { static func looksLikeSVG(_ data: Data) -> Bool { false } }
enum SVGArtworkRasterizer { static func makeCGImage(from: Data, maximumPixelSize: Int) -> CGImage? { nil } }
enum ArtworkImageCompatibility {
    static func isCompleteImage(_ data: Data) -> Bool { true }
    static func hasRedundantJPEGSampling(_ data: Data) -> Bool { false }
}

struct DecodeProbe {
    /* PRODUCTION_POLICY */
    static func image(_ data: Data, points: CGFloat?, scale: CGFloat) -> NSImage? {
        decode(data, bucket: /* BUCKET_CALL */)
    }
}


// Exercise production bucket fallback and invalidation against a real NSCache.
// Only notification delivery and the model's unrelated fields are replaced.
enum PrimuseKit { struct Song { let id: String; let coverArtFileName: String? } }
@MainActor struct CacheProbe {
    /* PRODUCTION_BUCKET */
    static let memoryCache = NSCache<NSString, NSImage>()
    static let failedLoadCache = NSCache<NSString, NSDate>()
    let bucket: Bucket
    func cacheKey(for bucket: Bucket) -> String { "cover@\(bucket.rawValue)" }
    static func postArtworkInvalidation(token: String?, userInfo: [AnyHashable: Any] = [:]) {}
    /* PRODUCTION_FALLBACK */
    /* PRODUCTION_INVALIDATION */
    /* PRODUCTION_SONG_INVALIDATION */

    static func check() -> Int {
        let names = ["icon", "thumb", "smallCard", "card", "full"]
        var failures = 0
        let image = NSImage(size: NSSize(width: 1, height: 1))
        for prefix in ["cover", "album_cover", "artist_cover", "unrelated"] {
            for name in names { memoryCache.setObject(image, forKey: "\(prefix)@\(name)" as NSString) }
        }
        failedLoadCache.setObject(NSDate(), forKey: "miss")
        invalidateCache(for: "cover")
        for name in names {
            for prefix in ["cover", "album_cover", "artist_cover"] {
                if memoryCache.object(forKey: "\(prefix)@\(name)" as NSString) != nil {
                    print("FAIL: invalidation left \(prefix)@\(name)"); failures += 1
                }
            }
            if memoryCache.object(forKey: "unrelated@\(name)" as NSString) == nil {
                print("FAIL: invalidation removed unrelated artwork"); failures += 1
            }
        }
        if failedLoadCache.object(forKey: "miss") != nil {
            print("FAIL: invalidation retained a recent failure"); failures += 1
        }
        memoryCache.removeAllObjects()
        for prefix in ["song", "reference", "unrelated"] {
            for name in names { memoryCache.setObject(image, forKey: "\(prefix)@\(name)" as NSString) }
        }
        invalidateCache(forSongs: [.init(id: "song", coverArtFileName: "reference")])
        for name in names {
            if memoryCache.object(forKey: "song@\(name)" as NSString) != nil
                || memoryCache.object(forKey: "reference@\(name)" as NSString) != nil
                || memoryCache.object(forKey: "unrelated@\(name)" as NSString) == nil {
                print("FAIL: song invalidation for \(name)"); failures += 1
            }
        }
        for (index, name) in names.enumerated() {
            guard let bucket = Bucket(rawValue: name) else {
                print("FAIL: missing pixel bucket \(name)"); failures += 1; continue
            }
            memoryCache.removeAllObjects()
            let images = names.map { _ in NSImage(size: NSSize(width: 1, height: 1)) }
            for candidate in names.indices where candidate != index {
                memoryCache.setObject(images[candidate], forKey: "cover@\(names[candidate])" as NSString)
            }
            let actual = CacheProbe(bucket: bucket).cachedLowerResolutionImage()
            if index == 0 ? actual != nil : actual !== images[index - 1] {
                print("FAIL: \(name) must use the nearest cached lower resolution"); failures += 1
            }
        }
        memoryCache.removeAllObjects()
        print("\(failures == 0 ? "PASS" : "FAIL"): bucket fallback and targeted cache invalidation")
        return failures
    }
}

struct AnimationLimitProbe {
    let size: CGFloat?
    /* PRODUCTION_ANIMATION_POLICY */
    var maximumPixels: Int { animationMaximumPixelSize }
}

@main struct ArtworkDecodeSmoke {
    @MainActor static func main() {
        startArtworkSmokeBudget()
        var failures = 0
        for (width, height) in [(2000, 2000), (2000, 1200), (1200, 2000), (40, 30), (4096, 32)] {
            autoreleasepool {
                let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                let data = NSMutableData()
                let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(destination, context.makeImage()!, nil)
                CGImageDestinationFinalize(destination)
                for (points, scale, target) in [(44.0, 1.0, 96.0), (44, 2, 96), (48, 2, 96), (48.5, 2, 192),
                                                (96, 2, 192), (96.5, 2, 384), (150, 2, 384),
                                                (192, 2, 384), (192.5, 2, 768), (320, 3, 1536),
                                                (384, 2, 768), (385, 2, 1536), (1000, 3, 1536)] {
                    let image = DecodeProbe.image(data as Data, points: points, scale: scale)!
                    let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
                    let short = Double(min(cg.width, cg.height))
                    let long = Double(max(cg.width, cg.height))
                    let sourceShort = Double(min(width, height))
                    let sourceLong = Double(max(width, height))
                    let expectedLong = min(sourceLong, 1536, ceil(target * sourceLong / sourceShort))
                    let requiredShort = min(points * scale, sourceShort, 1536 * sourceShort / sourceLong)
                    if abs(long - expectedLong) > 1 || short + 1 < requiredShort {
                        print("FAIL \(width)x\(height), \(points)pt @\(scale)x: \(cg.width)x\(cg.height), expected longest \(expectedLong), minimum short \(requiredShort)")
                        failures += 1
                    } else { print("PASS \(width)x\(height), \(points)pt @\(scale)x: \(cg.width)x\(cg.height), \(cg.bytesPerRow * cg.height) bytes") }
                }
                // Unknown layout size and invalid scale stay bounded.
                for (points, scale) in [(nil, 2.0), (CGFloat.nan, 2.0), (44.0, Double.infinity), (44, 0), (44, -1), (0, 2), (-1, 2)] as [(CGFloat?, CGFloat)] {
                    guard let image = DecodeProbe.image(data as Data, points: points, scale: scale),
                          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                          max(cg.width, cg.height) <= 1536 else { fatalError("Unbounded decode") }
                }
            }
        }
        for (points, expected) in [(nil, 1536), (44, 288), (150, 768), (321, 1536), (600, 1536)] as [(CGFloat?, Int)] {
            let actual = AnimationLimitProbe(size: points).maximumPixels
            if actual != expected {
                print("FAIL: static decode sizing must preserve animation limit for \(String(describing: points)): expected \(expected), got \(actual)")
                failures += 1
            }
        }
        failures += CacheProbe.check()
        print("\(failures == 0 ? "PASS" : "FAIL"): \(failures) decode/cache failures")
        exit(failures == 0 ? 0 : 1)
    }
}

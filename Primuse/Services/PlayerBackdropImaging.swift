import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import PrimuseKit
import UniformTypeIdentifiers

/// 播放背景用到的图片处理。全部是同步的纯函数，调用方放在后台执行：大图只经
/// ImageIO 的缩略图接口按目标尺寸解码（12MP 的照片不会整张解开），模糊只做一次。
enum PlayerBackdropImaging {
    /// 原始图片缩到长边 `maxPixel` 并重新编码成 JPEG（带上照片的方向）。
    nonisolated static func downscaledJPEG(from data: Data, maxPixel: Int, quality: Double = 0.84) -> Data? {
        guard let image = decodedImage(data: data, maxPixel: maxPixel) else { return nil }
        return jpegData(image, quality: quality)
    }

    /// 按长边上限解码，立刻解出位图，SwiftUI 画的时候不会再在主线程上解码。
    nonisolated static func decodedImage(data: Data, maxPixel: Int) -> CGImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        return thumbnail(from: source, maxPixel: maxPixel)
    }

    nonisolated static func decodedImage(url: URL, maxPixel: Int) -> CGImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return nil }
        return thumbnail(from: source, maxPixel: maxPixel)
    }

    /// 封面模糊：先缩成小图再做一次高斯模糊并略提饱和度。结果是一张普通位图，
    /// 显示时没有任何实时滤镜。
    nonisolated static func blurredBackdrop(from image: CGImage) -> CGImage? {
        let longSide = CGFloat(max(image.width, image.height))
        guard longSide > 0 else { return nil }
        let target = CGFloat(PlayerBackdropPixelPolicy.blurSourcePixel)
        var input = CIImage(cgImage: image)
        if longSide > target {
            let scale = target / longSide
            input = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let extent = input.extent.integral
        let radius = max(extent.width, extent.height) * 0.06
        let blurred = input
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(radius))
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.18,
                kCIInputBrightnessKey: -0.02,
            ])
            .cropped(to: extent)
        return ciContext.createCGImage(blurred, from: extent)
    }

    /// 专辑页背景用的封底:缩小后轻轻模糊一次。封底上的曲目单、字都化开成色块和线条,
    /// 版式还认得出来,但不会和页面上的字抢。结果是普通位图,显示时没有实时滤镜。
    nonisolated static func softenedBackdrop(from image: CGImage) -> CGImage? {
        let longSide = CGFloat(max(image.width, image.height))
        guard longSide > 0 else { return nil }
        let target: CGFloat = 640
        var input = CIImage(cgImage: image)
        if longSide > target {
            let scale = target / longSide
            input = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let extent = input.extent.integral
        let radius = max(extent.width, extent.height) * 0.01
        let softened = input
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(radius))
            .cropped(to: extent)
        return ciContext.createCGImage(softened, from: extent)
    }

    /// 铺满封面下面那一截的底图：封面下沿占高度 `fraction` 的那条，下面接上它的上下镜像，
    /// 缩成小图一起模糊一次。上半垫在封面渐隐那段底下，下半往下铺到屏幕底；接缝两边是封面
    /// 最下面同一行像素，所以渐隐处看到的就是封面自己的颜色。
    nonisolated static func fullBleedExtension(from image: CGImage, fraction: CGFloat) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0 else { return nil }
        let stripHeight = max(1, (height * min(max(fraction, 0.05), 1)).rounded())
        // Core Image 的原点在左下角：y 从 0 到 stripHeight 就是封面最下面那一条。
        let strip = CIImage(cgImage: image)
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: stripHeight))
        let upper = strip.transformed(by: CGAffineTransform(translationX: 0, y: stripHeight))
        let mirrored = strip.transformed(
            by: CGAffineTransform(scaleX: 1, y: -1).concatenating(CGAffineTransform(translationX: 0, y: stripHeight))
        )
        let scale = min(1, fullBleedExtensionWidth / width)
        let combined = upper.composited(over: mirrored)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = combined.extent.integral
        let blurred = combined
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(extent.width * 0.06))
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.1])
            .cropped(to: extent)
        return ciContext.createCGImage(blurred, from: extent)
    }

    /// 延伸底图的宽度。模糊过的图放大到整屏宽看不出差别。
    private nonisolated static let fullBleedExtensionWidth: CGFloat = 96

    nonisolated static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    nonisolated static func contentID(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func thumbnail(from source: CGImageSource, maxPixel: Int) -> CGImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixel),
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    // CIContext 本身线程安全，各处共用一份。
    private nonisolated static let ciContext = CIContext(options: [
        .cacheIntermediates: false,
        .useSoftwareRenderer: false,
    ])
}

/// 自选的背景图片：预缩到屏幕尺寸的 JPEG，存在 MetadataAssetStore 的 custom 目录下
/// 自己的子目录里（用户数据，不随缓存清理），按内容哈希命名。
enum PlayerBackdropImageStore {
    /// 原图上限。再大的文件多半不是照片，也不值得为一张背景读进内存。
    static let maximumSourceBytes = 80 * 1024 * 1024
    /// 收别处送来的成品（扫码直传）时的上限。
    static let maximumStoredBytes = 4 * 1024 * 1024

    nonisolated static var directoryURL: URL {
        MetadataAssetStore.shared.customArtworkDirectoryURL
            .appendingPathComponent("backdrops", isDirectory: true)
    }

    nonisolated static func fileURL(id: String) -> URL? {
        guard LibraryArtworkContentIDPolicy.isValid(id) else { return nil }
        return directoryURL.appendingPathComponent("\(id).jpg")
    }

    nonisolated static func exists(id: String) -> Bool {
        guard let url = fileURL(id: id) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    nonisolated static func data(id: String) -> Data? {
        guard let url = fileURL(id: id) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// 导入一张原图：缩到 `maxPixel`、存盘，返回 id。读不出图片时返回 nil。
    nonisolated static func importImage(_ data: Data, maxPixel: Int) -> String? {
        guard !data.isEmpty, data.count <= maximumSourceBytes,
              let jpeg = PlayerBackdropImaging.downscaledJPEG(from: data, maxPixel: maxPixel) else {
            return nil
        }
        return store(jpeg)
    }

    /// 存一份已经处理好的 JPEG（扫码直传过来的）。`expectedID` 不对就不收。
    @discardableResult
    nonisolated static func storeProcessed(_ data: Data, expectedID: String? = nil) -> String? {
        guard !data.isEmpty, data.count <= maximumStoredBytes,
              let image = PlayerBackdropImaging.decodedImage(data: data, maxPixel: 64),
              image.width > 0 else { return nil }
        if let expectedID, PlayerBackdropImaging.contentID(for: data) != expectedID { return nil }
        return store(data)
    }

    nonisolated static func remove(id: String) {
        guard let url = fileURL(id: id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private nonisolated static func store(_ jpeg: Data) -> String? {
        let id = PlayerBackdropImaging.contentID(for: jpeg)
        guard let url = fileURL(id: id) else { return nil }
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                try jpeg.write(to: url, options: .atomic)
            }
            return id
        } catch {
            plog("⚠️ Player backdrop image store failed: \(error.localizedDescription)")
            return nil
        }
    }
}

/// 从音乐源取来的专辑封底，缩好后的副本放在缓存目录（可随缓存清理，下次再取）。
enum PlayerBackdropAlbumBackCache {
    nonisolated static var directoryURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Primuse/PlayerBackdrops", isDirectory: true)
    }

    nonisolated static func fileURL(forKey key: String) -> URL {
        directoryURL.appendingPathComponent(PlayerBackdropImaging.contentID(for: Data(key.utf8)) + ".jpg")
    }

    nonisolated static func store(_ jpeg: Data, forKey key: String) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try jpeg.write(to: fileURL(forKey: key), options: .atomic)
        } catch {
            plog("⚠️ Player backdrop cache write failed: \(error.localizedDescription)")
        }
    }
}

/// 解好的背景位图，按 key 放在内存里（换歌回来、重新打开播放页时立刻就有）。
final class PlayerBackdropMemoryCache: @unchecked Sendable {
    nonisolated static let shared = PlayerBackdropMemoryCache()

    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    nonisolated func image(forKey key: String) -> CGImage? {
        cache.object(forKey: key as NSString)?.image
    }

    nonisolated func insert(_ image: CGImage, forKey key: String) {
        cache.setObject(Box(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
    }

    nonisolated func removeAll() {
        cache.removeAllObjects()
    }
}
